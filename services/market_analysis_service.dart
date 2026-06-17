import 'dart:async';
import 'dart:math';

import '../models/market_analysis_result.dart';
import '../models/candle.dart';
import '../models/risk_model.dart';
import 'deriv_service.dart';

enum MarketBias { buy, sell, none }
enum MarketSession { asia, london, newYork, sydney, unknown }

// ================= STRUCTURE =================
class Structure {
  final bool bosUp;
  final bool bosDown;
  final bool chochUp;
  final bool chochDown;

  Structure({
    required this.bosUp,
    required this.bosDown,
    required this.chochUp,
    required this.chochDown,
  });
}

class Liquidity {
  final bool sweepHigh;
  final bool sweepLow;
  final int equalHighs;
  final int equalLows;

  Liquidity({
    required this.sweepHigh,
    required this.sweepLow,
    required this.equalHighs,
    required this.equalLows,
  });
}

class OrderBlock {
  final bool validBullish;
  final bool validBearish;
  final double strength;

  OrderBlock({
    required this.validBullish,
    required this.validBearish,
    required this.strength,
  });
}

// ================= ENGINE =================
class MarketAnalysisService {
  MarketAnalysisService._internal();
  static final instance = MarketAnalysisService._internal();

  final StreamController<MarketAnalysisResult> _controller =
      StreamController.broadcast();

  Stream<MarketAnalysisResult> get analysisStream => _controller.stream;

  final Map<String, int> _lastSize = {};
  final Map<String, MarketAnalysisResult> _latest = {};

  bool debugMode = true;

  void _log(String msg) {
    if (debugMode) print("[PROMAX ULTRA NEXT] $msg");
  }

