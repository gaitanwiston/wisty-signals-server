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

  final StreamController<MarketAnalysisResult> _controller =
      StreamController.broadcast();

  Stream<MarketAnalysisResult> get analysisStream => _controller.stream;

  // ================= STORAGE =================
  final Map<String, List<Candle>> _candlesM1 = {};
  final Map<String, MarketAnalysisResult> _latest = {};
  final Map<String, DateTime> _lastSignalTime = {};

  // ================= CONFIG =================
  int minCandles = 120;
  int signalCooldownSec = 30;
  int rsiPeriod = 14;

  Timer? _timer;

  // ================= START =================
  Future<void> startPairs(List<String> pairs) async {
    final deriv = DerivService.instance;

    await deriv.connect();

    for (final p in pairs) {
      await deriv.subscribeCandles(p);
    }

    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 2), (_) async {
      for (final p in pairs) {
        final candles = await deriv.getCandles(p, timeframe: 1);

        if (candles.length < minCandles) continue;

        _processPair(p, candles);
      }
    });
  }

  void dispose() {
    _timer?.cancel();
    _controller.close();
  }

  // ================= PROCESS =================
  void _processPair(String pair, List<Candle> candles) {
    final p = _normalize(pair);

    final sorted = [...candles]
      ..sort((a, b) => a.epoch.compareTo(b.epoch));

    _candlesM1[p] = sorted;

    final m5 = _aggregate(sorted, 5);
    final m15 = _aggregate(sorted, 15);
    final m30 = _aggregate(sorted, 30);
    final h1 = _aggregate(sorted, 60);

    final result = _analyze(
      p,
      m1: sorted,
      m5: m5,
      m15: m15,
      m30: m30,
      h1: h1,
    );

    _latest[p] = result;

    if (result.canBuy || result.canSell) {
      _controller.add(result);
    }
  }

  // ================= ANALYSIS =================
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

    final ema50 = _ema(m15, 50);
    final ema200 = _ema(m15, 200);
    final rsi = _rsi(m15, rsiPeriod);
    final atr = _atr(m15, 14);

    if (biasH1 == MarketBias.none || biasM30 == MarketBias.none) {
      return _noTrade(pair, m1, m5, m15, m30, h1, "No HTF trend");
    }

    if (atr < 0.00025) {
      return _noTrade(pair, m1, m5, m15, m30, h1, "Low volatility");
    }

    if (rsi > 48 && rsi < 52) {
      return _noTrade(pair, m1, m5, m15, m30, h1, "RSI chop zone");
    }

    final emaBuy = ema50.isNotEmpty &&
        ema200.isNotEmpty &&
        ema50.last > ema200.last;

    final emaSell = ema50.isNotEmpty &&
        ema200.isNotEmpty &&
        ema50.last < ema200.last;

    final confirm = _confirmation(m1, biasM15);

    int buy = 0;
    int sell = 0;

    if (biasH1 == MarketBias.buy) buy += 3;
    if (biasH1 == MarketBias.sell) sell += 3;

    if (biasM30 == MarketBias.buy) buy += 2;
    if (biasM30 == MarketBias.sell) sell += 2;

    if (biasM15 == MarketBias.buy) buy += 2;
    if (biasM15 == MarketBias.sell) sell += 2;

    if (emaBuy) buy += 3;
    if (emaSell) sell += 3;

    if (rsi > 55) buy += 2;
    if (rsi < 45) sell += 2;

    if (confirm == EntryConfirmation.bullish) buy += 3;
    if (confirm == EntryConfirmation.bearish) sell += 3;

    final diff = (buy - sell).abs();

    final strongBuy = buy >= 10 && buy > sell && diff >= 4;
    final strongSell = sell >= 10 && sell > buy && diff >= 4;

    final probability = _aiProbability(buy, sell, rsi, atr);
    final aiOk = probability >= 80;

    bool canBuy = strongBuy && aiOk;
    bool canSell = strongSell && aiOk;

    final now = DateTime.now();
    final last = _lastSignalTime[pair];

    if (last != null &&
        now.difference(last).inSeconds < signalCooldownSec) {
      canBuy = false;
      canSell = false;
    }

    if (canBuy || canSell) {
      _lastSignalTime[pair] = now;
    }

    return MarketAnalysisResult(
      symbol: pair,
      candles: m1,
      candlesM5: m5,
      candlesM15: m15,
      candlesM30: m30,
      candlesH1: h1,
      canBuy: canBuy,
      canSell: canSell,
      structureValid: true,
      emaValid: emaBuy || emaSell,
      rsiValid: true,
      confirmationValid: confirm != EntryConfirmation.none,
      filtersValid: true,
      ema50: ema50,
      ema200: ema200,
      indicators: {
        'rsi': rsi,
        'atr': atr,
        'probability': probability,
        'buyScore': buy.toDouble(),
        'sellScore': sell.toDouble(),
      },
      entryCandles: const [],
      structurePoints: const [],
      conditionsMet: const [],
      reasonsFailed: const [],
      stopLoss: atr * 1.5,
      takeProfit: atr * 3,
      structureBuy: biasM30 == MarketBias.buy,
      structureSell: biasM30 == MarketBias.sell,
      biasIsBuy: biasM30 == MarketBias.buy,
    );
  }

  // ================= AI =================
  double _aiProbability(int buy, int sell, double rsi, double atr) {
    double score = max(buy, sell) * 7;

    if (rsi > 60 || rsi < 40) score += 15;
    if (atr > 0.0003 && atr < 0.0012) score += 10;
    if ((buy - sell).abs() >= 4) score += 10;

    return score.clamp(0, 100);
  }

  // ================= INDICATORS =================
  double _rsi(List<Candle> c, int p) {
    if (c.length < p + 1) return 50;

    double gain = 0, loss = 0;

    for (int i = c.length - p; i < c.length; i++) {
      final d = c[i].close - c[i - 1].close;
      if (d > 0) gain += d;
      if (d < 0) loss -= d;
    }

    final rs = gain / max(loss, 0.00001);
    return 100 - (100 / (1 + rs));
  }

  double _atr(List<Candle> c, int p) {
    if (c.length < p + 1) return 0;

    double sum = 0;
    for (int i = c.length - p; i < c.length; i++) {
      sum += (c[i].high - c[i].low);
    }
    return sum / p;
  }

  List<double> _ema(List<Candle> c, int p) {
    if (c.length < p) return [];

    double sma = 0;
    for (int i = c.length - p; i < c.length; i++) {
      sma += c[i].close;
    }

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

  // ================= AGGREGATION (FIXED) =================
  List<Candle> _aggregate(List<Candle> c, int tf) {
    final out = <Candle>[];

    for (final candle in c) {
      final bucket = (candle.epoch ~/ (tf * 60)) * (tf * 60);

      if (out.isEmpty || out.last.epoch != bucket) {
        out.add(candle);
      } else {
        final last = out.last;

        out[out.length - 1] = Candle(
          epoch: last.epoch,
          open: last.open,
          close: candle.close,
          high: max(last.high, candle.high),
          low: min(last.low, candle.low),
          volume: (last.volume + candle.volume),
        );
      }
    }

    return out;
  }

  // ================= FEEDBACK (FIXED) =================
  void registerTradeResult({
    required String pair,
    required String direction,
    required bool win,
  }) {
    final p = _normalize(pair);
    print("🧠 Feedback: $p | $direction | win=$win");
  }

  // ================= STRUCTURE =================
  MarketBias _detectStructure(List<Candle> c) {
    if (c.length < 20) return MarketBias.none;

    int bull = 0, bear = 0;

    for (int i = c.length - 10; i < c.length - 2; i++) {
      if (c[i].high > c[i - 1].high && c[i].low > c[i - 1].low) {
        bull++;
      }
      if (c[i].high < c[i - 1].high && c[i].low < c[i - 1].low) {
        bear++;
      }
    }

    if (bull >= 6) return MarketBias.buy;
    if (bear >= 6) return MarketBias.sell;
    return MarketBias.none;
  }

  EntryConfirmation _confirmation(List<Candle> c, MarketBias b) {
    if (c.length < 3) return EntryConfirmation.none;

    final last = c[c.length - 2];
    final prev = c[c.length - 3];

    final body = (last.close - last.open).abs();
    final range = (last.high - last.low);

    final strong = body > range * 0.6;
    final up = last.close > prev.high;
    final down = last.close < prev.low;

    if (b == MarketBias.buy && strong && up) return EntryConfirmation.bullish;
    if (b == MarketBias.sell && strong && down) return EntryConfirmation.bearish;

    return EntryConfirmation.none;
  }

  MarketAnalysisResult? latestFor(String pair) {
    final p = _normalize(pair);
    return _latest[p];
  }

  String _normalize(String p) {
    p = p.toUpperCase().replaceAll(RegExp(r'[^A-Z]'), '');
    if (!p.startsWith('FRX')) p = 'FRX$p';
    return p;
  }

  // ================= NO TRADE =================
  MarketAnalysisResult _noTrade(
    String pair,
    List<Candle> m1,
    List<Candle> m5,
    List<Candle> m15,
    List<Candle> m30,
    List<Candle> h1,
    String reason,
  ) {
    return MarketAnalysisResult(
      symbol: pair,
      candles: m1,
      candlesM5: m5,
      candlesM15: m15,
      candlesM30: m30,
      candlesH1: h1,
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
      reasonsFailed: [reason],
      stopLoss: 0,
      takeProfit: 0,
      structureBuy: false,
      structureSell: false,
      biasIsBuy: false,
    );
  }
}