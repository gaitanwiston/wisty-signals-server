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

  final Map<String, int> _lastSize = {}; // ✅ FIXED HERE
  final Map<String, MarketAnalysisResult> _latest = {};
  final Map<String, bool> _isAnalyzing = {}; // 🚀 prevent stacking

  bool debugMode = true;

  void _log(String msg) {
    if (debugMode) print("[PROMAX ULTRA NEXT] $msg");
  }

  // ================= START =================
  Future<void> startPairs(List<String> pairs) async {
    final deriv = DerivService.instance;
    await deriv.connect();

    for (final p in pairs) {
      await deriv.subscribeCandles(p);
      _lastSize[p] = 0;
      _isAnalyzing[p] = false;
    }

    Timer.periodic(const Duration(seconds: 5), (_) async {
      for (final p in pairs) {
        if (_isAnalyzing[p] == true) continue; // 🚫 prevent overlap
        _isAnalyzing[p] = true;

        try {
          final h1 = deriv.getCandles(p, TF.h1);
          final h4 = deriv.getCandles(p, TF.h4);
          final d1 = deriv.getCandles(p, TF.d1);
          final w1 = deriv.getCandles(p, TF.w1);

          if (h1.length < 120) {
            _isAnalyzing[p] = false;
            continue;
          }

          if (_lastSize[p] == h1.length) {
            _isAnalyzing[p] = false;
            continue;
          }

          _lastSize[p] = h1.length;

          final result = _analyze(p, w1, d1, h4, h1);
          _latest[p] = result;

          if (result.canBuy || result.canSell) {
            _controller.add(result);
          }
        } catch (e) {
          _log("ERROR $p -> $e");
        }

        _isAnalyzing[p] = false;
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
  _log("\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");
  _log("📊 PROMAX ULTRA NEXT ANALYSIS START");
  _log("PAIR: $pair");
  _log("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n");

  // ================= STEP 1: W1 =================
  _log("🔵 STEP 1: WEEKLY STRUCTURE (W1)");

  final w1Bias = _bias(w1);
  final w1Struct = _detectStructure(w1);

  _log("Bias: $w1Bias");
  _log("BOS Up: ${w1Struct.bosUp} | BOS Down: ${w1Struct.bosDown}");
  _log("CHOCH Up: ${w1Struct.chochUp} | CHOCH Down: ${w1Struct.chochDown}");

  _log("Interpretation: ${w1Bias == MarketBias.buy
      ? "Bullish weekly momentum"
      : w1Bias == MarketBias.sell
          ? "Bearish weekly momentum"
          : "Ranging / indecision"}");

  // ================= STEP 2: D1 =================
  _log("\n🟠 STEP 2: DAILY CONFIRMATION (D1)");

  final d1Bias = _bias(d1);
  final d1Struct = _detectStructure(d1);

  bool trendAligned =
      (w1Bias == d1Bias) && w1Bias != MarketBias.none;

  _log("Bias: $d1Bias");
  _log("Trend Alignment W1 vs D1: $trendAligned");

  _log("Interpretation: ${trendAligned
      ? "Institutional alignment confirmed"
      : "Conflict detected → consolidation/uncertain market"}");

  // ================= STEP 3: H4 =================
  _log("\n🟣 STEP 3: LIQUIDITY + ORDERBLOCK (H4)");

  final liquidity = _detectLiquidity(h4);
  final ob = _detectOrderBlock(h4);

  _log("Sweep High: ${liquidity.sweepHigh}");
  _log("Sweep Low: ${liquidity.sweepLow}");
  _log("Equal Highs: ${liquidity.equalHighs}");
  _log("Equal Lows: ${liquidity.equalLows}");

  _log("OrderBlock → Bullish: ${ob.validBullish} | Bearish: ${ob.validBearish}");

  // ================= STEP 4: H1 =================
  _log("\n🟡 STEP 4: ENTRY MOMENTUM (H1)");

  final last5 = h1.sublist(max(0, h1.length - 5));

  int bull = 0, bear = 0;
  for (final c in last5) {
    if (c.close > c.open) bull++;
    if (c.close < c.open) bear++;
  }

  bool h1Buy = bull >= 3;
  bool h1Sell = bear >= 3;

  _log("Last 5 candles → Bull: $bull | Bear: $bear");
  _log("Momentum: ${h1Buy
      ? "Bullish pressure"
      : h1Sell
          ? "Bearish pressure"
          : "Neutral"}");

  // ================= STEP 5: CANDLE PSYCHOLOGY =================
  _log("\n⚪ STEP 5: CANDLE PSYCHOLOGY");

  bool bullishCandle = false;
  bool bearishCandle = false;

  if (h1.length > 2) {
    final last = h1[h1.length - 1];
    final prev = h1[h1.length - 2];

    bullishCandle =
        last.close > last.open &&
        prev.close < prev.open &&
        last.close > prev.open;

    bearishCandle =
        last.close < last.open &&
        prev.close > prev.open &&
        last.close < prev.open;
  }

  _log("Bullish Engulfing: $bullishCandle");
  _log("Bearish Engulfing: $bearishCandle");

  // ================= SCORE ENGINE =================
  _log("\n🧠 STEP 6: CONFLUENCE ENGINE");

  double buy = 0;
  double sell = 0;

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

  if (bullishCandle) buy += 10;
  if (bearishCandle) sell += 10;

  double total = buy + sell;
  double confidence =
      total == 0 ? 0 : (max(buy, sell) / total) * 100;

  _log("Buy Score: $buy");
  _log("Sell Score: $sell");
  _log("Confidence: ${confidence.toStringAsFixed(2)}%");

// ================= FINAL DECISION (IMPROVED SMC FILTER) =================

bool strongTrend = trendAligned && w1Bias != MarketBias.none;

// Direction confirmation rules
bool buyStructure =
    w1Bias == MarketBias.buy &&
    (liquidity.sweepLow || ob.validBullish) &&
    h1Buy;

bool sellStructure =
    w1Bias == MarketBias.sell &&
    (liquidity.sweepHigh || ob.validBearish) &&
    h1Sell;

// Final strict filter
bool isBuy =
    strongTrend &&
    buyStructure &&
    buy > sell + 15 &&
    confidence >= 65;

bool isSell =
    strongTrend &&
    sellStructure &&
    sell > buy + 15 &&
    confidence >= 65;

// safety lock
if (isBuy && isSell) {
  isBuy = false;
  isSell = false;
}

  _log("BUY: $isBuy | SELL: $isSell");
  _log("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n");

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
    filtersValid: confidence >= 60,
    ema50: const [],
    ema200: const [],
    indicators: {
      "buy": buy,
      "sell": sell,
      "confidence": confidence,
      "trendAligned": trendAligned,
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