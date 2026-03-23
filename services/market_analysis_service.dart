import 'dart:async';
import 'dart:math';

import 'deriv_service.dart';
import '../models/market_analysis_result.dart';
import '../models/candle.dart' as model;

enum MarketBias { buy, sell, none }
enum EntryConfirmation { bullish, bearish, none }

class MarketAnalysisService {
  // ================= SINGLETON =================
  MarketAnalysisService._internal();
  static final MarketAnalysisService instance = MarketAnalysisService._internal();
  factory MarketAnalysisService() => instance;

  // ================= STREAM =================
  final StreamController<MarketAnalysisResult> _controller =
      StreamController.broadcast();
  Stream<MarketAnalysisResult> get analysisStream => _controller.stream;
Map<String, MarketAnalysisResult?> latestForAllPairsMap() {
  return Map<String, MarketAnalysisResult?>.from(_latest);
}
MarketAnalysisResult? latestFor(String pair) {
  return _latest[_normalize(pair)];
}

  // ================= STORAGE =================
  final Map<String, List<model.Candle>> _candlesM1 = {};
  final Map<String, List<model.Candle>> _candlesM5 = {};
  final Map<String, List<model.Candle>> _candlesM15 = {};
  final Map<String, List<model.Candle>> _candlesM30 = {};
  final Map<String, MarketAnalysisResult> _latest = {};

  // ================= CONFIG =================
  int rsiPeriod = 14;
  double defaultRR = 2.0;
  int minCandles = 2;
  int atrPeriod = 14;

  final Set<String> _activePairs = {};
  Timer? _timer;

  // ================= START =================
  Future<void> startPairs(List<String> pairs) async {
    final deriv = DerivService.instance;

    for (var p in pairs) {
      final pair = _normalize(p);
      _activePairs.add(pair);

      // 🔥 REAL-TIME TICKS
      deriv.subscribeContract(pair, (data) {
        final price = (data['price'] ?? 0).toDouble();
        final epoch = (data['epoch'] ?? 0) as int;
        if (epoch == 0) return;

        _onTick(pair, price, epoch);
      });

      await deriv.subscribeCandles(pair); // backup
    }

    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      for (final pair in _activePairs) {
        final candles = _candlesM1[pair] ?? [];

        if (candles.length < minCandles) {
          print("⏳ $pair waiting candles: ${candles.length}");
          continue;
        }

        _process(pair, candles);
      }
    });
  }

  // ================= BUILD CANDLES =================
  void _onTick(String pair, double price, int epoch) {
    final list = _candlesM1.putIfAbsent(pair, () => []);
    final bucket = (epoch ~/ 60) * 60;

    if (list.isEmpty || list.last.epoch != bucket) {
      final open = list.isNotEmpty ? list.last.close : price;

      list.add(model.Candle(
        epoch: bucket,
        open: open,
        close: price,
        high: max(open, price),
        low: min(open, price),
        volume: 1,
      ));
    } else {
      final last = list.last;

      list[list.length - 1] = model.Candle(
        epoch: last.epoch,
        open: last.open,
        close: price,
        high: max(last.high, price),
        low: min(last.low, price),
        volume: last.volume + 1,
      );
    }
  }

  // ================= PROCESS =================
