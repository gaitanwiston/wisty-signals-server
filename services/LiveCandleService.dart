// lib/src/services/live_candle_service.dart
import 'dart:async';
import 'dart:math';
import '../models/candle.dart';
import 'market_state_service.dart';

class LiveCandleService {
  // ================= SINGLETON =================
  static final LiveCandleService instance = LiveCandleService._internal();
  factory LiveCandleService() => instance;
  LiveCandleService._internal();

  final MarketStateService _marketState = MarketStateService.instance;
  final Map<String, StreamController<Candle>> _liveControllers = {};

  /// Subscribe to live candle updates for a pair
  Stream<Candle> subscribeLiveCandles(String pair) {
    pair = _marketState.normalizePair(pair);

    final controller = _liveControllers.putIfAbsent(
      pair,
      () => StreamController<Candle>.broadcast(),
    );

    // Listen to DerivService live candles through MarketStateService
    _marketState.subscribeCandlesStream(pair).listen((candle) {
      _updateLiveCandle(pair, candle, controller);
    });

    return controller.stream;
  }

  void _updateLiveCandle(
      String pair, Candle newCandle, StreamController<Candle> controller) {
    final history = _marketState.getHistory(pair);
    if (history.isEmpty) {
      // No candles yet, add first
      _marketState.addCandle(pair, newCandle);
      controller.add(newCandle);
      return;
    }

    final last = history.last;
    if (_isSameCandleEpoch(last, newCandle)) {
      // Update last candle dynamically
      final updated = Candle(
        epoch: last.epoch,
        open: last.open,
        close: newCandle.close,
        high: max(last.high, newCandle.high),
        low: min(last.low, newCandle.low),
        volume: last.volume + newCandle.volume,
      );

      _marketState.updateLastCandle(pair, updated);
      controller.add(updated);
    } else if (newCandle.epoch > last.epoch) {
      // New candle
      _marketState.addCandle(pair, newCandle);
      controller.add(newCandle);
    }
  }

  bool _isSameCandleEpoch(Candle last, Candle candle) {
    // Compare by epoch for 1-minute candles (adjust if needed)
    return last.epoch == candle.epoch;
  }

  /// Dispose all controllers
  void dispose() {
    for (final c in _liveControllers.values) {
      if (!c.isClosed) c.close();
    }
    _liveControllers.clear();
  }
}
