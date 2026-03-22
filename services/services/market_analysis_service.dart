import 'dart:async';
import 'dart:math';
import 'dart:ui';
import 'package:flutter/foundation.dart';
import '../models/candle.dart';
import '../models/market_analysis_result.dart';
import 'candle_storage_service.dart';

extension LastOrNull<E> on List<E> {
  E? get lastOrNull => isEmpty ? null : this[length - 1];
}

/// 🔥 MarketAnalysisService v10.6 (1-minute candle optimized + adaptive smoothing)
class MarketAnalysisService {
  MarketAnalysisService._internal();
  static final MarketAnalysisService instance = MarketAnalysisService._internal();

  final Map<String, MarketAnalysisResult> _resultsCache = {};
  final Map<String, Completer<void>> _analysisLocks = {};
  final Map<String, List<Candle>> _candlesPerPair = {};

  final ValueNotifier<Map<String, MarketAnalysisResult>> analysisNotifier = ValueNotifier({});
  final ValueNotifier<Map<String, Map<String, double>>> probabilityNotifier = ValueNotifier({});
  final ValueNotifier<String> selectedPair = ValueNotifier('frxUSDJPY');
  final StreamController<String> _pairUpdateController = StreamController<String>.broadcast();
  Stream<String> get pairUpdateStream => _pairUpdateController.stream;

  bool enableDebug = false;
  final int maxCandlesPerPair = 200; // memory-friendly

  // ----------------- Public API -----------------
  MarketAnalysisResult? latestAnalysisForSelectedPair() => _resultsCache[selectedPair.value];
  MarketAnalysisResult? getLatestAnalysis(String pair) => _resultsCache[pair];

  Future<void> selectPair(String pair) async {
    selectedPair.value = pair;
    final candles = await CandleStorageService.instance.getCandles(pair);
    final sanitized = _sanitizeCandles(candles)..sort((a, b) => a.epoch.compareTo(b.epoch));
    final prev = getLatestAnalysis(pair);
    final result = await analyzeMarket(pair, sanitized, prev: prev);
    _emitUpdatesForPair(pair, result);
  }

  Future<MarketAnalysisResult> updatePairSingleCandle(String pair, Candle candle, {bool debugPrints = false}) async {
    enableDebug = debugPrints;
    return await _updatePairCandle(pair, candle);
  }

  Future<MarketAnalysisResult> analyzePair(String pair, {bool debugPrints = false}) async {
    enableDebug = debugPrints;
    return await _analyzePairCandles(pair);
  }

  /// Called when new candle arrives
  void updatePair(String pair, Candle candle, {int timeframeMinutes = 1}) {
    final store = _candlesPerPair.putIfAbsent(pair, () => []);

    if (store.isEmpty || candle.epoch > store.last.epoch) {
      store.add(candle);
    } else if (candle.epoch == store.last.epoch) {
      store[store.length - 1] = candle;
    } else {
      if (enableDebug) debugPrint('IGNORED older candle for $pair: ${candle.epoch} < ${store.last.epoch}');
      return;
    }

    if (store.length > maxCandlesPerPair) store.removeRange(0, store.length - maxCandlesPerPair);

    final cloned = List<Candle>.from(store);
    final prev = getLatestAnalysis(pair);

    // async analysis per pair
    Future.microtask(() async {
      try {
        final sanitized = _sanitizeCandles(cloned)..sort((a, b) => a.epoch.compareTo(b.epoch));
        final res = await analyzeMarket(pair, sanitized, prev: prev, timeframeMinutes: timeframeMinutes);
        _emitUpdatesForPair(pair, res);
      } catch (e, st) {
        if (enableDebug) debugPrint('updatePair analyze error for $pair: $e\n$st');
      }
    });
  }

  // ----------------- Core Private Methods -----------------
  Future<MarketAnalysisResult> _updatePairCandle(String pair, Candle candle, {int timeframeMinutes = 1}) async {
    await _acquireLock(pair);
    try {
      final prev = getLatestAnalysis(pair);
      await CandleStorageService.instance.addCandle(pair, candle);
      final candles = await CandleStorageService.instance.getCandles(pair);
      final sanitized = _sanitizeCandles(candles)..sort((a, b) => a.epoch.compareTo(b.epoch));
      final result = await analyzeMarket(pair, sanitized, prev: prev, timeframeMinutes: timeframeMinutes);
      _emitUpdatesForPair(pair, result);
      return result;
    } finally {
      _releaseLock(pair);
    }
  }

