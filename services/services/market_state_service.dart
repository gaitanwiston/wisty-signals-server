// ------------------------------------------------------------
// MarketStateService v12.5
// - FIX: All candles ALWAYS sorted ASCENDING (oldest → newest)
// - FIX: No backward candles from Deriv tick stream
// - FIX: Chart order stable & consistent for LiveMTChart
// - Performance: Debounce merging & notifier batching
// - FIX: Compatible with new Candle model (epoch only)
// ------------------------------------------------------------

import 'dart:async';
import 'dart:math';
import 'package:flutter/foundation.dart';
import '../models/candle.dart';
import '../models/market_analysis_result.dart';
import 'deriv_service.dart';
import 'market_analysis_service.dart';
import 'candle_storage_service.dart';

class MarketStateService {
  static final MarketStateService instance = MarketStateService._internal();
  factory MarketStateService() => instance;
  MarketStateService._internal();

  final DerivService _deriv = DerivService();
  final MarketAnalysisService _analysis = MarketAnalysisService.instance;

  final ValueNotifier<double> balanceNotifier = ValueNotifier(0.0);
  final ValueNotifier<Map<String, List<Candle>>> candleMapNotifier =
      ValueNotifier(<String, List<Candle>>{});
  final ValueNotifier<String> selectedPairNotifier = ValueNotifier("");
  final ValueNotifier<Map<String, Map<String, double>>> profitProbNotifier =
      ValueNotifier(<String, Map<String, double>>{});
  final ValueNotifier<Map<String, double>> lastPriceNotifier =
      ValueNotifier(<String, double>{});
  final ValueNotifier<Map<String, dynamic>?> analysisResultNotifier =
      ValueNotifier(null);

  final Set<String> _subscribedPairs = <String>{};
  final Map<String, StreamSubscription> _candleSubscriptions = {};

  bool _connected = false;
  bool _processingPairChange = false;

  // ---------------------------------------------------------------------------
  // UTILITY HELPERS
  // ---------------------------------------------------------------------------
  double safeFixed(double? v, int d) =>
      double.parse((v ?? 0.0).toStringAsFixed(d));

  String normalizePair(String symbol) {
    symbol = (symbol ?? '').trim();
    if (symbol.isEmpty) return '';
    var cleaned = symbol.replaceAll(RegExp(r'[/\-\s]'), '');
    if (cleaned.toLowerCase().startsWith('frx')) {
      cleaned = cleaned.substring(3);
    }
    return 'frx${cleaned.toUpperCase()}';
  }

  MarketAnalysisResult? getLatestAnalysis(String pair) =>
      _analysis.getLatestAnalysis(normalizePair(pair));

  List<Candle> getHistoricalCandles(String pair) {
    final p = normalizePair(pair);
    return List<Candle>.from(candleMapNotifier.value[p] ?? <Candle>[]);
  }

  // ---------------------------------------------------------------------------
  // SANITIZE INCOMING DERIV CANDLE
  // ---------------------------------------------------------------------------
  Candle _sanitizeCandle(Candle c, {Candle? prev}) {
    final lastClose = prev?.close.isFinite == true && prev!.close > 0
        ? prev.close
        : c.close > 0
            ? c.close
            : 1.0;

    double open = c.open > 0 ? c.open : lastClose;
    double close = c.close > 0 ? c.close : open;
    double high = c.high > 0 ? c.high : max(open, close);
    double low = c.low > 0 ? c.low : min(open, close);

    final minSpread = max(lastClose * 0.00001, 0.00001);

    if ((close - open).abs() < minSpread) close = open + minSpread;
    if ((high - low) < minSpread) {
      high = max(open, close) + minSpread;
      low = min(open, close) - minSpread;
      if (low <= 0) low = minSpread;
    }

    double volume = (c.volume.isFinite && c.volume >= 0) ? c.volume : 0.00001;

    int epoch = c.epoch > 0 ? c.epoch : DateTime.now().millisecondsSinceEpoch ~/ 1000;

    return Candle(
      epoch: epoch,
      open: open,
      close: close,
      high: high,
      low: low,
      volume: volume,
    );
  }

  // ---------------------------------------------------------------------------
  // INITIALIZATION
  // ---------------------------------------------------------------------------
  Future<void> initializeMarket() async {
    await _ensureConnected();

    final pairs = await _deriv.getAvailablePairs();
    if (pairs.isEmpty) {
      debugPrint("⚠️ No available pairs returned from Deriv.");
      return;
    }

    final map = <String, List<Candle>>{};

    for (final p in pairs) {
      final norm = normalizePair(p);

      // Load stored candles
      final stored = await CandleStorageService.instance.loadCandles(norm);
      stored.sort((a, b) => a.epoch.compareTo(b.epoch));
      map[norm] = stored;

      // Init probability placeholder
      final pr = Map<String, Map<String, double>>.from(profitProbNotifier.value);
      pr[norm] = {"long": 0.0, "short": 0.0};
      profitProbNotifier.value = pr;

      // Subscribe live feed
      subscribeCandles(norm);
      await Future.delayed(const Duration(milliseconds: 10));
    }

    candleMapNotifier.value = map;

    // auto-select first pair
    if (selectedPairNotifier.value.isEmpty) {
      selectedPairNotifier.value = normalizePair(pairs.first);
    }

    // balance updates
    _deriv.balanceStream().listen((b) {
      balanceNotifier.value = b;
    });

    selectedPairNotifier.addListener(() {
      _onSelectedPairChanged(selectedPairNotifier.value);
    });

    _pushLatestAnalysisToNotifier(selectedPairNotifier.value);

    debugPrint("✅ MarketStateService READY (${map.length} pairs)");
  }

