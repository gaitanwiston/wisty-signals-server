import 'dart:async';
import 'dart:math';
import '../models/market_analysis_result.dart';
import '../models/candle.dart';
import 'deriv_service.dart';

enum MarketBias { buy, sell, none }
enum EntryConfirmation { bullish, bearish, none }

class MarketAnalysisService {
  // ================= SINGLETON =================
  MarketAnalysisService._internal();
  static final MarketAnalysisService instance = MarketAnalysisService._internal();
  factory MarketAnalysisService() => instance;

  // ================= STREAM =================
  final StreamController<MarketAnalysisResult> _controller = StreamController.broadcast();
  Stream<MarketAnalysisResult> get analysisStream => _controller.stream;

  // ================= STORAGE =================
  final Map<String, List<Candle>> _candlesM1 = {};
  final Map<String, List<Candle>> _candlesM5 = {};
  final Map<String, List<Candle>> _candlesM15 = {};
  final Map<String, List<Candle>> _candlesM30 = {};
  final Map<String, List<Candle>> _candlesH1 = {};
  final Map<String, MarketAnalysisResult> _latest = {};
  final Map<String, DateTime> _lastSignalTime = {};

  // ================= CONFIG =================
  int rsiPeriod = 14;
  int minCandles = 120;
  int signalCooldownSec = 20;

  // ================= START PAIR =================
  Future<void> startPair(String pair) async {
    final deriv = DerivService.instance;
    await deriv.subscribeCandles(pair);

    Timer.periodic(const Duration(seconds: 1), (_) async {
      final candles = await deriv.getCandles(pair, timeframe: 1);
      if (candles.length >= minCandles) {
        _processPair(pair, candles);
      }
    });
  }

  Future<void> startPairs(List<String> pairs) async {
    for (final p in pairs) {
      await startPair(p);
    }
  }

  // ================= PROCESS =================
  void _processPair(String pair, List<Candle> candlesM1) {
    final p = _normalize(pair);

    _candlesM1[p] = candlesM1;
    _candlesM5[p] = _aggregate(candlesM1, 5);
    _candlesM15[p] = _aggregate(candlesM1, 15);
    _candlesM30[p] = _aggregate(candlesM1, 30);
    _candlesH1[p] = _aggregate(candlesM1, 60);

    final result = _analyze(
      p,
      m1: _candlesM1[p]!,
      m5: _candlesM5[p]!,
      m15: _candlesM15[p]!,
      m30: _candlesM30[p]!,
      h1: _candlesH1[p]!,
    );

    _latest[p] = result;
    _controller.add(result);
  }

  // ================= CORE ANALYSIS =================
  MarketAnalysisResult _analyze(
    String pair, {
    required List<Candle> m1,
    required List<Candle> m5,
    required List<Candle> m15,
    required List<Candle> m30,
    required List<Candle> h1,
  }) {
    final biasH1 = _detectStructure(h1);
    final biasM30 = _detectStructure(m30);
    final biasM15 = _detectStructure(m15);

    final ema50 = _calcEMA(m15, 50);
    final ema200 = _calcEMA(m15, 200);
    final rsi = _calcRSI(m15, rsiPeriod);
    final atr = _calcATR(m15, 14);

    final emaBuy = ema50.isNotEmpty && ema200.isNotEmpty && ema50.last > ema200.last;
    final emaSell = ema50.isNotEmpty && ema200.isNotEmpty && ema50.last < ema200.last;

    final conf = _confirmation(m1, biasM15);

    // ================= SCORING =================
    int scoreBuy = 0;
    int scoreSell = 0;

    // Trend alignment
    if (biasH1 == MarketBias.buy) scoreBuy += 2;
    if (biasH1 == MarketBias.sell) scoreSell += 2;

    if (biasM30 == MarketBias.buy) scoreBuy += 2;
    if (biasM30 == MarketBias.sell) scoreSell += 2;

    if (biasM15 == MarketBias.buy) scoreBuy += 1;
    if (biasM15 == MarketBias.sell) scoreSell += 1;

    // EMA
    if (emaBuy) scoreBuy += 2;
    if (emaSell) scoreSell += 2;

    // RSI zones
    if (rsi > 55 && rsi < 70) scoreBuy += 1;
    if (rsi < 45 && rsi > 30) scoreSell += 1;

    // Confirmation
    if (conf == EntryConfirmation.bullish) scoreBuy += 2;
    if (conf == EntryConfirmation.bearish) scoreSell += 2;

    // Volatility filter (avoid dead market)
    if (atr > 0.0003) {
      scoreBuy += 1;
      scoreSell += 1;
    }

    // ================= FINAL DECISION =================
    bool canBuy = scoreBuy >= 6;
    bool canSell = scoreSell >= 6;

    // Cooldown
    final now = DateTime.now();
    final lastTime = _lastSignalTime[pair];

    if (lastTime != null &&
        now.difference(lastTime).inSeconds < signalCooldownSec) {
      canBuy = false;
      canSell = false;
    }

    if (canBuy || canSell) {
      _lastSignalTime[pair] = now;
    }

    // ================= RR =================
    double stopLoss = atr * 1.5;
    double takeProfit = atr * 3;

    print("📊 $pair BUY=$canBuy SELL=$canSell scoreB=$scoreBuy scoreS=$scoreSell");
    print("🧠 H1=$biasH1 M30=$biasM30 M15=$biasM15 RSI=$rsi ATR=$atr Conf=$conf");

    return MarketAnalysisResult(
      symbol: pair,
      candles: m1,
      candlesM5: m5,
      candlesM15: m15,
      candlesM30: m30,
      candlesH1: h1,
      structureValid: true,
      emaValid: emaBuy || emaSell,
      rsiValid: true,
      confirmationValid: conf != EntryConfirmation.none,
      filtersValid: true,
      canBuy: canBuy,
      canSell: canSell,
      structureBuy: biasM30 == MarketBias.buy,
      structureSell: biasM30 == MarketBias.sell,
      biasIsBuy: biasM30 == MarketBias.buy,
      ema50: ema50,
      ema200: ema200,
      indicators: {'rsi': rsi, 'atr': atr},
      entryCandles: [m1.length - 2],
      structurePoints: const [],
      conditionsMet: [],
      reasonsFailed: [],
      stopLoss: stopLoss,
      takeProfit: takeProfit,
    );
  }