void _process(String pair, List<model.Candle> m1) {
  _candlesM5[pair] = _aggregate(m1, 5);
  _candlesM15[pair] = _aggregate(m1, 15);
  _candlesM30[pair] = _aggregate(m1, 30);

  final result = _analyze(
    pair,
    m1: m1,
    m5: _candlesM5[pair]!,
    m15: _candlesM15[pair]!,
    m30: _candlesM30[pair]!,
  );

  _latest[pair] = result;
  _controller.add(result);

  // 🔥 Print analysis
  print("📊 $pair | BUY=${result.canBuy} SELL=${result.canSell} | SL=${result.stopLoss} TP=${result.takeProfit}");
  print("✅ Conditions met: ${result.conditionsMet.join(", ")} | Failed: ${result.reasonsFailed.join(", ")}");
}

  // ================= ANALYSIS =================
  MarketAnalysisResult _analyze(
    String pair, {
    required List<model.Candle> m1,
    required List<model.Candle> m5,
    required List<model.Candle> m15,
    required List<model.Candle> m30,
  }) {
    final reasonsOk = <String>[];
    final reasonsNo = <String>[];

    // 🔥 1. STRUCTURE
    final bias = _structure(m30);
    if (bias == MarketBias.none) {
      reasonsNo.add("No structure");
    } else {
      reasonsOk.add("Structure ${bias.name}");
    }

    // 🔥 2. EMA TREND
    final ema50 = _ema(m15, 50);
    final ema200 = _ema(m15, 200);

    bool emaBuy = false, emaSell = false;

    if (ema50.isNotEmpty && ema200.isNotEmpty) {
      emaBuy = ema50.last > ema200.last;
      emaSell = ema50.last < ema200.last;
    }

    if (emaBuy || emaSell) {
      reasonsOk.add("EMA trend");
    } else {
      reasonsNo.add("EMA fail");
    }

    // 🔥 3. RSI
    final rsi = _rsi(m15, rsiPeriod);

    final rsiBuy = rsi > 50;
    final rsiSell = rsi < 50;

    if (rsiBuy || rsiSell) {
      reasonsOk.add("RSI ok");
    } else {
      reasonsNo.add("RSI fail");
    }

    // 🔥 4. CONFIRMATION
    final conf = _confirmation(m1, bias);

    final confBuy = conf == EntryConfirmation.bullish;
    final confSell = conf == EntryConfirmation.bearish;

    if (confBuy || confSell) {
      reasonsOk.add("Entry confirmed");
    } else {
      reasonsNo.add("No entry");
    }

    // 🔥 5. SL / TP
    final entry = m1.last.close;
    final sl = _atrSL(m1, bias);
    final tp = _tp(entry, sl, bias);

    // 🔥 6. RR
    final rrOk = _rr(entry, sl, tp);
    if (!rrOk) reasonsNo.add("RR fail");

    // 🔥 7. SESSION
    final session = _session();
    if (!session) reasonsNo.add("Bad session");

    final canBuy = bias == MarketBias.buy &&
        emaBuy &&
        rsiBuy &&
        confBuy &&
        rrOk &&
        session;

    final canSell = bias == MarketBias.sell &&
        emaSell &&
        rsiSell &&
        confSell &&
        rrOk &&
        session;

    return MarketAnalysisResult(
      symbol: pair,
      candles: List.unmodifiable(m1),
      candlesM5: List.unmodifiable(m5),
      candlesM15: List.unmodifiable(m15),
      candlesM30: List.unmodifiable(m30),
      structureValid: bias != MarketBias.none,
      emaValid: emaBuy || emaSell,
      rsiValid: rsiBuy || rsiSell,
      confirmationValid: confBuy || confSell,
      filtersValid: rrOk && session,
      canBuy: canBuy,
      canSell: canSell,
      structureBuy: bias == MarketBias.buy,
      structureSell: bias == MarketBias.sell,
      biasIsBuy: bias == MarketBias.buy,
      ema50: ema50,
      ema200: ema200,
      indicators: {'rsi': rsi},
      entryCandles: [m1.length - 1],
      structurePoints: const [],
      conditionsMet: reasonsOk,
      reasonsFailed: reasonsNo,
      stopLoss: sl,
      takeProfit: tp,
    );
  }

  // ================= INDICATORS =================
  double _rsi(List<model.Candle> c, int p) {
    if (c.length < p + 1) return 50;

    double gain = 0, loss = 0;

    for (int i = c.length - p; i < c.length; i++) {
      final d = c[i].close - c[i - 1].close;
      if (d > 0) gain += d;
      else loss -= d;
    }

    if (gain + loss == 0) return 50;

    final rs = gain / max(loss, 0.00001);
    return 100 - (100 / (1 + rs));
  }

  List<double> _ema(List<model.Candle> c, int p) {
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

  // ================= LOGIC =================
  MarketBias _structure(List<model.Candle> c) {
    if (c.length < 10) return MarketBias.none;

    if (c.last.high > c[c.length - 5].high &&
        c.last.low > c[c.length - 5].low) {
      return MarketBias.buy;
    }

    if (c.last.low < c[c.length - 5].low &&
        c.last.high < c[c.length - 5].high) {
      return MarketBias.sell;
    }

    return MarketBias.none;
  }

  EntryConfirmation _confirmation(List<model.Candle> c, MarketBias bias) {
    if (c.length < 2) return EntryConfirmation.none;

    final last = c.last;
    final prev = c[c.length - 2];

    if (bias == MarketBias.buy && last.close > prev.high) {
      return EntryConfirmation.bullish;
    }

    if (bias == MarketBias.sell && last.close < prev.low) {
      return EntryConfirmation.bearish;
    }

    return EntryConfirmation.none;
  }

  double _atrSL(List<model.Candle> c, MarketBias bias) {
    final atr = _atr(c, atrPeriod);
    final entry = c.last.close;

    return bias == MarketBias.buy
        ? entry - atr
        : entry + atr;
  }

  double _tp(double entry, double sl, MarketBias bias) {
    final risk = (entry - sl).abs();
    if (risk == 0) return 0;

    return bias == MarketBias.buy
        ? entry + risk * defaultRR
        : entry - risk * defaultRR;
  }

  double _atr(List<model.Candle> c, int p) {
    if (c.length < p + 1) return 0;

    double sum = 0;

    for (int i = c.length - p; i < c.length; i++) {
      final high = c[i].high;
      final low = c[i].low;
      final prev = c[i - 1].close;

      final tr = max(high - low,
          max((high - prev).abs(), (low - prev).abs()));

      sum += tr;
    }

    return sum / p;
  }

  bool _rr(double entry, double sl, double tp) {
    if (sl == 0 || tp == 0) return false;

    final risk = (entry - sl).abs();
    final reward = (tp - entry).abs();

    return reward / risk >= defaultRR;
  }

  bool _session() {
    final now = DateTime.now().toUtc().add(const Duration(hours: 3));
    return now.hour >= 8 && now.hour <= 22;
  }

  // ================= AGGREGATE =================
  List<model.Candle> _aggregate(List<model.Candle> c, int tf) {
    final out = <model.Candle>[];

    for (final candle in c) {
      final bucket = (candle.epoch ~/ (tf * 60)) * (tf * 60);

      if (out.isEmpty || out.last.epoch != bucket) {
        final open = out.isNotEmpty ? out.last.close : candle.close;

        out.add(model.Candle(
          epoch: bucket,
          open: open,
          close: candle.close,
          high: candle.high,
          low: candle.low,
          volume: candle.volume,
        ));
      } else {
        final last = out.last;

        out[out.length - 1] = model.Candle(
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

  String _normalize(String p) {
    p = p.toUpperCase().replaceAll(RegExp(r'[^A-Z]'), '');
    if (!p.startsWith('FRX')) p = 'FRX$p';
    return p;
  }
}