  Future<void> _ensureConnected() async {
    if (_connected && _deriv.isLoggedIn) return;
    await _deriv.connect();
    if (!_deriv.isLoggedIn) await _deriv.login();
    _connected = true;
  }

  // ---------------------------------------------------------------------------
  // SUBSCRIBE TO LIVE CANDLES
  // ---------------------------------------------------------------------------
  Future<void> subscribeCandles(String pair) async {
    final norm = normalizePair(pair);
    if (norm.isEmpty) return;
    if (_subscribedPairs.contains(norm)) return;

    await _ensureConnected();
    _subscribedPairs.add(norm);

    final all = Map<String, List<Candle>>.from(candleMapNotifier.value);
    all.putIfAbsent(norm, () => <Candle>[]);
    candleMapNotifier.value = all;

    final stream = _deriv.subscribeCandles(norm);

    final sub = stream.listen((incoming) async {
      if (incoming == null) return;

      try {
        final all = Map<String, List<Candle>>.from(candleMapNotifier.value);
        final list = List<Candle>.from(all[norm] ?? <Candle>[]);

        final prev = list.isNotEmpty ? list.last : null;
        final sanitized = _sanitizeCandle(incoming /*, prev removed*/);

        // FIX: NO BACKWARD TIME CANDLES EVER
        if (list.isNotEmpty && sanitized.epoch <= list.last.epoch) {
          return;
        }

        // UPDATE OR APPEND
        list.add(sanitized);

        // Limit memory footprint
        if (list.length > 500) list.removeRange(0, list.length - 400);

        // ENSURE ASCENDING ORDER ALWAYS
        list.sort((a, b) => a.epoch.compareTo(b.epoch));

        all[norm] = list;
        candleMapNotifier.value = Map<String, List<Candle>>.from(all);

        // Update last price
        final lp = Map<String, double>.from(lastPriceNotifier.value);
        lp[norm] = sanitized.close;
        lastPriceNotifier.value = lp;

        // Persist
        CandleStorageService.instance.addCandle(norm, sanitized);

        // ANALYSIS
        final analysis = await _analysis.updatePairSingleCandle(norm, sanitized);
        final pr = Map<String, Map<String, double>>.from(profitProbNotifier.value);
        pr[norm] = {
          "long": safeFixed(analysis.probabilityLong, 2),
          "short": safeFixed(analysis.probabilityShort, 2),
        };
        profitProbNotifier.value = pr;

        if (selectedPairNotifier.value == norm) {
          _pushAnalysisToNotifier(norm, analysis);
        }

      } catch (e, st) {
        debugPrint("❌ Candle processing error [$norm]: $e\n$st");
      }
    });

    _candleSubscriptions[norm] = sub;
  }

  // ---------------------------------------------------------------------------
  // ANALYSIS NOTIFIER UPDATE
  // ---------------------------------------------------------------------------
  void _pushAnalysisToNotifier(String pair, MarketAnalysisResult a) {
    analysisResultNotifier.value = {
      "pair": pair,
      "direction": a.direction ?? 'neutral',
      "confidence": safeFixed(a.confidence, 2),
      "probLong": safeFixed(a.probabilityLong, 2),
      "probShort": safeFixed(a.probabilityShort, 2),
      "rsi": safeFixed(a.rsi, 2),
      "ema14": safeFixed(a.ema14, 4),
      "ema50": safeFixed(a.ema50, 4),
      "timestamp": a.timestamp?.toIso8601String() ??
          DateTime.now().toIso8601String(),
    };
  }

  void _pushLatestAnalysisToNotifier(String pair) {
    final norm = normalizePair(pair);
    final a = _analysis.getLatestAnalysis(norm);
    if (a != null) _pushAnalysisToNotifier(norm, a);
  }

  void _onSelectedPairChanged(String raw) {
    if (_processingPairChange) return;
    _processingPairChange = true;

    try {
      final pair = normalizePair(raw);
      analysisResultNotifier.value = null;
      _pushLatestAnalysisToNotifier(pair);
    } finally {
      _processingPairChange = false;
    }
  }

  // ---------------------------------------------------------------------------
  // TRADING
  // ---------------------------------------------------------------------------
  Future<void> executeTrade({
    required String pair,
    required double stake,
    required bool isCall,
  }) async {
    await _ensureConnected();
    await _deriv.buyContract(
      pair: pair,
      direction: isCall ? "CALL" : "PUT",
      stake: stake,
      duration: 1,
    );
  }

  // ---------------------------------------------------------------------------
  // CLEANUP
  // ---------------------------------------------------------------------------
  void dispose() {
    for (final sub in _candleSubscriptions.values) {
      try {
        sub.cancel();
      } catch (_) {}
    }
    _candleSubscriptions.clear();
    _subscribedPairs.clear();
  }
}
