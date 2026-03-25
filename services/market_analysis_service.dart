import 'dart:async';
import 'dart:math';
import 'deriv_service.dart';
import '../models/market_analysis_result.dart';
import '../models/candle.dart' as model;

/// ================= ENUMS =================
enum MarketBias { buy, sell, none }
enum EntryConfirmation { bullish, bearish, none }

/// ================= MARKET ANALYSIS SERVICE =================
class MarketAnalysisService {
  // ================= SINGLETON =================
  MarketAnalysisService._internal();
  static final MarketAnalysisService instance = MarketAnalysisService._internal();
  factory MarketAnalysisService() => instance;

  // ================= STREAM =================
  final StreamController<MarketAnalysisResult> _controller = StreamController.broadcast();
  Stream<MarketAnalysisResult> get analysisStream => _controller.stream;

  // ================= STORAGE =================
  final Map<String, List<model.Candle>> _candlesM1 = {};
  final Map<String, List<model.Candle>> _candlesM5 = {};
  final Map<String, List<model.Candle>> _candlesM15 = {};
  final Map<String, List<model.Candle>> _candlesM30 = {};
  final Map<String, MarketAnalysisResult> _latest = {};

  // ================= CONFIG =================
  int minCandles = 2000;
  int maxCandles = 2500; // sliding window
  int rsiPeriod = 14;
  int atrPeriod = 14;
  double defaultRR = 2.0;

  final Set<String> _activePairs = {};
  Timer? _timer;