  // ================= START (🔥 MISSING FIX) =================
  Future<void> startPairs(List<String> pairs) async {
    final deriv = DerivService.instance;
    await deriv.connect();

    for (final p in pairs) {
      await deriv.subscribeCandles(p);
      _lastSize[p] = 0;
    }

    Timer.periodic(const Duration(seconds: 5), (_) async {
      for (final p in pairs) {
        try {
          final h1 = deriv.getCandles(p, TF.h1);
          final h4 = deriv.getCandles(p, TF.h4);
          final d1 = deriv.getCandles(p, TF.d1);
          final w1 = deriv.getCandles(p, TF.w1);

          if (h1.length < 120) continue;
          if (_lastSize[p] == h1.length) continue;

          _lastSize[p] = h1.length;

          final result = _analyze(p, w1, d1, h4, h1);
          _latest[p] = result;

          if (result.canBuy || result.canSell) {
            _controller.add(result);
          }
        } catch (e) {
          _log("ERROR $p -> $e");
        }
      }
    });
  }
// ================= ANALYSIS =================
MarketAnalysisResult _analyze(
  String pair,
  List<Candle> w1,
  List<Candle> d1,
  List<Candle> h4,
  List<Candle> h1,
) {
  _log("════════ TOP DOWN PRICE ACTION ANALYSIS (DEEP MODE) ════════");
  _log("PAIR: $pair");

  // ================= W1 =================
  _log("\n🔵 [STEP 1 - W1 MACRO STRUCTURE]");
  final w1Bias = _bias(w1);
  final w1Struct = _detectStructure(w1);

  _log("W1 candles: ${w1.length}");
  _log("W1 Bias detected: $w1Bias");

  _log("Structure breakdown:");
  _log("  - BOS UP count > BOS DOWN ? ${w1Struct.bosUp}");
  _log("  - BOS DOWN dominance ? ${w1Struct.bosDown}");
  _log("  - CHOCH UP presence ? ${w1Struct.chochUp}");
  _log("  - CHOCH DOWN presence ? ${w1Struct.chochDown}");

  String w1Reason = w1Bias == MarketBias.buy
      ? "Weekly shows bullish pressure (buyers dominating momentum)"
      : w1Bias == MarketBias.sell
          ? "Weekly shows bearish pressure (sellers dominating momentum)"
          : "Weekly market is indecisive / ranging";

  _log("W1 INTERPRETATION: $w1Reason");

  // ================= D1 =================
  _log("\n🟠 [STEP 2 - D1 CONFIRMATION]");
  final d1Bias = _bias(d1);
  final d1Struct = _detectStructure(d1);

  bool trendAligned = (w1Bias == d1Bias) && w1Bias != MarketBias.none;

  _log("D1 candles: ${d1.length}");
  _log("D1 Bias: $d1Bias");
  _log("Trend alignment W1 vs D1: $trendAligned");

  String d1Reason = trendAligned
      ? "Daily confirms weekly direction → institutional alignment present"
      : "Daily contradicts weekly → market uncertainty / consolidation";

  _log("D1 INTERPRETATION: $d1Reason");

  if (!trendAligned) {
    _log("❌ FILTER TRIGGERED: NO HIGH PROBABILITY TRADE (TOP-DOWN FAILURE)");
  }

  // ================= H4 =================
  _log("\n🟣 [STEP 3 - H4 LIQUIDITY + ORDERBLOCK]");
  final liquidity = _detectLiquidity(h4);
  final ob = _detectOrderBlock(h4);

  _log("H4 candles: ${h4.length}");

  _log("Liquidity analysis:");
  _log("  - Sweep High detected: ${liquidity.sweepHigh}");
  _log("  - Sweep Low detected: ${liquidity.sweepLow}");
  _log("  - Equal Highs: ${liquidity.equalHighs}");
  _log("  - Equal Lows: ${liquidity.equalLows}");

  String liquidityReason = liquidity.sweepLow
      ? "Buy-side liquidity taken → potential bullish continuation"
      : liquidity.sweepHigh
          ? "Sell-side liquidity taken → potential bearish continuation"
          : "No liquidity sweep → market still balanced";

  _log("LIQUIDITY INTERPRETATION: $liquidityReason");

  _log("OrderBlock analysis:");
  _log("  - Bullish OB valid: ${ob.validBullish}");
  _log("  - Bearish OB valid: ${ob.validBearish}");
  _log("  - Strength: ${ob.strength}");

  String obReason = ob.validBullish
      ? "Bullish orderblock found → smart money accumulation zone"
      : ob.validBearish
          ? "Bearish orderblock found → smart money distribution zone"
          : "No clear orderblock → weak institutional footprint";

  _log("OB INTERPRETATION: $obReason");

  // ================= H1 =================
  _log("\n🟡 [STEP 4 - H1 ENTRY CONFIRMATION]");
  final last5 = h1.sublist(max(0, h1.length - 5));

  int bull = 0, bear = 0;
  for (final c in last5) {
    if (c.close > c.open) bull++;
    if (c.close < c.open) bear++;
  }

  bool h1Buy = bull >= 3;
  bool h1Sell = bear >= 3;

  _log("H1 candles: ${h1.length}");
  _log("Last 5 candles → Bull:$bull Bear:$bear");

  String h1Reason = h1Buy
      ? "Short-term momentum bullish → buyers active"
      : h1Sell
          ? "Short-term momentum bearish → sellers active"
          : "No clear momentum → market consolidation";

  _log("H1 INTERPRETATION: $h1Reason");

  // ================= CANDLE PSYCHOLOGY =================
  _log("\n⚪ [STEP 4.5 - CANDLE PSYCHOLOGY]");

  final last = h1.last;
  final prev = h1[h1.length - 2];

  bool engulfBull =
      last.close > last.open &&
      prev.close < prev.open &&
      last.close > prev.open;

  bool engulfBear =
      last.close < last.open &&
      prev.close > prev.open &&
      last.close < prev.open;

  bool bullishCandle = engulfBull;
  bool bearishCandle = engulfBear;

  _log("Bullish engulfing: $bullishCandle");
  _log("Bearish engulfing: $bearishCandle");

  String candleReason = bullishCandle
      ? "Strong bullish reversal candle → buyers aggressively entering"
      : bearishCandle
          ? "Strong bearish reversal candle → sellers aggressively entering"
          : "No strong reversal pattern → weak entry signal";

  _log("CANDLE INTERPRETATION: $candleReason");

  // ================= SCORE ENGINE =================
  _log("\n🧠 [FINAL STEP - CONFLUENCE ENGINE]");

  double buy = 0, sell = 0;

  if (trendAligned && w1Bias == MarketBias.buy) buy += 35;
  if (trendAligned && w1Bias == MarketBias.sell) sell += 35;

  if (w1Struct.bosUp && d1Struct.bosUp) buy += 20;
  if (w1Struct.bosDown && d1Struct.bosDown) sell += 20;

  if (liquidity.sweepLow) buy += 25;
  if (liquidity.sweepHigh) sell += 25;

  if (ob.validBullish) buy += 20;
  if (ob.validBearish) sell += 20;

  if (h1Buy) buy += 20;
  if (h1Sell) sell += 20;

  if (trendAligned) {
    if (bullishCandle) buy += 10;
    if (bearishCandle) sell += 10;
  }

  double total = buy + sell;
  double confidence =
      total == 0 ? 0 : (max(buy, sell) / total) * 100;

  _log("Buy Score: $buy");
  _log("Sell Score: $sell");
  _log("Confidence: $confidence");

  String finalReason = buy > sell
      ? "BUY favored due to confluence across W1-D1-H4-H1 alignment"
      : sell > buy
          ? "SELL favored due to bearish liquidity + structure alignment"
          : "No edge detected → market neutral";

  _log("FINAL INTERPRETATION: $finalReason");

  bool isBuy =
      trendAligned &&
      buy > sell &&
      buy >= 85 &&
      confidence >= 60;

  bool isSell =
      trendAligned &&
      sell > buy &&
      sell >= 85 &&
      confidence >= 60;

  _log("════════ FINAL DECISION ════════");
  _log("BUY: $isBuy | SELL: $isSell");

  return MarketAnalysisResult(
    symbol: pair,
    candles: h1,
    candlesH1: h1,
    candlesM15: h4,
    candlesM30: d1,
    candlesM5: const [],
    canBuy: isBuy,
    canSell: isSell,
    structureValid: true,
    emaValid: true,
    rsiValid: true,
    confirmationValid: isBuy || isSell,
    filtersValid: confidence > 70,
    ema50: const [],
    ema200: const [],
    indicators: {
      "buy": buy,
      "sell": sell,
      "confidence": confidence,
      "trendAligned": trendAligned,
      "w1Bias": w1Bias.toString(),
      "d1Bias": d1Bias.toString(),
      "reason": finalReason,
    },
    entryCandles: const [],
    structurePoints: const [],
    conditionsMet: const [],
    reasonsFailed: const [],
    stopLoss: _atr(h1),
    takeProfit: _atr(h1) * 3,
    structureBuy: isBuy,
    structureSell: isSell,
    biasIsBuy: isBuy,
    risk: RiskModel(
      entry: h1.last.close,
      stopLoss: isBuy
          ? h1.last.close - _atr(h1)
          : h1.last.close + _atr(h1),
      takeProfit: isBuy
          ? h1.last.close + _atr(h1) * 3
          : h1.last.close - _atr(h1) * 3,
      lotSize: 0.1,
      direction: isBuy ? "BUY" : isSell ? "SELL" : "NONE",
    ),
  );
}

