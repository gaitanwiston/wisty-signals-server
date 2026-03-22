import 'dart:async';
import '../models/candle.dart';

/// Builds 1-minute candles from live ticks.
/// Keeps 7 days history excluding Saturday/Sunday.
class CandleAggregatorService {
  final Map<String, List<Candle>> _candleHistory = {};
  final Map<String, List<double>> _currentTicks = {};
  final Map<String, DateTime> _currentBucketStart = {};

  final StreamController<MapEntry<String, Candle>> _newCandleController =
      StreamController.broadcast();

  /// Stream: API → MarketAnalysisService listens to this
  Stream<MapEntry<String, Candle>> get onNewCandle => _newCandleController.stream;

  /// Call this for every incoming tick
  void processTick(String symbol, double price, DateTime timestamp) {
    // ignore weekends (we don't store weekend candles)
    if (timestamp.weekday == DateTime.saturday ||
        timestamp.weekday == DateTime.sunday) return;

    // init if not exist
    _currentTicks.putIfAbsent(symbol, () => []);
    _candleHistory.putIfAbsent(symbol, () => []);

    final bucketStart = _currentBucketStart[symbol];

    // If this is first tick of the minute
    if (bucketStart == null ||
        timestamp.difference(bucketStart).inSeconds >= 60) {
      _finalizeLastBucket(symbol);

      // Start new 1-minute bucket
      _currentBucketStart[symbol] =
          DateTime(timestamp.year, timestamp.month, timestamp.day, timestamp.hour, timestamp.minute);

      _currentTicks[symbol] = [price];
    } else {
      _currentTicks[symbol]!.add(price);
    }
  }

  /// Create candle from bucket
  void _finalizeLastBucket(String symbol) {
    if (_currentTicks[symbol] == null || _currentTicks[symbol]!.isEmpty) return;

    final ticks = _currentTicks[symbol]!;
    final open = ticks.first;
    final close = ticks.last;
    final high = ticks.reduce((a, b) => a > b ? a : b);
    final low = ticks.reduce((a, b) => a < b ? a : b);

    final candle = Candle(
      open: open,
      high: high,
      low: low,
      close: close,
      timestamp: _currentBucketStart[symbol]!,
      volume: ticks.length.toDouble(),
    );

    _candleHistory[symbol]!.add(candle);
    _cleanupOld(symbol);

    _newCandleController.add(MapEntry(symbol, candle));
  }

  /// Keep only last 7 days
  void _cleanupOld(String symbol) {
    final history = _candleHistory[symbol]!;
    final cutoff = DateTime.now().subtract(Duration(days: 7));

    history.removeWhere((c) => c.timestamp.isBefore(cutoff));
  }

  /// Get all stored candles (up to 7 days)
  List<Candle> getCandles(String symbol) {
    return _candleHistory[symbol] ?? [];
  }
}
