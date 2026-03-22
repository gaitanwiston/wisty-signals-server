// lib/src/services/candles/candle_subscription_service.dart
import 'dart:async';
import 'dart:math';
import 'package:flutter/foundation.dart';
import '../../models/candle.dart';
import '../deriv_service.dart';

class CandleState {
  final ValueNotifier<List<Candle>> candles = ValueNotifier([]);
}

class CandleSubscriptionService {
  CandleSubscriptionService._internal();
  static final CandleSubscriptionService instance = CandleSubscriptionService._internal();

  final DerivService _deriv = DerivService();
  final Map<String, CandleState> _states = {};
  final Set<String> _subscribedPairs = {};

  CandleState stateFor(String pair) {
    return _states.putIfAbsent(pair, () => CandleState());
  }

  void subscribePair(String pair, {int granularity = 60}) {
    if (_subscribedPairs.contains(pair)) return;
    _subscribedPairs.add(pair);

    _deriv.subscribeCandles(pair, granularity: granularity).listen((candle) {
      final state = stateFor(pair);
      final candles = List<Candle>.from(state.candles.value);

      if (candles.isEmpty) {
        candles.add(candle);
      } else {
        final last = candles.last;
        if (last.epoch == candle.epoch) {
          candles[candles.length - 1] = candle; // update current candle
        } else if (candle.epoch > last.epoch) {
          candles.add(candle); // new candle
          if (candles.length > 500) candles.removeAt(0); // max 500 candles
        }
      }

      state.candles.value = candles; // notify listeners
    });
  }
}