  // ================= STRUCTURE =================
  MarketBias _detectStructure(List<Candle> c) {
    if (c.length < 20) return MarketBias.none;

    final last = c[c.length - 2];
    final prev = c[c.length - 3];

    if (last.high > prev.high && last.low > prev.low) return MarketBias.buy;
    if (last.high < prev.high && last.low < prev.low) return MarketBias.sell;

    return MarketBias.none;
  }

  // ================= CONFIRMATION =================
  EntryConfirmation _confirmation(List<Candle> c, MarketBias bias) {
    if (c.length < 3) return EntryConfirmation.none;

    final last = c[c.length - 2];
    final prev = c[c.length - 3];

    final strong = (last.close - last.open).abs() > (last.high - last.low) * 0.4;

    if (bias == MarketBias.buy && last.close > prev.high && strong) {
      return EntryConfirmation.bullish;
    }

    if (bias == MarketBias.sell && last.close < prev.low && strong) {
      return EntryConfirmation.bearish;
    }

    return EntryConfirmation.none;
  }

  // ================= RSI =================
  double _calcRSI(List<Candle> c, int period) {
    if (c.length < period + 1) return 50;

    double gain = 0, loss = 0;
    for (int i = c.length - period; i < c.length; i++) {
      final diff = c[i].close - c[i - 1].close;
      if (diff > 0) gain += diff;
      if (diff < 0) loss -= diff;
    }

    final rs = gain / max(loss, 0.00001);
    return 100 - (100 / (1 + rs));
  }

  // ================= ATR =================
  double _calcATR(List<Candle> c, int period) {
    if (c.length < period + 1) return 0;
    double sum = 0;
    for (int i = c.length - period; i < c.length; i++) {
      sum += (c[i].high - c[i].low);
    }
    return sum / period;
  }

  // ================= EMA =================
  List<double> _calcEMA(List<Candle> c, int period) {
    if (c.length < period) return [];

    double sma = 0;
    for (int i = c.length - period; i < c.length; i++) {
      sma += c[i].close;
    }
    sma /= period;

    final k = 2 / (period + 1);
    double ema = sma;
    final out = [ema];

    for (int i = c.length - period + 1; i < c.length; i++) {
      ema = c[i].close * k + ema * (1 - k);
      out.add(ema);
    }

    return out;
  }

  // ================= AGGREGATE =================
  List<Candle> _aggregate(List<Candle> c, int tf) {
    final out = <Candle>[];

    for (final candle in c) {
      final bucket = (candle.epoch ~/ (tf * 60)) * (tf * 60);

      if (out.isEmpty || out.last.epoch != bucket) {
        out.add(Candle(
          epoch: bucket,
          open: candle.open,
          close: candle.close,
          high: candle.high,
          low: candle.low,
          volume: candle.volume,
        ));
      } else {
        final last = out.last;
        out[out.length - 1] = Candle(
          epoch: last.epoch,
          open: last.open,
          close: candle.close,
          high: max(last.high, candle.high),
          low: min(last.low, candle.low),
          volume: last.volume + candle.volume,
        );
      }
    }

    return out;
  }

  // ================= LATEST =================
  MarketAnalysisResult? latestFor(String pair) {
    final p = _normalize(pair);
    return _latest[p];
  }

  // ================= NORMALIZE =================
  String _normalize(String p) {
    p = p.toUpperCase().replaceAll(RegExp(r'[^A-Z]'), '');
    if (!p.startsWith('FRX')) p = 'FRX$p';
    return p;
  }
}