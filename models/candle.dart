import 'dart:math';

class Tick {
  final double price;
  final int epoch;

  Tick({
    required this.price,
    required this.epoch,
  });
}

class Candle {
  int epoch;

  double open;
  double close;
  double high;
  double low;

  // ================= VOLUME =================

  double volume;
  double buyVolume;
  double sellVolume;

  double delta;
  double imbalance;

  // ================= STRUCTURE =================

  bool isBullishBreak;
  bool isBearishBreak;

  bool swingHigh;
  bool swingLow;

  bool bosUp;
  bool bosDown;

  bool chochUp;
  bool chochDown;

  // ================= LIQUIDITY =================

  bool liquiditySweepHigh;
  bool liquiditySweepLow;

  bool equalHigh;
  bool equalLow;

  // ================= ORDER FLOW =================

  bool bullishEngulfing;
  bool bearishEngulfing;

  bool pinBarBullish;
  bool pinBarBearish;

  bool insideBar;

  // ================= FAIR VALUE GAP =================

  bool bullishFvg;
  bool bearishFvg;

  // ================= ORDER BLOCK =================

  bool bullishOrderBlock;
  bool bearishOrderBlock;

  // ================= PREMIUM / DISCOUNT =================

  double premiumDiscountRatio;

  DateTime get time =>
      DateTime.fromMillisecondsSinceEpoch(epoch * 1000);

  Candle({
    int? epoch,
    DateTime? time,

    required this.open,
    required this.close,
    required this.high,
    required this.low,

    this.volume = 0,

    this.buyVolume = 0,
    this.sellVolume = 0,

    this.delta = 0,
    this.imbalance = 0,

    this.isBullishBreak = false,
    this.isBearishBreak = false,

    this.swingHigh = false,
    this.swingLow = false,

    this.bosUp = false,
    this.bosDown = false,

    this.chochUp = false,
    this.chochDown = false,

    this.liquiditySweepHigh = false,
    this.liquiditySweepLow = false,

    this.equalHigh = false,
    this.equalLow = false,

    this.bullishEngulfing = false,
    this.bearishEngulfing = false,

    this.pinBarBullish = false,
    this.pinBarBearish = false,

    this.insideBar = false,

    this.bullishFvg = false,
    this.bearishFvg = false,

    this.bullishOrderBlock = false,
    this.bearishOrderBlock = false,

    this.premiumDiscountRatio = 0.5,
  }) : epoch =
            epoch ??
            (time?.millisecondsSinceEpoch ??
                    DateTime.now().millisecondsSinceEpoch) ~/
                1000;

  factory Candle.empty() {
    return Candle(
      epoch: 0,
      open: 0,
      close: 0,
      high: 0,
      low: 0,
      volume: 0,
    );
  }

  static double safe(dynamic v) {
    if (v == null) return 0.0;

    if (v is num) {
      return v.toDouble();
    }

    final parsed = double.tryParse(v.toString());

    if (parsed == null) {
      throw FormatException("Invalid candle value: $v");
    }

    return parsed;
  }

  factory Candle.fromJson(
    Map<String, dynamic> json,
  ) {
    final open = safe(json['open']);
    final close = safe(json['close']);
    final high = safe(json['high']);
    final low = safe(json['low']);
    final volume = safe(json['volume']);

    final ep = (json['epoch'] ?? json['time']).toInt();

    final buyVol =
        close > open
            ? volume * 0.60
            : volume * 0.30;

    final sellVol =
        close < open
            ? volume * 0.60
            : volume * 0.30;

    final delta = buyVol - sellVol;

    final range = (high - low).abs();

    final imbalance =
        range > 0
            ? (close - low) / range
            : 0.5;

    final bullishBreak =
        close > open &&
        (close - open) > range * 0.50;

    final bearishBreak =
        close < open &&
        (open - close) > range * 0.50;

    // ================= ENGULFING =================

    final bullishEngulfing =
        close > open &&
        imbalance > 0.75;

    final bearishEngulfing =
        close < open &&
        imbalance < 0.25;

    // ================= PIN BAR =================

    final upperWick =
        high - max(open, close);

    final lowerWick =
        min(open, close) - low;

    final pinBull =
        lowerWick > range * 0.5;

    final pinBear =
        upperWick > range * 0.5;

    // ================= PREMIUM/DISCOUNT =================

    final pd =
        range > 0
            ? (close - low) / range
            : 0.5;

    return Candle(
      epoch: ep,

      open: open,
      close: close,
      high: high,
      low: low,

      volume: volume,

      buyVolume: buyVol,
      sellVolume: sellVol,

      delta: delta,
      imbalance: imbalance,

      isBullishBreak: bullishBreak,
      isBearishBreak: bearishBreak,

      bullishEngulfing: bullishEngulfing,
      bearishEngulfing: bearishEngulfing,

      pinBarBullish: pinBull,
      pinBarBearish: pinBear,

      premiumDiscountRatio: pd,
    );
  }

  Candle copyWith({
    int? epoch,
    double? open,
    double? close,
    double? high,
    double? low,
  }) {
    return Candle(
      epoch: epoch ?? this.epoch,

      open: open ?? this.open,
      close: close ?? this.close,
      high: high ?? this.high,
      low: low ?? this.low,

      volume: volume,

      buyVolume: buyVolume,
      sellVolume: sellVolume,

      delta: delta,
      imbalance: imbalance,

      isBullishBreak: isBullishBreak,
      isBearishBreak: isBearishBreak,

      swingHigh: swingHigh,
      swingLow: swingLow,

      bosUp: bosUp,
      bosDown: bosDown,

      chochUp: chochUp,
      chochDown: chochDown,

      liquiditySweepHigh: liquiditySweepHigh,
      liquiditySweepLow: liquiditySweepLow,

      equalHigh: equalHigh,
      equalLow: equalLow,

      bullishEngulfing: bullishEngulfing,
      bearishEngulfing: bearishEngulfing,

      pinBarBullish: pinBarBullish,
      pinBarBearish: pinBarBearish,

      insideBar: insideBar,

      bullishFvg: bullishFvg,
      bearishFvg: bearishFvg,

      bullishOrderBlock: bullishOrderBlock,
      bearishOrderBlock: bearishOrderBlock,

      premiumDiscountRatio:
          premiumDiscountRatio,
    );
  }
}