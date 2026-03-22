import 'dart:math';

/// -------------------------------------------------------------------
/// Tick model → used to build candles
/// -------------------------------------------------------------------
class Tick {
  final double price;
  final int epoch; // seconds since Unix epoch

  Tick({required this.price, required this.epoch});
}

/// -------------------------------------------------------------------
/// Full OHLCV Candle model
/// -------------------------------------------------------------------
class Candle {
  int epoch; // seconds since Unix epoch
  double open;
  double close;
  double high;
  double low;
  double volume;

  /// Convert epoch → DateTime
  DateTime get time => DateTime.fromMillisecondsSinceEpoch(epoch * 1000);

  // ✅ Constants
  static const double minPrice = 0.00001;
  static const double minVolume = 0.00001;
  static const double minBody = 0.0005; // ensures visible candle body

  /// -------------------------------------------------------------------
  /// Main constructor
  /// Accepts either epoch OR time
  /// -------------------------------------------------------------------
  Candle({
    int? epoch,
    DateTime? time,
    required this.open,
    required this.close,
    required this.high,
    required this.low,
    double? volume,
  })  : assert(epoch != null || time != null,
            "You must provide either epoch OR time"),
        epoch = epoch ?? (time!.millisecondsSinceEpoch ~/ 1000),
        volume = (volume != null && volume.isFinite && volume >= 0)
            ? volume
            : minVolume;

  /// -------------------------------------------------------------------
  /// copyWith → allows updating individual fields safely
  /// -------------------------------------------------------------------
  Candle copyWith({
    int? epoch,
    double? open,
    double? close,
    double? high,
    double? low,
    double? volume,
  }) {
    return Candle(
      epoch: epoch ?? this.epoch,
      open: open ?? this.open,
      close: close ?? this.close,
      high: high ?? this.high,
      low: low ?? this.low,
      volume: volume ?? this.volume,
    );
  }

  /// -------------------------------------------------------------------
  /// Safe double parser
  /// -------------------------------------------------------------------
  static double safe(dynamic v) {
    if (v == null) return minPrice;
    if (v is num) return v.isFinite ? v.toDouble() : minPrice;
    if (v is String) return double.tryParse(v) ?? minPrice;
    return minPrice;
  }

  /// -------------------------------------------------------------------
  /// Create Candle from JSON/Map
  /// -------------------------------------------------------------------
  factory Candle.fromJson(Map<String, dynamic> json, {double? lastClose}) {
    double openFinal = lastClose ?? safe(json['open']);
    double closeFinal = safe(json['close']);
    double high = safe(json['high']);
    double low = safe(json['low']);
    double volume = safe(json['volume']);
    final int ep = (json['epoch'] ?? json['time'] ?? 0).toInt();

    if (ep <= 0) throw Exception("Invalid epoch in Candle JSON: $json");

    // normalize high/low
    high = max(high, max(openFinal, closeFinal));
    low = min(low, min(openFinal, closeFinal));

    // prevent flat candle
    if ((high - low).abs() < minPrice) {
      final spread = max(openFinal * 0.001, minPrice);
      high = max(openFinal, closeFinal) + spread;
      low = min(openFinal, closeFinal) - spread;
    }

    // ensure minimum body
    if ((openFinal - closeFinal).abs() < minBody) {
      closeFinal = closeFinal >= openFinal ? openFinal + minBody : openFinal - minBody;
    }

    return Candle(
      epoch: ep,
      open: openFinal,
      close: closeFinal,
      high: high,
      low: low,
      volume: volume,
    );
  }

  /// Convert Candle to Map
  Map<String, dynamic> toJson() => {
        'epoch': epoch,
        'open': open,
        'close': close,
        'high': high,
        'low': low,
        'volume': volume,
      };

  factory Candle.fromMap(Map<String, dynamic> map) => Candle.fromJson(map);

  @override
  String toString() =>
      'Candle(epoch:$epoch open:$open close:$close high:$high low:$low vol:$volume)';

  /// -------------------------------------------------------------------
  /// Convert a list of ticks → list of candles
  /// Supports multi-timeframe aggregation
  /// -------------------------------------------------------------------
  static List<Candle> fromTicks(
    List<Tick> ticks, {
    int timeframe = 1, // minutes
  }) {
    if (ticks.isEmpty) return [];

    // Sort by epoch ascending
    ticks.sort((a, b) => a.epoch.compareTo(b.epoch));

    // Group ticks by timeframe bucket
    final Map<int, List<Tick>> groups = {};
    for (final t in ticks) {
      final bucket = (t.epoch ~/ 60) ~/ timeframe;
      groups.putIfAbsent(bucket, () => []).add(t);
    }

    final List<Candle> candles = [];

    groups.forEach((bucket, list) {
      list.sort((a, b) => a.epoch.compareTo(b.epoch));

      double o = list.first.price;
      double c = list.last.price;
      double h = list.map((e) => e.price).reduce(max);
      double l = list.map((e) => e.price).reduce(min);

      // prevent flat candle
      if ((h - l).abs() < minPrice) {
        final spread = max(o * 0.001, minPrice);
        h = max(o, c) + spread;
        l = min(o, c) - spread;
      }

      // ensure minimum body
      if ((o - c).abs() < minBody) {
        c = c >= o ? o + minBody : o - minBody;
      }

      final epoch = (list.first.epoch ~/ (timeframe * 60)) * (timeframe * 60);

      candles.add(
        Candle(
          epoch: epoch,
          open: o,
          close: c,
          high: h,
          low: l,
          volume: list.length.toDouble(),
        ),
      );
    });

    // Sort candles by epoch ascending
    candles.sort((a, b) => a.epoch.compareTo(b.epoch));

    // Remove duplicates
    final uniqueCandles = <Candle>[];
    int? lastEpoch;
    for (var c in candles) {
      if (c.epoch != lastEpoch) {
        uniqueCandles.add(c);
        lastEpoch = c.epoch;
      }
    }

    return uniqueCandles;
  }
}

/// -------------------------------------------------------------------
/// Extension helper
/// -------------------------------------------------------------------
extension LastOrNull<T> on List<T> {
  T? get lastOrNull => isNotEmpty ? last : null;
}
