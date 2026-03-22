import 'package:flutter/foundation.dart';
import '../../models/candle.dart';

/// ===========================================
/// LIVE CANDLE STATE
/// Aggregates live + history candles
/// MT4 / MT5 style (LEFT ➜ RIGHT)
/// ===========================================
class LiveCandleState {
  /// Holds full candle list for UI
  final ValueNotifier<List<Candle>> candles =
      ValueNotifier<List<Candle>>([]);

  /// Load initial history
  void setHistory(List<Candle> history) {
    final sorted = List<Candle>.from(history)
      ..sort((a, b) => a.epoch.compareTo(b.epoch));

    candles.value = List.unmodifiable(sorted);
  }

  /// Insert or update candle (LIVE)
  void upsert(Candle candle) {
    final list = List<Candle>.from(candles.value);

    if (list.isEmpty) {
      candles.value = [candle];
      return;
    }

    final last = list.last;

    // UPDATE current candle
    if (candle.epoch == last.epoch) {
      list[list.length - 1] = candle;
    }
    // NEW candle (future / right side)
    else if (candle.epoch > last.epoch) {
      list.add(candle);
    } else {
      // ignore old candle
      return;
    }

    candles.value = List.unmodifiable(list);
  }

  /// Clear all candles (on pair switch)
  void reset() {
    candles.value = [];
  }
}
