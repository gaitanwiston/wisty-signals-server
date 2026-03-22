//import 'package:flutter/foundation.dart';
import 'candle.dart';

class MarketAnalysisResult {
  final String symbol;
  final List<Candle> candles;        // M1 candles
  final List<Candle>? candlesM5;     // optional
  final List<Candle>? candlesM15;    // optional
  final List<Candle>? candlesM30;    // optional

  // ================= Market structure & filters =================
  final bool structureValid;
  final bool emaValid;
  final bool rsiValid;
  final bool confirmationValid;
  final bool filtersValid;

  // ================= Trade signals =================
  final bool canBuy;
  final bool canSell;
  final bool structureBuy; // for early exit logic
  final bool structureSell; // for early exit logic
  final bool biasIsBuy; // true = BUY, false = SELL

  // ================= Indicators =================
  final List<double> ema50;
  final List<double> ema200;
  final Map<String, double> indicators;

  // ================= Candles of interest =================
  final List<int> entryCandles;
  final List<int> structurePoints;

  // ================= Logging / diagnostics =================
  final List<String> conditionsMet;
  final List<String> reasonsFailed;

  // ================= Risk Management =================
  final double stopLoss;
  final double takeProfit;

  MarketAnalysisResult({
    required this.symbol,
    required this.candles,
    this.candlesM5,
    this.candlesM15,
    this.candlesM30,
    this.structureValid = false,
    this.emaValid = false,
    this.rsiValid = false,
    this.confirmationValid = false,
    this.filtersValid = false,
    this.canBuy = false,
    this.canSell = false,
    this.structureBuy = true,
    this.structureSell = true,
    this.biasIsBuy = true,
    List<double>? ema50,
    List<double>? ema200,
    Map<String, double>? indicators,
    List<int>? entryCandles,
    List<int>? structurePoints,
    List<String>? conditionsMet,
    List<String>? reasonsFailed,
    double? stopLoss,
    double? takeProfit,
  })  : ema50 = ema50 ?? [],
        ema200 = ema200 ?? [],
        indicators = indicators ?? {},
        entryCandles = entryCandles ?? [],
        structurePoints = structurePoints ?? [],
        conditionsMet = conditionsMet ?? [],
        reasonsFailed = reasonsFailed ?? [],
        stopLoss = stopLoss ?? 0.0,
        takeProfit = takeProfit ?? 0.0;

  @override
  String toString() {
    return 'MarketAnalysisResult(symbol: $symbol, canBuy: $canBuy, canSell: $canSell, '
        'structureValid: $structureValid, emaValid: $emaValid, rsiValid: $rsiValid, '
        'confirmationValid: $confirmationValid, filtersValid: $filtersValid, '
        'stopLoss: $stopLoss, takeProfit: $takeProfit)';
  }
}