  Future<MarketAnalysisResult> _analyzePairCandles(String pair, {int timeframeMinutes = 1}) async {
    await _acquireLock(pair);
    try {
      final candles = _sanitizeCandles(await CandleStorageService.instance.getCandles(pair))
        ..sort((a, b) => a.epoch.compareTo(b.epoch));
      if (candles.isEmpty) {
        final empty = MarketAnalysisResult.empty(pair);
        _emitUpdatesForPair(pair, empty);
        return empty;
      }
      final prev = getLatestAnalysis(pair);
      final result = await analyzeMarket(pair, candles, prev: prev, timeframeMinutes: timeframeMinutes);
      _emitUpdatesForPair(pair, result);
      return result;
    } finally {
      _releaseLock(pair);
    }
  }

  // ----------------- Analysis -----------------
  Future<MarketAnalysisResult> analyzeMarket(String pair, List<Candle> candles,
      {MarketAnalysisResult? prev, int timeframeMinutes = 1}) async {
    if (candles.isEmpty) return prev ?? MarketAnalysisResult.empty(pair);

    final lastPrice = candles.last.close;
    final forecastPrice = _forecastNextPrice(candles, 30, timeframeMinutes: timeframeMinutes);

    final atr = max(_atr(candles, 14) * timeframeMinutes, 0.0000001);
    final ema20 = _ema(candles, 20).lastOrNull ?? lastPrice;
    final ema50 = _ema(candles, 50).lastOrNull ?? lastPrice;
    final ema200 = _ema(candles, 200).lastOrNull ?? lastPrice;
    final rsi14 = _rsi(candles, 14);
    final macdHist = _macdHistogram(candles).lastOrNull ?? 0.0;
    final volumePressure = _smoothedVolume(candles);
    final orderBlockScore = _dynamicOrderBlockScore(candles);
    final structureScore = _dynamicMarketStructureScore(candles, lookback: max(5, timeframeMinutes));
    final liquidityScore = _smoothedLiquidity(candles);

    final contributions = <String, double>{
      'ATR': ((atr / lastPrice - 0.0001) * 200.0).clamp(-1.0, 1.0),
      'Volume': ((volumePressure / 3.0 - 0.5) * 0.8).clamp(-1.0, 1.0),
      'Liquidity': ((liquidityScore - 50.0) / 50.0 * 0.7).clamp(-1.0, 1.0),
      'Order': ((orderBlockScore - 50.0) / 50.0 * 0.7).clamp(-1.0, 1.0),
      'Structure': ((structureScore - 50.0) / 50.0 * 0.8).clamp(-1.0, 1.0),
      'MA': ((_maSlopePercent(candles, 20) / 100) * 0.5).clamp(-0.5, 0.5),
      'MACD': ((macdHist / max(atr, 1e-8) / 100.0) * 0.5).clamp(-0.5, 0.5),
    };

    double score = contributions.values.reduce((a, b) => a + b).clamp(-3.0, 3.0);
    final adjustedScore = score * (lerpDouble(0.95, 1.05, ((forecastPrice / lastPrice) - 0.995) / 0.01) ?? 1.0);

    double rawLongProb = _sigmoid(adjustedScore * 2.0) * 100.0;
    double longProb = _applySmoothing(prev?.probabilityLongHistory, rawLongProb, timeframeMinutes: timeframeMinutes);
    double shortProb = (100.0 - longProb).clamp(0.0, 100.0);

    final diff = longProb - shortProb;
    final direction = diff.abs() < 8.0 ? 'neutral' : (diff > 0 ? 'long' : 'short');
    final forecastDirection = forecastPrice > lastPrice ? 'long' : 'short';
    final stableDirection = (direction == forecastDirection) ? direction : 'neutral';
    final confidence = (diff.abs() / 100.0).clamp(0.0, 1.0);

    final result = MarketAnalysisResult(
      symbol: pair,
      candles: candles,
      analysisDirection: direction,
      direction: direction,
      stableDirection: stableDirection,
      probabilityLong: longProb,
      probabilityShort: shortProb,
      confidence: confidence,
      lastPrice: lastPrice,
      forecastPrice: forecastPrice,
      timestamp: DateTime.now(),
      pipTarget: max(10.0, atr * 100000),
      volumeConfirmed: volumePressure >= 50,
      rsi14: rsi14,
      ema20: ema20,
      ema50: ema50,
      ema200: ema200,
      macd: macdHist,
      macdHist: macdHist,
      atr: atr,
      probabilityLongHistory: _appendHistory(prev?.probabilityLongHistory, longProb),
      probabilityShortHistory: _appendHistory(prev?.probabilityShortHistory, shortProb),
      reasons: _buildReasonsList(longProb, shortProb,
          maSlope: (_maSlopePercent(candles, 20) / 100),
          rsi: rsi14,
          macd: macdHist,
          volumePressure: volumePressure,
          orderBlockScore: orderBlockScore,
          marketStructure: structureScore,
          liquiditySweep: liquidityScore),
      structure: structureScore >= 60 ? 'trend' : structureScore <= 40 ? 'range' : 'neutral',
    );

    if (enableDebug) {
      debugPrint('>>> [$pair] Candles:${candles.length} Last:${lastPrice.toStringAsFixed(6)} '
          'ATR:${atr.toStringAsFixed(6)} Vol:${volumePressure.toStringAsFixed(2)} '
          'Struct:${structureScore.toStringAsFixed(1)} Liqu:${liquidityScore.toStringAsFixed(1)} '
          'Score:${adjustedScore.toStringAsFixed(3)} → $direction ${longProb.toStringAsFixed(0)}/${shortProb.toStringAsFixed(0)}% '
          '(conf ${(confidence*100).toStringAsFixed(0)}%)');
    }

    return result;
  }

