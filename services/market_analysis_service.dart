import 'dart:async';
import 'dart:math';
import '../models/market_analysis_result.dart';
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
  final Map<String, MarketAnalysisResult> _latest = {};

  // ================= CONFIG =================
  int rsiPeriod = 14;
  double defaultRR = 2.0;
  int minCandles = 50;
  bool useATRforSLTP = true;
  int atrPeriod = 14;

  // ================= LIVE DATA =================
  Future<void> startPair(String pair) async {
    final deriv = DerivService.instance;
    await deriv.subscribeCandles(pair);

    Timer.periodic(const Duration(seconds: 1), (_) async {
      final candles = await deriv.getCandles(pair, timeframe: 1);
      if (candles.length >= minCandles) _processPair(pair, candles);
    });
  }

  void _processPair(String pair, List<Candle> candlesM1) {
    final p = _normalize(pair);

    _candlesM1[p] = candlesM1;
    _candlesM5[p] = _aggregate(candlesM1, timeframeMinutes: 5);
    _candlesM15[p] = _aggregate(candlesM1, timeframeMinutes: 15);
    _candlesM30[p] = _aggregate(candlesM1, timeframeMinutes: 30);

    final result = _analyze(
      p,
      m1: _candlesM1[p]!,
      m5: _candlesM5[p]!,
      m15: _candlesM15[p]!,
      m30: _candlesM30[p]!,
    );

    _latest[p] = result;
    _controller.add(result);
  }

  MarketAnalysisResult? latestFor(String pair) => _latest[_normalize(pair)];

  // ================= CORE ANALYSIS =================
  MarketAnalysisResult _analyze(
    String pair, {
    required List<Candle> m1,
    required List<Candle> m5,
    required List<Candle> m15,
    required List<Candle> m30,
  }) {
    final reasonsOk = <String>[];
    final reasonsNo = <String>[];

    final bias = _detectStructure(m30);
    final structureBuy = bias == MarketBias.buy;
    final structureSell = bias == MarketBias.sell;
    if (bias == MarketBias.none) reasonsNo.add("No clear structure");
    else reasonsOk.add("Structure ${bias.name}");

    final ema50 = _calcEMA(m15, 50);
    final ema200 = _calcEMA(m15, 200);
    bool emaBuy = false, emaSell = false;
    if (ema50.isNotEmpty && ema200.isNotEmpty) {
      emaBuy = ema50.last > ema200.last && m1.last.close > ema50.last;
      emaSell = ema50.last < ema200.last && m1.last.close < ema50.last;
    }
    if (emaBuy || emaSell) reasonsOk.add("EMA trend ok");
    else reasonsNo.add("EMA not aligned");

    final rsi = _calcRSI(m15, rsiPeriod);
    final rsiBuy = rsi >= 52 && rsi <= 68;
    final rsiSell = rsi <= 48 && rsi >= 32;
    if (rsiBuy || rsiSell) reasonsOk.add("RSI momentum ok");
    else reasonsNo.add("RSI not good ($rsi)");

    final conf = _confirmation(m1, bias);
    final confBuy = conf == EntryConfirmation.bullish;
    final confSell = conf == EntryConfirmation.bearish;
    if (confBuy || confSell) reasonsOk.add("Entry confirmed");
    else reasonsNo.add("No entry candle");

    final entry = m1.last.close;
    final sl = useATRforSLTP ? _atrSL(m1, bias) : _stopLoss(m1, bias);
    final tp = useATRforSLTP
        ? _atrTP(entry, sl, bias, defaultRR)
        : _takeProfit(entry, sl, bias, defaultRR);

    final sessionOk = _checkSession();
    final riskOk = _checkRR(entry, sl, tp);
    if (!sessionOk) reasonsNo.add("Bad session");
    if (!riskOk) reasonsNo.add("Bad RR");

    final canBuy = structureBuy && emaBuy && rsiBuy && confBuy && sessionOk && riskOk;
    final canSell = structureSell && emaSell && rsiSell && confSell && sessionOk && riskOk;

    return MarketAnalysisResult(
      symbol: pair,
      candles: List.unmodifiable(m1),
      candlesM5: List.unmodifiable(m5),
      candlesM15: List.unmodifiable(m15),
      candlesM30: List.unmodifiable(m30),
      structureValid: structureBuy || structureSell,
      emaValid: emaBuy || emaSell,
      rsiValid: rsiBuy || rsiSell,
      confirmationValid: confBuy || confSell,
      filtersValid: sessionOk && riskOk,
      canBuy: canBuy,
      canSell: canSell,
      structureBuy: structureBuy,
      structureSell: structureSell,
      biasIsBuy: bias == MarketBias.buy,
      ema50: ema50,
      ema200: ema200,
      indicators: {'rsi$rsiPeriod': rsi},
      entryCandles: [m1.length - 1],
      structurePoints: const [],
      conditionsMet: reasonsOk,
      reasonsFailed: reasonsNo,
      stopLoss: sl,
      takeProfit: tp,
    );
  }

  // ================= PUBLIC ATR =================
  double calcATR(List<Candle> c, int period) => _calcATR(c, period);

  // ================= HELPERS =================
  List<Candle> _aggregate(List<Candle> c, {required int timeframeMinutes}) {
    final out = <Candle>[];
    for (final candle in c) {
      _addTickToCandles(out, candle.close, candle.epoch, timeframe: timeframeMinutes);
    }
    return out;
  }

  void _addTickToCandles(List<Candle> list, double price, int epoch, {required int timeframe}) {
    final bucket = (epoch ~/ (timeframe * 60)) * (timeframe * 60);
    if (list.isEmpty || list.last.epoch != bucket) {
      final open = list.isNotEmpty ? list.last.close : price;
      list.add(Candle(epoch: bucket, open: open, close: price, high: max(open, price), low: min(open, price), volume: 1));
    } else {
      final last = list.last;
      list[list.length - 1] = Candle(
        epoch: last.epoch,
        open: last.open,
        close: price,
        high: max(last.high, price),
        low: min(last.low, price),
        volume: last.volume + 1,
      );
    }
  }

  double _calcRSI(List<Candle> c, int period) {
    if (c.length < period + 1) return 50;
    double gain = 0, loss = 0;
    for (int i = c.length - period; i < c.length; i++) {
      final d = c[i].close - c[i - 1].close;
      if (d > 0) gain += d;
      if (d < 0) loss -= d;
    }
    if (gain + loss == 0) return 50;
    final rs = gain / max(loss, 0.00001);
    return 100 - (100 / (1 + rs));
  }

  List<double> _calcEMA(List<Candle> c, int p) {
    if (c.length < p) return [];
    double sma = 0;
    for (int i = c.length - p; i < c.length; i++) sma += c[i].close;
    sma /= p;
    final k = 2 / (p + 1);
    double ema = sma;
    final out = [ema];
    for (int i = c.length - p + 1; i < c.length; i++) {
      ema = c[i].close * k + ema * (1 - k);
      out.add(ema);
    }
    return out;
  }

  MarketBias _detectStructure(List<Candle> c) {
    if (c.length < 10) return MarketBias.none;
    final h1 = c[c.length - 1].high;
    final h2 = c[c.length - 5].high;
    final h3 = c[c.length - 10].high;
    final l1 = c[c.length - 1].low;
    final l2 = c[c.length - 5].low;
    final l3 = c[c.length - 10].low;
    if (h1 > h2 && h2 > h3 && l1 > l2 && l2 > l3) return MarketBias.buy;
    if (l1 < l2 && l2 < l3 && h1 < h2 && h2 < h3) return MarketBias.sell;
    return MarketBias.none;
  }

  EntryConfirmation _confirmation(List<Candle> c, MarketBias bias) {
    if (c.length < 2) return EntryConfirmation.none;
    final last = c.last;
    final prev = c[c.length - 2];
    final body = (last.close - last.open).abs();
    final upperWick = last.high - max(last.close, last.open);
    final lowerWick = min(last.close, last.open) - last.low;
    final bullishEngulf = last.close > prev.high && last.close > last.open;
    final bearishEngulf = last.close < prev.low && last.close < prev.open;
    final bullishPin = lowerWick > body * 2 && upperWick < body;
    final bearishPin = upperWick > body * 2 && lowerWick < body;
    if (bias == MarketBias.buy && (bullishEngulf || bullishPin)) return EntryConfirmation.bullish;
    if (bias == MarketBias.sell && (bearishEngulf || bearishPin)) return EntryConfirmation.bearish;
    return EntryConfirmation.none;
  }

  double _stopLoss(List<Candle> c, MarketBias bias) {
    if (c.length < 2) return 0;
    if (bias == MarketBias.buy) return c[c.length - 2].low;
    if (bias == MarketBias.sell) return c[c.length - 2].high;
    return 0;
  }

  double _atrSL(List<Candle> c, MarketBias bias) {
    if (c.length < atrPeriod + 1) return _stopLoss(c, bias);
    final atr = _calcATR(c, atrPeriod);
    final entry = c.last.close;
    return bias == MarketBias.buy ? entry - atr : entry + atr;
  }

  double _atrTP(double entry, double sl, MarketBias bias, double rr) {
    final risk = (entry - sl).abs();
    if (risk == 0) return 0;
    return bias == MarketBias.buy ? entry + risk * rr : entry - risk * rr;
  }

  double _calcATR(List<Candle> c, int period) {
    if (c.length < period + 1) return 0;
    double sum = 0;
    for (int i = c.length - period; i < c.length; i++) {
      final high = c[i].high;
      final low = c[i].low;
      final prev = c[i - 1].close;
      final tr1 = high - low;
      final tr2 = (high - prev).abs();
      final tr3 = (low - prev).abs();
      sum += max(tr1, max(tr2, tr3));
    }
    return sum / period;
  }

  double _takeProfit(double entry, double sl, MarketBias bias, double rr) => _atrTP(entry, sl, bias, rr);

  bool _checkRR(double entry, double sl, double tp) {
    if (sl == 0 || tp == 0) return false;
    final risk = (entry - sl).abs();
    final reward = (tp - entry).abs();
    if (risk == 0) return false;
    return reward / risk >= defaultRR;
  }

  bool _checkSession() {
    final now = DateTime.now().toUtc().add(const Duration(hours: 3));
    return now.hour >= 8 && now.hour <= 22;
  }

  String _normalize(String p) {
    p = p.toUpperCase().replaceAll(RegExp(r'[^A-Z]'), '');
    while (p.startsWith('FRXFRX')) p = p.substring(3);
    if (!p.startsWith('FRX')) p = 'FRX$p';
    return p;
  }
}