  /// ================= START ANALYSIS =================
  Future<void> startPairs(List<String> pairs) async {
    final deriv = DerivService.instance;
    await deriv.connect();

    print("🚀 STARTING MARKET ANALYSIS...");

    for (var p in pairs) {
      _activePairs.add(p);
      print("📩 Subscribing: $p");

      await deriv.subscribeCandles(p);
      print("ℹ Historical + live ticks subscription done for $p");

      // 🔥 Load history into analysis immediately
      Future.delayed(const Duration(seconds: 2), () {
        final history = deriv.getCachedCandles(p);
        if (history.isNotEmpty) {
          _candlesM1[p] = List.from(history);
          print("📦 HISTORY INSERTED → $p candles=${history.length}");
        } else {
          print("❌ NO HISTORY FOUND FOR $p");
        }
      });

      // Listen to live ticks
      deriv.wsStream.listen((data) {
        final tick = data['tick'];
        if (tick != null && tick['symbol'] == p) {
          final price = double.tryParse(tick['quote'].toString()) ?? 0.0;
          final epoch = int.tryParse(tick['epoch'].toString()) ?? 0;
          if (epoch == 0) return;
          _onTick(p, price, epoch);
        }
      });
    }

    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      for (final pair in _activePairs) {
        final candles = _candlesM1[pair] ?? [];
        if (candles.length < minCandles) continue;

        // 🔥 Debug: Processing pair
        print("📦 PROCESSING $pair candles=${candles.length}");
        _process(pair, candles);
      }
    });
  }

  /// ================= PROCESS TICK =================
  void _onTick(String pair, double price, int epoch) {
    final list = _candlesM1.putIfAbsent(pair, () => []);
    final bucket = (epoch ~/ 60) * 60;

    if (list.isEmpty || list.last.epoch != bucket) {
      list.add(model.Candle(
        epoch: bucket,
        open: price,
        close: price,
        high: price,
        low: price,
        volume: 1,
      ));

      if (list.length > maxCandles) {
        list.removeAt(0);
      }
    } else {
      final last = list.last;
      list[list.length - 1] = model.Candle(
        epoch: last.epoch,
        open: last.open,
        close: price,
        high: max(last.high, price),
        low: min(last.low, price),
        volume: last.volume + 1,
      );
    }

    // 🔥 Debug: live tick
    print("📈 $pair LIVE candle update → total=${list.length}");
  }

  /// ================= PROCESS ANALYSIS =================
  void _process(String pair, List<model.Candle> m1) {
    _candlesM5[pair] = _aggregate(m1, 5);
    _candlesM15[pair] = _aggregate(m1, 15);
    _candlesM30[pair] = _aggregate(m1, 30);

    final result = _analyze(
      pair,
      m1: m1,
      m5: _candlesM5[pair]!,
      m15: _candlesM15[pair]!,
      m30: _candlesM30[pair]!,
    );

    _latest[pair] = result;
    _controller.add(result);
  }

  /// ================= ANALYZE =================
  MarketAnalysisResult _analyze(
    String pair, {
    required List<model.Candle> m1,
    required List<model.Candle> m5,
    required List<model.Candle> m15,
    required List<model.Candle> m30,
  }) {
    final ok = <String>[];
    final no = <String>[];

    final bias = _structure(m30);
    final ema50 = _ema(m15, 50);
    final ema200 = _ema(m15, 200);

    final emaBuy = ema50.isNotEmpty && ema200.isNotEmpty && ema50.last > ema200.last && ema50.last > ema50[ema50.length - 2];
    final emaSell = ema50.isNotEmpty && ema200.isNotEmpty && ema50.last < ema200.last && ema50.last < ema50[ema50.length - 2];

    final rsi = _rsi(m15, rsiPeriod);
    final conf = _confirmation(m1, bias);

    final entry = m1.last.close;
    final sl = _atrSL(m1, bias);
    final tp = _tp(entry, sl, bias);

    final rrOk = _rr(entry, sl, tp);
    final sessionOk = _session();

    final canBuy = bias == MarketBias.buy && emaBuy && rsi > 50 && conf == EntryConfirmation.bullish && rrOk && sessionOk;
    final canSell = bias == MarketBias.sell && emaSell && rsi < 50 && conf == EntryConfirmation.bearish && rrOk && sessionOk;

    /// 🔥 Debug: Full analysis
    print("📊 $pair BUY=$canBuy SELL=$canSell candles=${m1.length} Reason: $no");
    print("🧠 $pair Bias=$bias | EMA Buy=$emaBuy EMA Sell=$emaSell | RSI=${rsi.toStringAsFixed(2)} | Conf=$conf | RR=$rrOk | Session=$sessionOk");

    if (canBuy || canSell) {
      ok.add("All conditions met");
    } else {
      if (bias == MarketBias.none) no.add("No structure");
      if (!(emaBuy || emaSell)) no.add("EMA fail");
      if (!(rsi > 50 || rsi < 50)) no.add("RSI fail");
      if (conf == EntryConfirmation.none) no.add("No confirmation");
      if (!rrOk) no.add("RR fail");
      if (!sessionOk) no.add("Session fail");
    }

    return MarketAnalysisResult(
      symbol: pair,
      candles: m1,
      candlesM5: m5,
      candlesM15: m15,
      candlesM30: m30,
      structureValid: bias != MarketBias.none,
      emaValid: emaBuy || emaSell,
      rsiValid: true,
      confirmationValid: conf != EntryConfirmation.none,
      filtersValid: rrOk && sessionOk,
      canBuy: canBuy,
      canSell: canSell,
      structureBuy: bias == MarketBias.buy,
      structureSell: bias == MarketBias.sell,
      biasIsBuy: bias == MarketBias.buy,
      ema50: ema50,
      ema200: ema200,
      indicators: {'rsi': rsi},
      entryCandles: [m1.length - 1],
      structurePoints: const [],
      conditionsMet: ok,
      reasonsFailed: no,
      stopLoss: sl,
      takeProfit: tp,
    );
  }

  /// ================= HELPERS =================
  double _rsi(List<model.Candle> c, int p) {
    if (c.length < p + 1) return 50;
    double gain = 0, loss = 0;
    for (int i = c.length - p; i < c.length; i++) {
      final d = c[i].close - c[i - 1].close;
      if (d > 0) gain += d;
      else loss += d.abs();
    }
    if (gain + loss == 0) return 50;
    final rs = gain / max(loss, 0.00001);
    return 100 - (100 / (1 + rs));
  }

  List<double> _ema(List<model.Candle> c, int p) {
    if (c.length < p) return [];
    double sma = 0;
    for (int i = c.length - p; i < c.length; i++) sma += c[i].close;
    sma /= p;
    final k = 2 / (p + 1);
    double ema = sma;
    final out = [ema];
    for (int i = c.length - p + 1; i < c.length; i++) {
      ema = c[i].close * k + ema * (1 - k);
      out.add(ema);
    }
    return out;
  }

  /// 🔹 Improved structure: trend-based over last 10 candles
  MarketBias _structure(List<model.Candle> c) {
    if (c.length < 10) return MarketBias.none;
    int up = 0, down = 0;
    for (int i = c.length - 10; i < c.length; i++) {
      if (c[i].close > c[i].open) up++;
      if (c[i].close < c[i].open) down++;
    }
    if (up >= 7) return MarketBias.buy;
    if (down >= 7) return MarketBias.sell;
    return MarketBias.none;
  }

  /// 🔹 Improved confirmation: last 3 candles trend
  EntryConfirmation _confirmation(List<model.Candle> c, MarketBias bias) {
    if (c.length < 3) return EntryConfirmation.none;
    final last = c.last;
    final prev2 = c[c.length - 2];
    final prev3 = c[c.length - 3];

    if (bias == MarketBias.buy && last.close > prev2.close && prev2.close > prev3.close) return EntryConfirmation.bullish;
    if (bias == MarketBias.sell && last.close < prev2.close && prev2.close < prev3.close) return EntryConfirmation.bearish;
    return EntryConfirmation.none;
  }

  double _atrSL(List<model.Candle> c, MarketBias bias) {
    final atr = _atr(c, atrPeriod);
    final entry = c.last.close;
    return bias == MarketBias.buy ? entry - atr : entry + atr;
  }

  double _tp(double entry, double sl, MarketBias bias) {
    final risk = (entry - sl).abs();
    if (risk == 0) return 0;
    return bias == MarketBias.buy ? entry + risk * defaultRR : entry - risk * defaultRR;
  }

  double _atr(List<model.Candle> c, int p) {
    if (c.length < p + 1) return 0;
    double sum = 0;
    for (int i = c.length - p; i < c.length; i++) {
      final high = c[i].high;
      final low = c[i].low;
      final prev = c[i - 1].close;
      final tr = max(high - low, max((high - prev).abs(), (low - prev).abs()));
      sum += tr;
    }
    return sum / p;
  }

  bool _rr(double entry, double sl, double tp) {
    if (sl == 0 || tp == 0) return false;
    final risk = (entry - sl).abs();
    final reward = (tp - entry).abs();
    return reward / risk >= defaultRR;
  }

  bool _session() {
    final now = DateTime.now().toUtc().add(const Duration(hours: 3));
    return now.hour >= 8 && now.hour <= 22;
  }

  List<model.Candle> _aggregate(List<model.Candle> c, int tf) {
    final out = <model.Candle>[];
    for (final candle in c) {
      final bucket = (candle.epoch ~/ (tf * 60)) * (tf * 60);
      if (out.isEmpty || out.last.epoch != bucket) {
        out.add(model.Candle(
          epoch: bucket,
          open: candle.open,
          close: candle.close,
          high: candle.high,
          low: candle.low,
          volume: candle.volume,
        ));
      } else {
        final last = out.last;
        out[out.length - 1] = model.Candle(
          epoch: last.epoch,
          open: last.open,
          close: candle.close,
          high: max(last.high, candle.high),
          low: min(last.low, candle.low),
          volume: last.volume + candle.volume,
        );
      }
    }
    return out;
  }

  /// ================= LATEST RESULTS =================
  Map<String, MarketAnalysisResult?> latestForAllPairsMap() => Map<String, MarketAnalysisResult?>.from(_latest);
  MarketAnalysisResult? latestFor(String pair) => _latest[pair];
}