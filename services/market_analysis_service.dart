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
  final Map<String, DateTime> _lastRun = {};
  final Map<String, DateTime> _lastSignalTime = {};
Timer? _globalAnalysisTimer;
  final Duration signalCooldown = const Duration(seconds: 8);

  bool debugMode = true;

  void _log(String msg) {
    if (debugMode) {
      print("[PROMAX ULTRA NEXT] $msg");
    }
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

      if (symbol == null || type == null) return;

      if (type == "candles_update" || type == "ohlc") {
        _runAnalysis(symbol);
      }

      _log("📩 WS EVENT ${DateTime.now()} TYPE:$type SYMBOL:$symbol");
    });

    _log("🚀 ENGINE STARTED WITH FULL DEBUG MODE");
  }

  // ================= RUN =================
  Future<void> _runAnalysis(String p) async {
    final now = DateTime.now();

    if (_lastRun[p] != null &&
        now.difference(_lastRun[p]!).inMilliseconds < 2500) {
      return;
    }

    if (_isAnalyzing[p] == true) return;

    _isAnalyzing[p] = true;
    _lastRun[p] = now;

    try {
      final deriv = DerivService.instance;

      _log("\n🔥 RUN ANALYSIS TRIGGERED → $p");

      final h1 = deriv.getCandles(p, TF.h1);
      final h4 = deriv.getCandles(p, TF.h4);
      final d1 = deriv.getCandles(p, TF.d1);
      final w1 = deriv.getCandles(p, TF.w1);

      _log("📊 Candle Sizes → H1:${h1.length} H4:${h4.length} D1:${d1.length} W1:${w1.length}");

      if (h1.length < 120 || h4.length < 50 || d1.length < 50 || w1.length < 50) {
        _log("⚠️ SKIP $p → insufficient candles");
        _isAnalyzing[p] = false;
        return;
      }

      final result = _analyze(p, w1, d1, h4, h1);

      _latest[p] = result;
      _controller.add(result);

      _log("✅ SIGNAL GENERATED → $p | BUY:${result.canBuy} SELL:${result.canSell}");
    } catch (e, st) {
      _log("❌ ERROR $p: $e");
      _log("$st");
    } finally {
      _isAnalyzing[p] = false;
    }
  }

  // ================= MAIN ANALYSIS =================
  MarketAnalysisResult _analyze(
    String pair,
    List<Candle> w1,
    List<Candle> d1,
    List<Candle> h4,
    List<Candle> h1,
  ) {
    _log("\n══════════════════════════════════════");
    _log("📊 ANALYSIS START: $pair");
    _log("══════════════════════════════════════");

    if (h1.length < 3) {
      _log("❌ Not enough candles → fallback mode");
      return _fallback(pair, h1);
    }

    // ================= STRUCTURE =================
    final w1Bias = _bias(w1);
    final d1Bias = _bias(d1);
    final trendAligned = (w1Bias == d1Bias) && w1Bias != MarketBias.none;

    _log("W1 Bias → $w1Bias");
    _log("D1 Bias → $d1Bias");
    _log("Trend Alignment → $trendAligned");

    // ================= H4 =================
    final liquidity = _detectLiquidity(h4);
    final ob = _detectOrderBlock(h4);

    _log("Sweep High → ${liquidity.sweepHigh}");
    _log("Sweep Low  → ${liquidity.sweepLow}");
    _log("OB Bullish → ${ob.validBullish}");
    _log("OB Bearish → ${ob.validBearish}");

    // ================= H1 =================
    final last5 = h1.sublist(max(0, h1.length - 5));

    int bull = 0, bear = 0;

    for (final c in last5) {
      if (c.close > c.open) bull++;
      if (c.close < c.open) bear++;
    }

    final h1Buy = bull >= 3;
    final h1Sell = bear >= 3;

    _log("Bull candles → $bull");
    _log("Bear candles → $bear");

    // ================= ENGULF =================
    final last = h1.last;
    final prev = h1[h1.length - 2];

    final engulfBull =
        last.close > last.open &&
        prev.close < prev.open &&
        last.close > prev.open;

    final engulfBear =
        last.close < last.open &&
        prev.close > prev.open &&
        last.close < prev.open;

    _log("Bull Engulf → $engulfBull");
    _log("Bear Engulf → $engulfBear");

    // ================= SCORE ENGINE (IMPROVED) =================
    double buy = 0;
    double sell = 0;

    if (trendAligned && w1Bias == MarketBias.buy) buy += 35;
    if (trendAligned && w1Bias == MarketBias.sell) sell += 35;

    if (liquidity.sweepLow) buy += 25;
    if (liquidity.sweepHigh) sell += 25;

    if (ob.validBullish) buy += 25;
    if (ob.validBearish) sell += 25;

    if (h1Buy) buy += 15;
    if (h1Sell) sell += 15;

    if (engulfBull) buy += 15;
    if (engulfBear) sell += 15;

    final total = buy + sell;

    final dominance = (buy - sell).abs();
    final confidence = total == 0
        ? 0
        : (max(buy, sell) / total) * 100;

    _log("BUY SCORE → $buy");
    _log("SELL SCORE → $sell");
    _log("CONFIDENCE → $confidence");
    _log("GAP → $dominance");

    // ================= NEW DECISION LOGIC =================
    final strongTrend = confidence >= 65;
    final clearEdge = dominance >= 25;
    final structureOk = trendAligned;

    bool isBuy = strongTrend && clearEdge && structureOk && buy > sell;
    bool isSell = strongTrend && clearEdge && structureOk && sell > buy;

    _log("FINAL FILTER → strongTrend:$strongTrend clearEdge:$clearEdge structureOk:$structureOk");

    // ================= COOLDOWN =================
    final lastSignal = _lastSignalTime[pair];
    final canSend = lastSignal == null ||
        DateTime.now().difference(lastSignal) > signalCooldown;

    isBuy = isBuy && canSend;
    isSell = isSell && canSend;

    if (isBuy || isSell) {
      _lastSignalTime[pair] = DateTime.now();
    }

    _log("FINAL BUY → $isBuy");
    _log("FINAL SELL → $isSell");

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
      filtersValid: confidence > 65,
      ema50: const [],
      ema200: const [],
      indicators: {
        "buy": buy,
        "sell": sell,
        "confidence": confidence,
        "gap": dominance,
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

  // ================= FALLBACK =================
  MarketAnalysisResult _fallback(String pair, List<Candle> h1) {
    return MarketAnalysisResult(
      symbol: pair,
      candles: h1,
      candlesH1: h1,
      candlesM15: const [],
      candlesM30: const [],
      candlesM5: const [],
      canBuy: false,
      canSell: false,
      structureValid: false,
      emaValid: false,
      rsiValid: false,
      confirmationValid: false,
      filtersValid: false,
      ema50: const [],
      ema200: const [],
      indicators: const {},
      entryCandles: const [],
      structurePoints: const [],
      conditionsMet: const [],
      reasonsFailed: const ["Insufficient data"],
      stopLoss: 0,
      takeProfit: 0,
      structureBuy: false,
      structureSell: false,
      biasIsBuy: false,
      risk: RiskModel(
        entry: 0,
        stopLoss: 0,
        takeProfit: 0,
        lotSize: 0,
        direction: "NONE",
      ),
    );
  }
void startPeriodicAnalysis(List<String> pairs) {
  _globalAnalysisTimer?.cancel();

  print("🚀 PERIODIC ANALYSIS STARTED");

  _globalAnalysisTimer = Timer.periodic(
    const Duration(minutes: 5),
    (_) async {
      print(
        "⏱️ FORCED ANALYSIS ${DateTime.now()}",
      );

      for (final p in pairs) {
        await _runAnalysis(p);
      }

      print("✅ FORCED ANALYSIS COMPLETE");
    },
  );
}
  // ================= HELPERS =================
  MarketBias _bias(List<Candle> c) {
    int up = 0, down = 0;

    for (int i = 1; i < c.length; i++) {
      if (c[i].close > c[i - 1].close) up++;
      if (c[i].close < c[i - 1].close) down++;
    }

    if (up > down + 8) return MarketBias.buy;
    if (down > up + 8) return MarketBias.sell;
    return MarketBias.none;
  }

  Liquidity _detectLiquidity(List<Candle> c) {
    if (c.length < 2) {
      return Liquidity(
        sweepHigh: false,
        sweepLow: false,
        equalHighs: 0,
        equalLows: 0,
      );
    }

    int eqH = 0, eqL = 0;
    double threshold = 0.0005;

    for (int i = 1; i < c.length; i++) {
      if ((c[i].high - c[i - 1].high).abs() < threshold) eqH++;
      if ((c[i].low - c[i - 1].low).abs() < threshold) eqL++;
    }

    return Liquidity(
      sweepHigh: eqH > 2,
      sweepLow: eqL > 2,
      equalHighs: eqH,
      equalLows: eqL,
    );
  }

  OrderBlock _detectOrderBlock(List<Candle> c) {
    if (c.length < 3) {
      return OrderBlock(
        validBullish: false,
        validBearish: false,
        strength: 0.2,
      );
    }

    for (int i = max(1, c.length - 5); i < c.length; i++) {
      final p = c[i - 1];
      final cur = c[i];

      if (cur.close > cur.open && cur.close > p.high) {
        return OrderBlock(
          validBullish: true,
          validBearish: false,
          strength: 0.85,
        );
      }

      if (cur.close < cur.open && cur.close < p.low) {
        return OrderBlock(
          validBullish: false,
          validBearish: true,
          strength: 0.85,
        );
      }
    }

    return OrderBlock(
      validBullish: false,
      validBearish: false,
      strength: 0.3,
    );
  }

  double _atr(List<Candle> c) {
    if (c.length < 2) return 0;

    int len = min(14, c.length - 1);
    double sum = 0;

    for (int i = c.length - len; i < c.length; i++) {
      sum += (c[i].high - c[i].low);
    }

    return sum / len;
  }

  MarketAnalysisResult? latestFor(String pair) => _latest[pair];
}