import 'dart:convert';
import 'dart:async';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/candle.dart';

/// 🔥 ULTRA-COMPLETE CandleStorageService v6.3 (Mutable + Epoch-compatible)
class CandleStorageService {
  static final CandleStorageService instance = CandleStorageService._internal();
  CandleStorageService._internal();

  static const int maxCandles = 500000;

  bool _initialized = false;
  final Map<String, List<Candle>> _cache = {};
  final Set<String> _subscribedSymbols = {};

  /// ----------------------------------------------------
  /// INIT SYMBOLS
  /// ----------------------------------------------------
  Future<void> initSymbols(List<String> symbols) async {
    if (_initialized) return;

    final prefs = await SharedPreferences.getInstance();
    for (final s in symbols) {
      final sym = _normalizeSymbol(s);
      final key = 'candles_$sym';

      if (!prefs.containsKey(key)) {
        await prefs.setString(key, json.encode([]));
      }

      // preload cache
      final raw = prefs.getString(key);
      _cache[sym] = (raw == null
          ? <Candle>[]
          : (json.decode(raw) as List)
              .map((e) => Candle.fromJson(e))
              .toList()
            ..sort((a, b) => a.epoch.compareTo(b.epoch)));
    }

    _initialized = true;
  }

  /// ----------------------------------------------------
  /// GET CANDLES (cache preferred)
  /// ----------------------------------------------------
  Future<List<Candle>> getCandles(String symbol) async {
    final sym = _normalizeSymbol(symbol);
    if (_cache.containsKey(sym)) return _cache[sym]!;
    return await loadCandles(sym);
  }

  /// ----------------------------------------------------
  /// LOAD CANDLES (from SharedPreferences)
  /// ----------------------------------------------------
  Future<List<Candle>> loadCandles(String symbol) async {
    try {
      final sym = _normalizeSymbol(symbol);
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('candles_$sym');
      if (raw == null) {
        _cache[sym] = [];
        return [];
      }
      final candles = (json.decode(raw) as List)
          .map((e) => Candle.fromJson(e))
          .toList()
        ..sort((a, b) => a.epoch.compareTo(b.epoch));
      _cache[sym] = candles;
      return candles;
    } catch (e) {
      return [];
    }
  }

  /// ----------------------------------------------------
  /// SAVE CANDLES (overwrite + trim + validation)
  /// ----------------------------------------------------
  Future<void> saveCandles(String symbol, List<Candle> candles) async {
    try {
      final sym = _normalizeSymbol(symbol);
      final prefs = await SharedPreferences.getInstance();
      candles = candles.where(_isValidCandle).map(_roundCandle).toList();
      candles.sort((a, b) => a.epoch.compareTo(b.epoch));

      if (candles.length > maxCandles) {
        candles = candles.sublist(candles.length - maxCandles);
      }

      await prefs.setString('candles_$sym', json.encode(candles.map((c) => c.toJson()).toList()));
      _cache[sym] = candles;
    } catch (e) {
      // ignore errors
    }
  }

  /// ----------------------------------------------------
  /// ADD NEW CANDLE (Deriv-friendly)
  /// ----------------------------------------------------
  Future<void> addCandle(String symbol, Candle newCandle) async {
    final sym = _normalizeSymbol(symbol);
    List<Candle> candles = await getCandles(sym);

    if (!_isValidCandle(newCandle)) return;

    if (candles.isEmpty) {
      candles = [_roundCandle(newCandle)];
      await saveCandles(sym, candles);
      return;
    }

    final lastIndex = candles.length - 1;
    final last = candles[lastIndex];

    // SAME EPOCH: overwrite last
    if (newCandle.epoch == last.epoch) {
      candles[lastIndex] = _roundCandle(newCandle);
      await saveCandles(sym, candles);
      return;
    }

    // NEWER EPOCH: append
    if (newCandle.epoch > last.epoch) {
      candles.add(_roundCandle(newCandle));
      if (candles.length > maxCandles) {
        candles = candles.sublist(candles.length - maxCandles);
      }
      await saveCandles(sym, candles);
      return;
    }

    // OLDER EPOCH: ignore
  }

  /// ----------------------------------------------------
  /// ADD TICK -> Candle (epoch-based aggregation)
  /// ----------------------------------------------------
  Future<void> addTick(String symbol, double price, double volume, {int granularity = 60}) async {
    final sym = _normalizeSymbol(symbol);
    List<Candle> candles = await getCandles(sym);

    final int seconds = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final int currentEpoch = (seconds ~/ granularity) * granularity;

    Candle? last = candles.isNotEmpty ? candles.last : null;

    if (last != null && last.epoch == currentEpoch) {
      // Update existing candle
      last.close = price;
      last.high = price > last.high ? price : last.high;
      last.low = price < last.low ? price : last.low;
      last.volume += volume;
      candles[candles.length - 1] = _roundCandle(last);
    } else if (last == null || currentEpoch > last.epoch) {
      // New candle
      final newCandle = Candle(
        epoch: currentEpoch,
        open: price,
        close: price,
        high: price,
        low: price,
        volume: volume,
      );
      candles.add(_roundCandle(newCandle));
    } else {
      // Tick for older epoch -> ignore
      return;
    }

    if (candles.length > maxCandles) {
      candles = candles.sublist(candles.length - maxCandles);
    }

    await saveCandles(sym, candles);
  }

  /// ----------------------------------------------------
  /// CLEAR candles for a symbol
  /// ----------------------------------------------------
  Future<void> clear(String symbol) async {
    final sym = _normalizeSymbol(symbol);
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('candles_$sym');
    _cache[sym] = [];
  }

  /// ----------------------------------------------------
  /// PRIVATE: Candle validation
  /// ----------------------------------------------------
  bool _isValidCandle(Candle c) {
    if (c.high < c.low) return false;
    if (c.open < 0 || c.close < 0 || c.high < 0 || c.low < 0) return false;
    if (c.volume < 0) return false;
    if (c.epoch <= 0) return false;
    return true;
  }

  /// ----------------------------------------------------
  /// PRIVATE: Round decimals
  /// ----------------------------------------------------
  Candle _roundCandle(Candle c) {
    double round6(double v) => double.parse(v.toStringAsFixed(6));
    return Candle(
      epoch: c.epoch,
      open: round6(c.open),
      close: round6(c.close),
      high: round6(c.high),
      low: round6(c.low),
      volume: round6(c.volume),
    );
  }

  /// ----------------------------------------------------
  /// PRIVATE: Normalize symbol
  /// ----------------------------------------------------
  String _normalizeSymbol(String symbol) => symbol.toLowerCase();
}