  // ----------------- Utilities & Indicators -----------------
  double _forecastNextPrice(List<Candle> candles, int minutesAhead, {int timeframeMinutes = 1}) {
    if (candles.length < 2) return candles.last.close;
    final ema20 = _ema(candles, 20);
    if (ema20.length < 2) return candles.last.close;
    // Multiply by minutesAhead and scale for timeframe
    return candles.last.close + (ema20.last - ema20[ema20.length - 2]) * minutesAhead * max(1, timeframeMinutes/1.0);
  }

  List<double> _appendHistory(List<double>? history, double value) {
    final h = history == null ? <double>[] : [...history];
    h.add(value);
    if (h.length > 500) h.removeAt(0);
    return h;
  }

  double _applySmoothing(List<double>? prevHistory, double current, {int timeframeMinutes = 1}) {
    if (prevHistory == null || prevHistory.isEmpty) return current;
    double alpha = (timeframeMinutes >= 5) ? 0.5 : 0.3; // adaptive smoothing
    return alpha * current + (1 - alpha) * prevHistory.last;
  }

  List<Candle> _sanitizeCandles(List<Candle> candles) {
    return candles.where((c) =>
        c.epoch > 0 &&
        [c.open, c.close, c.high, c.low].every((v) => !v.isNaN && v >= 0) &&
        c.high >= c.low).toList();
  }

  double _sigmoid(double x) => 1 / (1 + exp(-x));

  List<String> _buildReasonsList(double longProb, double shortProb,
      {required double maSlope,
      required double rsi,
      required double macd,
      double? volumePressure,
      double? orderBlockScore,
      double? marketStructure,
      double? liquiditySweep}) {
    return [
      "LongProb: ${longProb.toStringAsFixed(2)}%",
      "ShortProb: ${shortProb.toStringAsFixed(2)}%",
      "MA Slope: ${maSlope.toStringAsFixed(3)}%",
      "RSI: ${rsi.toStringAsFixed(2)}",
      "MACD Hist: ${macd.toStringAsFixed(2)}",
      "Volume: ${volumePressure?.toStringAsFixed(2) ?? 'NA'}",
      "OrderBlock: ${orderBlockScore?.toStringAsFixed(2) ?? 'NA'}",
      "Structure: ${marketStructure?.toStringAsFixed(2) ?? 'NA'}",
      "LiquiditySweep: ${liquiditySweep?.toStringAsFixed(2) ?? 'NA'}",
    ];
  }

