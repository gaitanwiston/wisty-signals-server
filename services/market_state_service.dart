import 'dart:async';
import 'package:flutter/foundation.dart';

import '../models/candle.dart';
import '../models/market_analysis_result.dart';
import '../models/market_pair.dart';
import 'deriv_service.dart';
import 'market_analysis_service.dart';

class MarketStateService {
  // ================= SINGLETON =================
  MarketStateService._internal();
  static final MarketStateService instance = MarketStateService._internal();
  factory MarketStateService() => instance;

  // ================= NOTIFIERS (PUBLIC) =================
  final ValueNotifier<double> balanceNotifier = ValueNotifier<double>(0.0);
  final ValueNotifier<MarketAnalysisResult?> analysisNotifier = ValueNotifier(null);
  final ValueNotifier<String?> selectedPairNotifier = ValueNotifier(null);
  final ValueNotifier<List<MarketPair>> availablePairsNotifier = ValueNotifier([]);
  final ValueNotifier<bool> goLongEnabled = ValueNotifier(false);
  final ValueNotifier<bool> goShortEnabled = ValueNotifier(false);

  // ================= INTERNAL =================
  final DerivService _deriv = DerivService.instance;

  bool _initialized = false;
  String? _activePair;

  StreamSubscription<double>? _balanceSub;
  StreamSubscription<List<Candle>>? _activeCandleSub;
  StreamSubscription<MarketAnalysisResult>? _analysisSub;

  final Map<String, List<Candle>> _historyCache = {};
  final StreamController<List<Candle>> _activeCandleCtrl = StreamController<List<Candle>>.broadcast();

  // Callback for trade alerts
  void Function(String pair, bool canBuy, bool canSell)? tradeAlertCallback;

  // ================= INITIALIZE =================
  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;

    // 🔁 Listen BALANCE from Deriv
    _balanceSub?.cancel();
    _balanceSub = _deriv.balanceStream().listen((bal) {
      debugPrint("💰 MarketState got balance = $bal");
      balanceNotifier.value = bal;
    });

    // 🔁 Listen AVAILABLE PAIRS from Deriv
    _deriv.availablePairsStream().listen((pairs) {
      final marketPairs = pairs.map((e) => MarketPair(symbol: e)).toList();
      _setAvailablePairs(marketPairs);
    });

    // 🔁 Listen ANALYSIS stream
    _analysisSub?.cancel();
    _analysisSub = MarketAnalysisService.instance.analysisStream.listen((result) {
      final normalized = _normalizePair(result.symbol);

      _historyCache[normalized] = result.candles;

      if (_activePair == normalized) {
        analysisNotifier.value = result;
        goLongEnabled.value = result.canBuy;
        goShortEnabled.value = result.canSell;

        if (tradeAlertCallback != null && (result.canBuy || result.canSell)) {
          tradeAlertCallback!(result.symbol, result.canBuy, result.canSell);
        }
      }
    });
  }

  // ================= GETTERS =================
  MarketAnalysisResult? get latestAnalysis => analysisNotifier.value;

  List<Candle> getHistory(String pair) => _historyCache[_normalizePair(pair)] ?? const [];

  Stream<List<Candle>> candleStream() => _activeCandleCtrl.stream;

  MarketAnalysisResult? getAnalysis(String pair) {
    final normalized = _normalizePair(pair);
    if (_activePair != normalized) return null;
    return analysisNotifier.value;
  }

  int getBlockedCount(String pair) {
    final analysis = getAnalysis(pair);
    if (analysis == null) return 0;
    if (!analysis.canBuy && !analysis.canSell) return 1;
    return 0;
  }

  // ================= NORMALIZE =================
  String _normalizePair(String pair) {
    var p = pair.toUpperCase().replaceAll('FRX', '');
    return 'FRX$p';
  }

  // ================= SET ACTIVE PAIR =================
  Future<void> setActivePair(String pair) async {
    final normalized = _normalizePair(pair);
    if (_activePair == normalized) return;

    debugPrint("📡 MarketState switching active pair to $normalized");

    _activePair = normalized;
    selectedPairNotifier.value = normalized;

    analysisNotifier.value = null;
    goLongEnabled.value = false;
    goShortEnabled.value = false;

    _activeCandleSub?.cancel();
    _activeCandleSub = null;

    await _subscribeActivePair();
  }

  Future<void> _subscribeActivePair() async {
    final pair = _activePair!;
    await _deriv.subscribeCandles(pair);

    _activeCandleSub = _deriv.candleStream(pair).listen((candles) {
      if (candles.isEmpty) return;

      final safeCopy = List<Candle>.unmodifiable(candles);
      _historyCache[pair] = safeCopy;

      _emitActiveCandles(safeCopy);
    });

    // Emit cached immediately
    final cached = _historyCache[pair];
    if (cached != null && cached.isNotEmpty) {
      _emitActiveCandles(cached);
    }
  }

  // ================= UI STREAM =================
  void _emitActiveCandles(List<Candle> candles) {
    if (!_activeCandleCtrl.isClosed) {
      _activeCandleCtrl.add(candles);
    }
  }

  // ================= AVAILABLE PAIRS =================
  void _setAvailablePairs(List<MarketPair> pairs) {
    availablePairsNotifier.value = pairs;
    if (_activePair == null && pairs.isNotEmpty) {
      Future.microtask(() => setActivePair(pairs.first.symbol));
    }
  }

  // ================= DISPOSE =================
  void dispose() {
    _balanceSub?.cancel();
    _activeCandleSub?.cancel();
    _analysisSub?.cancel();

    balanceNotifier.dispose();
    analysisNotifier.dispose();
    selectedPairNotifier.dispose();
    availablePairsNotifier.dispose();
    goLongEnabled.dispose();
    goShortEnabled.dispose();

    _activeCandleCtrl.close();
  }
}
