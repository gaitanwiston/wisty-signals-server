import 'package:flutter/foundation.dart';
import '../models/candle.dart';

class IndicatorData {
  final List<Candle> candles;
  IndicatorData(this.candles);
}

class IndicatorResult {
  final double maShort, maLong, rsi, macd, vwap;
  final List<double?> ma10Series, ma30Series, rsiSeries, macdSeries, vwapSeries;

  IndicatorResult(
    this.maShort,
    this.maLong,
    this.rsi,
    this.macd,
    this.vwap, {
    required this.ma10Series,
    required this.ma30Series,
    required this.rsiSeries,
    required this.macdSeries,
    required this.vwapSeries,
  });
}

Future<IndicatorResult> calculateIndicatorsIsolate(IndicatorData data) async {
  final candles = data.candles;
  final n = candles.length;
  if (n == 0) {
    return IndicatorResult(0, 0, 0, 0, 0,
      ma10Series: const [], ma30Series: const [], rsiSeries: const [], macdSeries: const [], vwapSeries: const []);
  }

  final ma10 = List<double?>.filled(n, null);
  final ma30 = List<double?>.filled(n, null);
  final rsi14 = List<double?>.filled(n, null);
  final macd = List<double?>.filled(n, null);
  final vwap = List<double?>.filled(n, null);

  double sum10 = 0, sum30 = 0;
  const rsiPeriod = 14;
  double? avgGain, avgLoss;
  double? ema12, ema26;
  const k12 = 2 / 13, k26 = 2 / 27;
  double cumPV = 0, cumVol = 0;

  for (int i = 0; i < n; i++) {
    final c = candles[i];
    final close = c.close;

    // MA
    sum10 += close; if (i >= 10) sum10 -= candles[i - 10].close;
    if (i >= 9) ma10[i] = sum10 / 10;
    sum30 += close; if (i >= 30) sum30 -= candles[i - 30].close;
    if (i >= 29) ma30[i] = sum30 / 30;

    // RSI (Wilder smoothing)
    if (i > 0) {
      final change = close - candles[i - 1].close;
      final gain = change > 0 ? change : 0;
      final loss = change < 0 ? -change : 0;
      if (i == 1) {
        avgGain = 0; avgLoss = 0;
      }
      if (i <= rsiPeriod) {
        avgGain = (avgGain ?? 0) + gain;
        avgLoss = (avgLoss ?? 0) + loss;
        if (i == rsiPeriod) {
          avgGain = (avgGain ?? 0) / rsiPeriod;
          avgLoss = (avgLoss ?? 0) / rsiPeriod;
          final rs = (avgLoss ?? 0) == 0 ? 100 : (avgGain! / avgLoss!);
          rsi14[i] = 100 - (100 / (1 + rs));
        }
      } else {
        avgGain = ((avgGain ?? 0) * (rsiPeriod - 1) + gain) / rsiPeriod;
        avgLoss = ((avgLoss ?? 0) * (rsiPeriod - 1) + loss) / rsiPeriod;
        final rs = (avgLoss ?? 0) == 0 ? 100 : (avgGain! / avgLoss!);
        rsi14[i] = 100 - (100 / (1 + rs));
      }
    }

    // MACD
    if (i == 0) { ema12 = close; ema26 = close; }
    else {
      ema12 = k12 * close + (1 - k12) * (ema12 ?? close);
      ema26 = k26 * close + (1 - k26) * (ema26 ?? close);
    }
    if (i >= 26) macd[i] = (ema12 ?? close) - (ema26 ?? close);

    // VWAP
    final tp = (c.high + c.low + c.close) / 3;
    cumPV += tp * c.volume;
    cumVol += c.volume;
    vwap[i] = cumVol == 0 ? null : (cumPV / cumVol);
  }

  final last = n - 1;
  return IndicatorResult(
    ma10[last] ?? 0,
    ma30[last] ?? 0,
    rsi14[last] ?? 0,
    macd[last] ?? 0,
    vwap[last] ?? 0,
    ma10Series: List.unmodifiable(ma10),
    ma30Series: List.unmodifiable(ma30),
    rsiSeries: List.unmodifiable(rsi14),
    macdSeries: List.unmodifiable(macd),
    vwapSeries: List.unmodifiable(vwap),
  );
}