  Future<void> _acquireLock(String symbol) async {
    while (true) {
      if (!_analysisLocks.containsKey(symbol)) {
        _analysisLocks[symbol] = Completer<void>();
        return;
      }
      await _analysisLocks[symbol]!.future;
    }
  }

  void _releaseLock(String symbol) {
    final lock = _analysisLocks.remove(symbol);
    if (lock != null && !lock.isCompleted) lock.complete();
  }

  double _atr(List<Candle> candles, int period) {
    if (candles.length < 2) return 0.0;
    double sum = 0.0;
    for (int i = 1; i < candles.length; i++) {
      final highLow = candles[i].high - candles[i].low;
      final highClose = (candles[i].high - candles[i - 1].close).abs();
      final lowClose = (candles[i].low - candles[i - 1].close).abs();
      sum += max(highLow, max(highClose, lowClose));
    }
    return sum / period;
  }

  List<double> _ema(List<Candle> candles, int period) {
    if (candles.isEmpty) return [];
    final k = 2 / (period + 1);
    List<double> ema = [];
    for (int i = 0; i < candles.length; i++) {
      ema.add(i == 0 ? candles[i].close : candles[i].close * k + ema[i - 1] * (1 - k));
    }
    return ema;
  }

  List<double> _macdHistogram(List<Candle> candles) {
    final ema12 = _ema(candles, 12);
    final ema26 = _ema(candles, 26);
    return List.generate(min(ema12.length, ema26.length), (i) => ema12[i] - ema26[i]);
  }

  double _rsi(List<Candle> candles, int period) {
    if (candles.length < 2) return 50.0;
    List<double> gains = [], losses = [];
    for (int i = 1; i < candles.length; i++) {
      final change = candles[i].close - candles[i - 1].close;
      gains.add(max(0, change));
      losses.add(max(0, -change));
    }
    final avgGain = gains.take(period).fold(0.0, (a, b) => a + b) / period;
    final avgLoss = losses.take(period).fold(0.0, (a, b) => a + b) / period;
    return avgLoss == 0 ? 100.0 : 100 - (100 / (1 + avgGain / avgLoss));
  }

  double _maSlopePercent(List<Candle> candles, int period) {
    final ema = _ema(candles, period);
    if (ema.length < 2) return 0.0;
    return ((ema.last - ema[ema.length - 2]) / ema[ema.length - 2]) * 100;
  }

  double _smoothedVolume(List<Candle> candles, [int lookback = 5]) {
    if (candles.isEmpty) return 50.0;
    final start = max(0, candles.length - lookback);
    return candles.sublist(start).map((c) => c.volume).reduce((a, b) => a + b) / (candles.length - start);
  }

  double _smoothedLiquidity(List<Candle> candles, [int lookback = 5]) {
    final v = _smoothedVolume(candles, lookback);
    return min(100, (v / 3.0) * 10.0);
  }

  double _dynamicOrderBlockScore(List<Candle> candles) {
    if (candles.isEmpty) return 50.0;
    final last = candles.last;
    final diff = (last.close - last.open).abs();
    return ((diff / max(1e-8, last.close)) * 10000).clamp(0.0, 100.0);
  }

  double _dynamicMarketStructureScore(List<Candle> candles, {int lookback = 5}) {
    if (candles.length < lookback) return 50.0;
    int up = 0, down = 0;
    for (int i = candles.length - lookback; i < candles.length - 1; i++) {
      if (candles[i + 1].high > candles[i].high) up++;
      if (candles[i + 1].low < candles[i].low) down++;
    }
    if (up >= lookback - 1) return 80.0;
    if (down >= lookback - 1) return 20.0;
    return 50.0;
  }

  void _emitUpdatesForPair(String pair, MarketAnalysisResult result) {
    _resultsCache[pair] = result;
    analysisNotifier.value = Map.from(_resultsCache);
    final probs = Map<String, Map<String, double>>.from(probabilityNotifier.value);
    probs[pair] = {'long': result.probabilityLong, 'short': result.probabilityShort};
    probabilityNotifier.value = probs;
    _pairUpdateController.add(pair);

    if (enableDebug) debugPrint('EMIT [$pair] lp:${result.probabilityLong.toStringAsFixed(0)}% sp:${result.probabilityShort.toStringAsFixed(0)}%');
  }
}
