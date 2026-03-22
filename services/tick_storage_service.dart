// lib/src/services/tick_storage_service.dart
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/candle.dart';
import 'candle_storage_service.dart';

class TickStorageService {
  static final TickStorageService instance = TickStorageService._internal();
  TickStorageService._internal();

  /// Ticks per 1-minute candle
  static const int ticksPerCandle = 60;

  /// Save a tick
  Future<void> addTick(String symbol, double price) async {
    final prefs = await SharedPreferences.getInstance();

    // Load existing ticks
    String key = "ticks_$symbol";
    final raw = prefs.getString(key);

    List<double> ticks = [];
    if (raw != null) {
      ticks = (jsonDecode(raw) as List).map((e) => e as double).toList();
    }

    ticks.add(price);

    // If we reached one candle
    if (ticks.length >= ticksPerCandle) {
      await _convertToCandle(symbol, ticks);
      ticks.clear(); // clear tick buffer
    }

    // Save ticks
    await prefs.setString(key, jsonEncode(ticks));
  }

  /// Convert tick list → Candle(1m)
  Future<void> _convertToCandle(String symbol, List<double> ticks) async {
    if (ticks.isEmpty) return;

    final double open = ticks.first;
    final double close = ticks.last;
    final double high = ticks.reduce((a, b) => a > b ? a : b);
    final double low = ticks.reduce((a, b) => a < b ? a : b);

    final candle = Candle(
      open: open,
      high: high,
      low: low,
      close: close,
      timestamp: DateTime.now().millisecondsSinceEpoch,
    );

    await CandleStorageService.instance.addCandle(symbol, candle);
  }
}
