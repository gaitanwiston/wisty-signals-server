import 'candle.dart';
import 'risk_model.dart';

class MarketAnalysisResult {
  final String symbol;

  // ================= TIMEFRAMES =================

  final List<Candle> candles;
  final List<Candle> candlesM5;
  final List<Candle> candlesM15;
  final List<Candle> candlesM30;
  final List<Candle> candlesH1;

  // ================= STRUCTURE =================

  final bool structureValid;
  final bool structureBuy;
  final bool structureSell;
  final bool biasIsBuy;

  final bool emaValid;
  final bool rsiValid;
  final bool filtersValid;

  final double stopLoss;
  final double takeProfit;

  final List<double> ema50;
  final List<double> ema200;

  // ================= SIGNAL =================

  final bool canBuy;
  final bool canSell;
  final bool confirmationValid;

  // ================= SMART MONEY =================

  final List<Candle> orderBlocks;

  final List<Map<String, double>> fairValueGaps;

  final bool liquiditySweep;
  final bool bos;
  final bool choch;

  // ================= INSTITUTIONAL =================

  final bool premiumZone;
  final bool discountZone;

  final bool bullishOrderFlow;
  final bool bearishOrderFlow;

  final bool bullishImbalance;
  final bool bearishImbalance;

  final bool equalHighs;
  final bool equalLows;

  final bool inducement;

  final bool mitigation;

  final bool breakerBlock;

  final bool rejectionBlock;

  final bool multiCandleConfirmation;

  final bool sessionValid;

  final bool volatilityValid;

  final bool trendAlignment;

  // ================= CONFIDENCE =================

  final double confidence;

  final double buyScore;
  final double sellScore;

  // ================= BACKTEST =================

  final double expectedRR;

  final double probability;

  // ================= INDICATORS =================

  final Map<String, dynamic> indicators;

  // ================= ENTRYS =================

  final List<Map<String, dynamic>> entryPoints;

  final List<Map<String, dynamic>> structurePoints;

  final List<Candle> entryCandles;

  // ================= RISK =================

  final RiskModel risk;

  // ================= FEEDBACK =================

  final List<String> conditionsMet;
  final List<String> reasonsFailed;

  MarketAnalysisResult({
    required this.symbol,
    required this.candles,

    this.candlesM5 = const [],
    this.candlesM15 = const [],
    this.candlesM30 = const [],
    this.candlesH1 = const [],

    this.structureValid = false,
    this.structureBuy = false,
    this.structureSell = false,
    this.biasIsBuy = false,

    this.emaValid = false,
    this.rsiValid = false,
    this.filtersValid = false,

    this.stopLoss = 0,
    this.takeProfit = 0,

    this.ema50 = const [],
    this.ema200 = const [],

    this.canBuy = false,
    this.canSell = false,
    this.confirmationValid = false,

    this.orderBlocks = const [],
    this.fairValueGaps = const [],

    this.liquiditySweep = false,
    this.bos = false,
    this.choch = false,

    // ================= INSTITUTIONAL =================

    this.premiumZone = false,
    this.discountZone = false,

    this.bullishOrderFlow = false,
    this.bearishOrderFlow = false,

    this.bullishImbalance = false,
    this.bearishImbalance = false,

    this.equalHighs = false,
    this.equalLows = false,

    this.inducement = false,
    this.mitigation = false,

    this.breakerBlock = false,
    this.rejectionBlock = false,

    this.multiCandleConfirmation = false,

    this.sessionValid = false,
    this.volatilityValid = false,
    this.trendAlignment = false,

    // ================= CONFIDENCE =================

    this.confidence = 0,
    this.buyScore = 0,
    this.sellScore = 0,

    // ================= BACKTEST =================

    this.expectedRR = 0,
    this.probability = 0,

    this.indicators = const {},

    this.entryPoints = const [],
    this.structurePoints = const [],
    this.entryCandles = const [],

    required this.risk,

    this.conditionsMet = const [],
    this.reasonsFailed = const [],
  });

  bool get hasSignal => canBuy || canSell;

  String get direction {
    if (canBuy) return "BUY";
    if (canSell) return "SELL";
    return "NONE";
  }

  @override
  String toString() {
    return '''
MarketAnalysisResult(
  pair: $symbol,
  direction: $direction,
  confidence: ${confidence.toStringAsFixed(2)},
  buyScore: ${buyScore.toStringAsFixed(2)},
  sellScore: ${sellScore.toStringAsFixed(2)},
  RR: ${expectedRR.toStringAsFixed(2)},
)
''';
  }
}