  // ================= HELPERS =================
  MarketBias _bias(List<Candle> c) {
    int up = 0, down = 0;
    for (int i = 1; i < c.length; i++) {
      if (c[i].close > c[i - 1].close) up++;
      if (c[i].close < c[i - 1].close) down++;
    }
    if (up > down + 10) return MarketBias.buy;
    if (down > up + 10) return MarketBias.sell;
    return MarketBias.none;
  }

  Structure _detectStructure(List<Candle> c) {
    int h = 0, l = 0;
    for (int i = 2; i < c.length - 2; i++) {
      if (c[i].high > c[i - 1].high && c[i].high > c[i + 1].high) h++;
      if (c[i].low < c[i - 1].low && c[i].low < c[i + 1].low) l++;
    }
    return Structure(
      bosUp: h > l,
      bosDown: l > h,
      chochUp: h >= l,
      chochDown: l >= h,
    );
  }

  Liquidity _detectLiquidity(List<Candle> c) {
    int eqH = 0, eqL = 0;
    for (int i = 1; i < c.length; i++) {
      if ((c[i].high - c[i - 1].high).abs() < 0.0005) eqH++;
      if ((c[i].low - c[i - 1].low).abs() < 0.0005) eqL++;
    }
    return Liquidity(
      sweepHigh: eqH > 3,
      sweepLow: eqL > 3,
      equalHighs: eqH,
      equalLows: eqL,
    );
  }

  OrderBlock _detectOrderBlock(List<Candle> c) {
    for (int i = c.length - 5; i < c.length; i++) {
      if (i <= 0) continue;
      final p = c[i - 1];
      final cur = c[i];

      if (cur.close > cur.open && cur.close > p.high) {
        return OrderBlock(validBullish: true, validBearish: false, strength: 0.8);
      }
      if (cur.close < cur.open && cur.close < p.low) {
        return OrderBlock(validBullish: false, validBearish: true, strength: 0.8);
      }
    }
    return OrderBlock(validBullish: false, validBearish: false, strength: 0.3);
  }

  double _atr(List<Candle> c) {
    int len = min(14, c.length - 1);
    double sum = 0;
    for (int i = c.length - len; i < c.length; i++) {
      sum += (c[i].high - c[i].low);
    }
    return len == 0 ? 0 : sum / len;
  }

  MarketAnalysisResult? latestFor(String pair) => _latest[pair];
}