import 'dart:async';
import 'dart:math';

import '../models/market_analysis_result.dart';
import '../models/candle.dart';
import '../models/risk_model.dart';
import 'deriv_service.dart';

enum MarketBias { buy, sell, none }
enum MarketSession { asia, london, newYork, sydney, unknown }

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

class MarketAnalysisService {
  MarketAnalysisService._internal();
  static final instance = MarketAnalysisService._internal();

  final StreamController<MarketAnalysisResult> _controller =
      StreamController.broadcast();

  Stream<MarketAnalysisResult> get analysisStream => _controller.stream;

  final Map<String, MarketAnalysisResult> _latest = {};
  final Map<String, bool> _isAnalyzing = {};

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
      _isAnalyzing[p] = false;
    }

    deriv.wsStream.listen((event) {
      final symbol = event["symbol"];
      final type = event["type"];

      if (symbol == null) return;

      if (type == "candles_update" || type == "ohlc") {
        _runAnalysis(symbol);
      }
    });

    _log("🚀 ENGINE STARTED WITH FULL DEBUG MODE");
  }

  // ================= RUN =================
  Future<void> _runAnalysis(String p) async {
    if (_isAnalyzing[p] == true) return;
    _isAnalyzing[p] = true;

    try {
      final deriv = DerivService.instance;

      final h1 = deriv.getCandles(p, TF.h1);
      final h4 = deriv.getCandles(p, TF.h4);
      final d1 = deriv.getCandles(p, TF.d1);
      final w1 = deriv.getCandles(p, TF.w1);

      _log("\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");
      _log("📡 NEW ANALYSIS TRIGGERED: $p");
      _log("DATA SIZE → H1:${h1.length} H4:${h4.length} D1:${d1.length} W1:${w1.length}");
      _log("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");

      if (h1.length < 120) {
        _log("⛔ SKIP: Not enough H1 candles");
        _isAnalyzing[p] = false;
        return;
      }

      final result = _analyze(p, w1, d1, h4, h1);
      _latest[p] = result;

      _controller.add(result);

      _log("✅ RESULT → BUY:${result.canBuy} SELL:${result.canSell}");
      _log("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n");

    } catch (e) {
      _log("❌ ERROR $p -> $e");
    }

    _isAnalyzing[p] = false;
  }

  // ================= ANALYSIS =================
  MarketAnalysisResult _analyze(
    String pair,
    List<Candle> w1,
    List<Candle> d1,
    List<Candle> h4,
    List<Candle> h1,
  ) {
    _log("🔵 STEP 1: WEEKLY STRUCTURE (W1)");
    final w1Bias = _bias(w1);
    final w1Struct = _detectStructure(w1);

    _log("W1 Bias = $w1Bias");
    _log("BOS UP:${w1Struct.bosUp} BOS DOWN:${w1Struct.bosDown}");
    _log("CHOCH UP:${w1Struct.chochUp} CHOCH DOWN:${w1Struct.chochDown}");

    _log("\n🟠 STEP 2: DAILY STRUCTURE (D1)");
    final d1Bias = _bias(d1);
    final d1Struct = _detectStructure(d1);

    _log("D1 Bias = $d1Bias");

    bool trendAligned =
        (w1Bias == d1Bias) && w1Bias != MarketBias.none;

    _log("Trend Aligned = $trendAligned");

    _log("\n🟣 STEP 3: LIQUIDITY + ORDERBLOCK (H4)");
    final liquidity = _detectLiquidity(h4);
    final ob = _detectOrderBlock(h4);

    _log("Sweep High:${liquidity.sweepHigh} Sweep Low:${liquidity.sweepLow}");
    _log("Equal Highs:${liquidity.equalHighs} Equal Lows:${liquidity.equalLows}");
    _log("OB Bull:${ob.validBullish} OB Bear:${ob.validBearish}");

    _log("\n🟡 STEP 4: ENTRY MOMENTUM (H1)");
    final last5 = h1.sublist(max(0, h1.length - 5));

    int bull = 0, bear = 0;
    for (final c in last5) {
      if (c.close > c.open) bull++;
      if (c.close < c.open) bear++;
    }

    bool h1Buy = bull >= 3;
    bool h1Sell = bear >= 3;

    _log("Bull:${bull} Bear:${bear}");
    _log("H1 BUY:$h1Buy H1 SELL:$h1Sell");

    _log("\n⚪ STEP 5: SCORE ENGINE");

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

    double total = buy + sell;
    double confidence = total == 0 ? 0 : (max(buy, sell) / total) * 100;

    _log("BUY SCORE:$buy SELL SCORE:$sell");
    _log("CONFIDENCE:${confidence.toStringAsFixed(2)}%");

    bool isBuy =
        trendAligned &&
        w1Bias == MarketBias.buy &&
        buy > sell + 15 &&
        confidence >= 65;

    bool isSell =
        trendAligned &&
        w1Bias == MarketBias.sell &&
        sell > buy + 15 &&
        confidence >= 65;

    _log("FINAL → BUY:$isBuy SELL:$isSell");

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