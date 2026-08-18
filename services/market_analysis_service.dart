import 'dart:async';
import 'dart:math';

import '../models/market_analysis_result.dart';
import '../models/candle.dart';
import '../models/risk_model.dart';
import 'deriv_service.dart';

enum MarketBias { buy, sell, none }

// KUMBUKA: 'MarketSession' ilikuwepo kwenye faili ya awali lakini
// HAIKUWA ikitumika popote ndani ya faili hii (dead code - kama
// nyingine tulizozipata na kuzirekebisha kwenye mfumo mzima). Nimeibakiza
// hapa kwa USALAMA WA API TU - endapo faili nyingine za app yako
// (nje ya hizi mbili) zinarejelea aina hii ya enum moja kwa moja.
// Kama hakuna kinachoitumia mahali pengine, ni salama kuiondoa.
enum MarketSession { asia, london, newYork, sydney, unknown }

enum TradeDecision {

strongBuy,

buy,

wait,

sell,

strongSell,

}

class StructureAnalysis {
  final bool bosUp;
  final bool bosDown;

  final bool chochUp;
  final bool chochDown;

  final double swingHigh;
  final double swingLow;

  // ONGEZO JIPYA (kwa ombi la mtumiaji - Chart Patterns kutoka
  // "TOP_DOWN.docx"): swing points za hivi karibuni (bei tu, si
  // index) - zinatumika na _detectChartPatterns() kutambua Double
  // Top/Bottom na Head & Shoulders.
  final List<double> recentSwingHighs;
  final List<double> recentSwingLows;

  const StructureAnalysis({
    required this.bosUp,
    required this.bosDown,
    required this.chochUp,
    required this.chochDown,
    required this.swingHigh,
    required this.swingLow,
    this.recentSwingHighs = const [],
    this.recentSwingLows = const [],
  });
}

// ONGEZO JIPYA: inawakilisha swing point MOJA (fractal high/low) -
// index yake ndani ya orodha ya candles, na bei yake. Inatumika na
// _detectStructure() kujenga "ramani" ya swing points nyingi za
// historia, badala ya kutumia max/min ya dirisha fupi TU.
class _SwingPoint {
  final int index;
  final double price;

  const _SwingPoint({required this.index, required this.price});
}

// ONGEZO JIPYA: inawakilisha "tukio la kuvunja structure" (break of
// structure event) MOJA - index ya candle iliyovunja swing husika, na
// mwelekeo (juu/chini). Orodha ya matukio haya, ikipangwa kwa wakati,
// ndiyo inayotumika kubaini "structure regime ya SASA" (angalia
// _detectStructure()) - si tu tukio la candle ya mwisho.
class _BreakEvent {
  final int index;
  final bool isUp;

  const _BreakEvent(this.index, this.isUp);
}

class LiquidityAnalysis {
  final bool sweepHigh;
  final bool sweepLow;

  final int equalHighs;
  final int equalLows;

  final double highest;
  final double lowest;

  const LiquidityAnalysis({
    required this.sweepHigh,
    required this.sweepLow,
    required this.equalHighs,
    required this.equalLows,
    required this.highest,
    required this.lowest,
  });
}

class InstitutionalOrderBlock {
  final bool bullish;
  final bool bearish;

  final bool mitigated;

  final double strength;

  final double high;
  final double low;

  // ONGEZO JIPYA: candle HALISI iliyounda OB (base candle) - inahitajika
  // kujaza 'orderBlocks: List<Candle>' kwenye MarketAnalysisResult.
  final Candle? baseCandle;

  const InstitutionalOrderBlock({
    required this.bullish,
    required this.bearish,
    required this.mitigated,
    required this.strength,
    required this.high,
    required this.low,
    this.baseCandle,
  });
}

class PriceActionAnalysis {
  final bool bullishEngulfing;
  final bool bearishEngulfing;

  final bool bullishPinBar;
  final bool bearishPinBar;

  final bool insideBar;

  final bool doji;

  final bool bullishRejection;
  final bool bearishRejection;

  // 🚨 ONGEZO JIPYA (kutoka "The Candlestick Trading Bible" - kwa
  // ombi la mtumiaji): patterns tano MPYA zisizokuwepo awali. NOTE:
  // kitabu chenyewe kinathibitisha "Hammer"="Pin Bar bullish",
  // "Shooting Star"="Pin Bar bearish", "Harami"="Inside Bar" - hizo
  // TAYARI zinapatikana hapo juu, hazikuongezwa tena (zingekuwa
  // urudufu).
  final bool dragonflyDoji; // Doji + mkia mrefu chini TU - bullish
  final bool gravestoneDoji; // Doji + mkia mrefu juu TU - bearish
  final bool morningStar; // Candles 3: bearish, ndogo, bullish (>midpoint ya 1) - bullish
  final bool eveningStar; // Candles 3: bullish, ndogo, bearish (<midpoint ya 1) - bearish
  final bool tweezersTop; // Candles 2: bullish+bearish, high zinazolingana - bearish
  final bool tweezersBottom; // Candles 2: bearish+bullish, low zinazolingana - bullish

  const PriceActionAnalysis({
    required this.bullishEngulfing,
    required this.bearishEngulfing,
    required this.bullishPinBar,
    required this.bearishPinBar,
    required this.insideBar,
    required this.doji,
    required this.bullishRejection,
    required this.bearishRejection,
    this.dragonflyDoji = false,
    this.gravestoneDoji = false,
    this.morningStar = false,
    this.eveningStar = false,
    this.tweezersTop = false,
    this.tweezersBottom = false,
  });
}

class ConfluenceAnalysis {
  final bool aligned;

  final int confirmations;

  final double score;

  // FIX (bug halisi ya mantiki - si tu 'uboreshaji'): awali
  // 'confirmations' ilikuwa ikihesabu VYANZO VILIVYOPO (mf. W1/D1
  // sawa, H4 structure, engulfing, pinbar) BILA kuangalia kama
  // vinakubaliana KIMWELEKEO. Kwa mfano: W1/D1 zote BUY (+1), lakini
  // H4 ikawa BEARISH (+1 pia, kwa sababu "h4.bullish || h4.bearish"
  // ilikuwa ikihesabu uwepo tu), na bearish engulfing (+1) - hiyo
  // ingetoa confirmations=3 na 'aligned=true' HALI YA KWAMBA ishara
  // hizo zinapingana moja kwa moja (2 buy dhidi ya 2 sell), si
  // "confluence" ya kweli. Sasa kila upande (buy/sell) una hesabu yake
  // MAHUSUSI, na 'aligned' inaangaliwa kwa mwelekeo husika pekee kwenye
  // _makeDecision (angalia buyAligned/sellAligned).
  final int buyConfirmations;
  final int sellConfirmations;
  final bool buyAligned;
  final bool sellAligned;

  const ConfluenceAnalysis({
    required this.aligned,
    required this.confirmations,
    required this.score,
    required this.buyConfirmations,
    required this.sellConfirmations,
    required this.buyAligned,
    required this.sellAligned,
  });
}

class WeightedScore {
  double trend = 0;
  double liquidity = 0;
  double structure = 0;
  double orderBlock = 0;
  double priceAction = 0;
  double momentum = 0;

  // ONGEZO JIPYA: awali EMA na RSI hazikuwa na mchango wowote kwenye
  // score - licha ya matokeo (MarketAnalysisResult) kudai "emaValid:
  // true" na "rsiValid: true" kila wakati. Sasa ni vyanzo halisi vya
  // uthibitisho, vyenye uzito wao wenyewe (angalia _calculateConfidence).
  double ema = 0;
  double rsi = 0;

  double get total =>
      trend +
      liquidity +
      structure +
      orderBlock +
      priceAction +
      momentum +
      ema +
      rsi;
}

class ConfidenceResult {

  final double confidence;

  final bool strong;

  final bool valid;

  final String quality;


  const ConfidenceResult({

    required this.confidence,

    required this.strong,

    required this.valid,

    required this.quality,

  });

}

class DecisionAnalysis {

final TradeDecision decision;

final bool allowed;


const DecisionAnalysis({

required this.decision,

required this.allowed,

});

}
// ================= H4 STRUCTURE MODEL =================

class H4Analysis {

  final bool bosUp;
  final bool bosDown;

  final bool chochUp;
  final bool chochDown;

  final bool sweepHigh;
  final bool sweepLow;

  final bool bullishOB;
  final bool bearishOB;

  // ONGEZO JIPYA: ishara ya "H4 momentum breakout" - dirisha fupi
  // zaidi (candles 10) la swing high/low ambalo lilikuwa likihesabiwa
  // kwenye _analyzeH4() lakini halikuwahi kutumika popote (dead code -
  // angalia maelezo marefu kwenye _analyzeH4). Sasa ni chanzo halisi
  // cha ziada cha uthibitisho.
  final bool momentumUp;
  final bool momentumDown;

  // ONGEZO JIPYA (kuondoa "pambo" kwenye MarketAnalysisResult):
  // 'equalHighs'/'equalLows'/'mitigated' zilikuwa zikihesabiwa NDANI
  // ya _analyzeH4() (kupitia _detectLiquidity/_detectInstitutionalOB)
  // lakini HAZIKUWAHI kutolewa nje ya function hiyo - zilipotea kimya
  // kimya, na hivyo MarketAnalysisResult.equalHighs/equalLows/
  // mitigation zilibaki 'false' KILA WAKATI licha ya data halisi
  // kuwepo. Sasa zinabebwa hapa ili ziweze kufikishwa kwenye matokeo
  // ya mwisho.
  final bool equalHighs;
  final bool equalLows;
  final bool mitigated;

  // ONGEZO JIPYA: viwango halisi vya bei (swing high/low ya structure,
  // na high/low ya order block) - vinahitajika kujenga
  // 'structurePoints' kwenye MarketAnalysisResult (List<Map<String,
  // dynamic>> - tuligundua aina yake halisi kutoka
  // models/market_analysis_result.dart) yenye maana halisi, badala ya
  // kuachwa tupu.
  final double structureSwingHigh;
  final double structureSwingLow;
  final double obHigh;
  final double obLow;
  final Candle? obBaseCandle;

  final double buyScore;
  final double sellScore;


  H4Analysis({

    required this.bosUp,
    required this.bosDown,

    required this.chochUp,
    required this.chochDown,

    required this.sweepHigh,
    required this.sweepLow,

    required this.bullishOB,
    required this.bearishOB,

    required this.momentumUp,
    required this.momentumDown,

    required this.equalHighs,
    required this.equalLows,
    required this.mitigated,

    required this.structureSwingHigh,
    required this.structureSwingLow,
    required this.obHigh,
    required this.obLow,
    this.obBaseCandle,

    required this.buyScore,
    required this.sellScore,

  });


  // FIX (uchambuzi wa kina - sababu kuu ya "TRADE ALLOWED:false"
  // ya kudumu): kizingiti hiki (>=50) kilikuwa kikihitaji ISHARA
  // MBILI adimu ziunganishwe pamoja (mf. bosUp+chochUp=50, au
  // bosUp+sweepLow=55) kwa sababu kila ishara moja peke yake
  // (bosUp=30, chochUp=20, sweepLow=25) haikuweza kufika 50 hata
  // moja. Kwa vile kila ishara moja mmoja ni adimu (matukio ya
  // structure halisi), kuhitaji MBILI kwa wakati mmoja kulifanya
  // 'bullish'/'bearish' kuwa karibu haiwezekani kabisa - hii ndiyo
  // iliyokuwa ikizuia BUY/SELL kutokea hata pale confluence na
  // confidence zilipokuwa nzuri (GOOD, Aligned:true).
  //
  // Sasa kizingiti kimeshushwa hadi >=30 (BOS peke yake, ishara
  // muhimu zaidi ya structure - "break of structure" - inatosha
  // yenyewe), NA ishara mpya ya 'momentumUp/momentumDown' (breakout
  // ya dirisha fupi la candles 10, uzito 20) imeongezwa kama njia ya
  // ziada, HALISI (si ya kubuni) ya kufikia kizingiti hicho.
  //
  // UWAZI: hii ni MABADILIKO YA MKAKATI (si tu kurekebisha bug) -
  // yanafanya 'h4.bullish/h4.bearish' kufikiwa mara nyingi zaidi.
  // Kama unataka kubaki na ukali wa awali (>=50, ishara mbili
  // zinazohitajika), niambie na nitarudisha kizingiti.
  bool get bullish =>
      buyScore > sellScore &&
      buyScore >= 30;


  bool get bearish =>
      sellScore > buyScore &&
      sellScore >= 30;

}

// ================= BACKTEST HALISI (ONGEZO JIPYA) =================
//
// Madhumuni: kutoa NAMBA HALISI za utendaji (win rate, profit factor,
// drawdown) badala ya kutumaini tu kwamba mkakati "unafanya kazi".
// Kila 'BacktestTrade' inaandikwa kikamilifu ili iwe rahisi kukagua
// (audit) kila uamuzi baadaye - hii ni muhimu kwa uaminifu wa matokeo.
class BacktestTrade {
  final String symbol;
  final bool isBuy;

  final int entryEpoch;
  final int? exitEpoch;

  final double entryPrice;
  final double stopLoss;
  final double takeProfit;
  final double exitPrice;

  final double lots;
  final double riskAmount;

  final double grossPnl;
  final double costs; // spread + commission
  final double netPnl;

  final double rMultiple; // netPnl / riskAmount

  // "TP" | "SL" | "OPEN_AT_END" | "BOTH_TOUCHED_SL_ASSUMED"
  final String outcome;

  final double balanceAfter;

  const BacktestTrade({
    required this.symbol,
    required this.isBuy,
    required this.entryEpoch,
    required this.exitEpoch,
    required this.entryPrice,
    required this.stopLoss,
    required this.takeProfit,
    required this.exitPrice,
    required this.lots,
    required this.riskAmount,
    required this.grossPnl,
    required this.costs,
    required this.netPnl,
    required this.rMultiple,
    required this.outcome,
    required this.balanceAfter,
  });
}

class BacktestResult {
  final String symbol;
  final DateTime start;
  final DateTime end;

  final double startingBalance;
  final double endingBalance;

  final List<BacktestTrade> trades;
  final List<double> equityCurve;

  const BacktestResult({
    required this.symbol,
    required this.start,
    required this.end,
    required this.startingBalance,
    required this.endingBalance,
    required this.trades,
    required this.equityCurve,
  });

  int get totalTrades => trades.length;

  int get wins => trades.where((t) => t.netPnl > 0).length;

  int get losses => trades.where((t) => t.netPnl <= 0).length;

  double get winRatePct =>
      totalTrades == 0 ? 0 : (wins / totalTrades) * 100;

  double get grossProfit => trades
      .where((t) => t.netPnl > 0)
      .fold(0.0, (sum, t) => sum + t.netPnl);

  double get grossLoss => trades
      .where((t) => t.netPnl <= 0)
      .fold(0.0, (sum, t) => sum + t.netPnl.abs());

  // FIX ya uaminifu: profitFactor haina maana ikiwa hakuna hasara YOYOTE
  // (mgawanyo kwa 0). Badala ya kurudisha 'infinity' isiyoeleweka,
  // tunarudisha null kuashiria "haiwezi kuhesabiwa kwa uhakika".
  double? get profitFactor =>
      grossLoss == 0 ? null : grossProfit / grossLoss;

  double get averageRMultiple => totalTrades == 0
      ? 0
      : trades.fold(0.0, (sum, t) => sum + t.rMultiple) / totalTrades;

  double get expectancyPerTrade =>
      totalTrades == 0 ? 0 : (endingBalance - startingBalance) / totalTrades;

  double get totalReturnPct => startingBalance == 0
      ? 0
      : ((endingBalance - startingBalance) / startingBalance) * 100;

  // Max drawdown kwa asilimia kutoka kilele (peak) hadi chini zaidi
  // (trough) ya equity curve - hii ndiyo namba muhimu zaidi ya HATARI,
  // sio faida tu.
  double get maxDrawdownPct {
    if (equityCurve.isEmpty) return 0;

    double peak = equityCurve.first;
    double maxDd = 0;

    for (final e in equityCurve) {
      if (e > peak) peak = e;
      if (peak > 0) {
        final dd = (peak - e) / peak * 100;
        if (dd > maxDd) maxDd = dd;
      }
    }

    return maxDd;
  }

  int get maxConsecutiveLosses {
    int worst = 0;
    int current = 0;
    for (final t in trades) {
      if (t.netPnl <= 0) {
        current++;
        if (current > worst) worst = current;
      } else {
        current = 0;
      }
    }
    return worst;
  }

  // Muhtasari wa kibinadamu wa matokeo, ikiwa na ONYO la wazi endapo
  // sampuli ni ndogo mno kuaminika kitakwimu.
  String summary() {
    final buf = StringBuffer();
    buf.writeln("═══════════════════════════════════════");
    buf.writeln("BACKTEST: $symbol");
    buf.writeln("Kipindi: ${start.toIso8601String()} -> ${end.toIso8601String()}");
    buf.writeln("═══════════════════════════════════════");
    buf.writeln("Jumla ya trades   : $totalTrades");
    buf.writeln("Ushindi (wins)    : $wins");
    buf.writeln("Hasara (losses)   : $losses");
    buf.writeln("Win rate          : ${winRatePct.toStringAsFixed(1)}%");
    buf.writeln(
      "Profit factor     : ${profitFactor == null ? 'N/A (hakuna hasara)' : profitFactor!.toStringAsFixed(2)}",
    );
    buf.writeln("Average R         : ${averageRMultiple.toStringAsFixed(2)}");
    buf.writeln("Max drawdown      : ${maxDrawdownPct.toStringAsFixed(1)}%");
    buf.writeln("Max losses mfululizo: $maxConsecutiveLosses");
    buf.writeln("Balance ya mwanzo : ${startingBalance.toStringAsFixed(2)}");
    buf.writeln("Balance ya mwisho : ${endingBalance.toStringAsFixed(2)}");
    buf.writeln("Total return      : ${totalReturnPct.toStringAsFixed(1)}%");

    if (totalTrades < 30) {
      buf.writeln("───────────────────────────────────────");
      buf.writeln(
        "⚠️ ONYO: trades $totalTrades ni SAMPULI NDOGO SANA. Kitakwimu, "
        "matokeo chini ya ~30 trades hayawezi kuaminiwa kutabiri "
        "utendaji wa baadaye - ongeza muda wa backtest (miaka zaidi) "
        "kabla ya kuamini namba hizi.",
      );
    }

    buf.writeln("═══════════════════════════════════════");
    return buf.toString();
  }
}

// =====================================================================
// ONGEZO JIPYA (kutoka TOP_DOWN.docx - kwa ombi la mtumiaji): CHART
// PATTERNS (Double Top/Bottom, Head & Shoulders) - hizi ni patterns
// "kubwa" zinazoundwa na swing points NYINGI (si candle 1-3 tu kama
// candlestick patterns) - zinaonekana kwenye D1 (muktadha wa "Major"
// kama hati ilivyoeleza), zikitoa ishara imara ZAIDI ya mabadiliko ya
// mwelekeo mkubwa kabisa.
// =====================================================================

class ChartPatternAnalysis {
  final bool doubleTop;
  final bool doubleBottom;
  final bool headAndShoulders; // bearish (reversal ya juu kwenda chini)
  final bool inverseHeadAndShoulders; // bullish (reversal ya chini kwenda juu)

  const ChartPatternAnalysis({
    this.doubleTop = false,
    this.doubleBottom = false,
    this.headAndShoulders = false,
    this.inverseHeadAndShoulders = false,
  });
}

ChartPatternAnalysis _detectChartPatterns(
  StructureAnalysis structure,
  double currentPrice,
) {
  final highs = structure.recentSwingHighs;
  final lows = structure.recentSwingLows;

  bool doubleTop = false;
  bool doubleBottom = false;
  bool headAndShoulders = false;
  bool inverseHeadAndShoulders = false;

  // Double Top: swing highs mbili za MWISHO zikiwa karibu sawa (tofauti
  // <0.3% ya bei) - "neckline" ni swing low kati yao - pattern
  // "inathibitika" mara bei ya SASA ikivunja chini ya neckline hiyo.
  if (highs.length >= 2 && lows.isNotEmpty) {
    final h1 = highs[highs.length - 2];
    final h2 = highs[highs.length - 1];
    final avgHigh = (h1 + h2) / 2;

    if (avgHigh > 0) {
      final diff = (h1 - h2).abs() / avgHigh;

      if (diff < 0.003) {
        final neckline = lows.last;
        if (currentPrice < neckline) {
          doubleTop = true;
        }
      }
    }
  }

  // Double Bottom: kioo (mirror) cha Double Top.
  if (lows.length >= 2 && highs.isNotEmpty) {
    final l1 = lows[lows.length - 2];
    final l2 = lows[lows.length - 1];
    final avgLow = (l1 + l2) / 2;

    if (avgLow > 0) {
      final diff = (l1 - l2).abs() / avgLow;

      if (diff < 0.003) {
        final neckline = highs.last;
        if (currentPrice > neckline) {
          doubleBottom = true;
        }
      }
    }
  }

  // Head & Shoulders: swing highs 3 za mwisho - "head" (ya kati) ndiyo
  // ya juu zaidi, "shoulders" (kushoto/kulia) zinakaribiana kwa urefu
  // (<1% tofauti) - pattern inathibitika mara bei ikivunja chini ya
  // "neckline" (swing low ya karibuni).
  if (highs.length >= 3) {
    final leftShoulder = highs[highs.length - 3];
    final head = highs[highs.length - 2];
    final rightShoulder = highs[highs.length - 1];

    if (head > 0) {
      final shoulderDiff = (leftShoulder - rightShoulder).abs() / head;

      if (head > leftShoulder &&
          head > rightShoulder &&
          shoulderDiff < 0.01) {
        final neckline = lows.isNotEmpty ? lows.last : 0.0;

        if (neckline > 0 && currentPrice < neckline) {
          headAndShoulders = true;
        }
      }
    }
  }

  // Inverse Head & Shoulders: kioo (mirror).
  if (lows.length >= 3) {
    final leftShoulder = lows[lows.length - 3];
    final head = lows[lows.length - 2];
    final rightShoulder = lows[lows.length - 1];

    if (head > 0) {
      final shoulderDiff = (leftShoulder - rightShoulder).abs() / head;

      if (head < leftShoulder &&
          head < rightShoulder &&
          shoulderDiff < 0.01) {
        final neckline = highs.isNotEmpty ? highs.last : 0.0;

        if (neckline > 0 && currentPrice > neckline) {
          inverseHeadAndShoulders = true;
        }
      }
    }
  }

  return ChartPatternAnalysis(
    doubleTop: doubleTop,
    doubleBottom: doubleBottom,
    headAndShoulders: headAndShoulders,
    inverseHeadAndShoulders: inverseHeadAndShoulders,
  );
}

// =====================================================================
// ONGEZO JIPYA (kutoka TOP_DOWN.docx - "Fibonacci in conjunction with
// any strategy" kwa PULLBACK entry): tunachunguza kama bei ya SASA
// iko ndani ya "eneo la dhahabu" la Fibonacci retracement (38.2% -
// 78.6%) kati ya swingLow na swingHigh za structure - eneo hili ndilo
// wafanyabiashara wengi wa SMC/ICT wanalotumia kutafuta PULLBACK
// ENTRY (kuingia wakati bei inaporudi nyuma kidogo ndani ya trend,
// si kuingia katikati ya "impulse move").
// =====================================================================

bool _inFibonacciZone({
  required double currentPrice,
  required double swingHigh,
  required double swingLow,
  required bool forBuy,
}) {
  final range = swingHigh - swingLow;

  if (range <= 0) return false;

  if (forBuy) {
    // Uptrend: pullback inapimwa kutoka swingHigh kurudi chini.
    final retracement = (swingHigh - currentPrice) / range;
    return retracement >= 0.382 && retracement <= 0.786;
  } else {
    // Downtrend: pullback inapimwa kutoka swingLow kurudi juu.
    final retracement = (currentPrice - swingLow) / range;
    return retracement >= 0.382 && retracement <= 0.786;
  }
}


class MarketAnalysisService {
  MarketAnalysisService._internal();
  static final instance = MarketAnalysisService._internal();

  final StreamController<MarketAnalysisResult> _controller =
      StreamController.broadcast();

  Stream<MarketAnalysisResult> get analysisStream => _controller.stream;

  final Map<String, MarketAnalysisResult> _latest = {};

  // ✅ FIX: alias for compatibility with trades.dart
  Map<String, MarketAnalysisResult> get latestKeys => _latest;

final Set<String> _queue = {};

final Map<String, DateTime> _lastRun = {};
final Map<String, DateTime> _lastEvent = {};

/// PROMAX Compatibility
final Map<String, bool> _isAnalyzing = {};
final Map<String, DateTime> _lastSignalTime = {};

Timer? _globalAnalysisTimer;

/// FIX: hizi hazikuwepo awali -> kila `startPairs()` ilipoitwa mara
/// ya pili (mf. reconnect), listener/timer mpya ziliundwa juu ya zile
/// za zamani bila kuzifuta (leak + event/analysis za mara mbili-mbili).
StreamSubscription? _wsSub;
Timer? _queueTimer;

/// signal cooldown
final Duration signalCooldown = const Duration(seconds: 8);

// FIX: field `cooldown` (Duration 3s) iliyokuwepo hapa iliondolewa -
// haikutumika mahali popote kwenye faili nzima (dead code). Kizuizi
// halisi cha "usichanganue pair moja mara mbili karibu-karibu" ni
// `_lastRun` (2500ms) ndani ya `_run()`.

// ================= DIAGNOSTIC COUNTERS (ONGEZO JIPYA) =================
// MADHUMUNI: kujibu swali "kwa nini Structure/Liquidity/OrderBlock/
// PriceAction ni 0.0 mara nyingi" kwa TAKWIMU HALISI (asilimia halisi
// ya mara ngapi kila kigezo kimefyatuka), badala ya kubishana kutoka
// kwenye sampuli chache za logi. Kila mzunguko wa _analyze() wenye
// data ya kutosha unaongeza kwenye counters hizi - zinaonyesha ukweli
// wa muda mrefu (si picha moja tu ya wakati mmoja).
int _totalAnalysisRuns = 0;

// ONGEZO JIPYA: kufuatilia NI ALAMA ZIPI hasa zimechambuliwa (na mara
// ngapi), tofauti na counters za vigezo hapo juu. Hii inajibu swali
// "je FRXEURUSD imewahi kuchambuliwa hata mara moja?" moja kwa moja,
// bila kubashiri kutoka logi.
final Map<String, int> _symbolRunCount = {};
final Map<String, DateTime> _symbolLastRun = {};

final Map<String, int> _componentFireCount = {
  'trend': 0,
  'liquidity': 0,
  'structure': 0,
  'orderBlock': 0,
  'priceAction': 0,
  'momentum': 0,
  'ema': 0,
  'rsi': 0,
};

// ONGEZO JIPYA: kufuatilia MWELEKEO HALISI (buy/sell/none) wa W1/D1
// kila mzunguko - hii inajibu swali "je BUY nyingi zinatoka wapi -
// TREND YENYEWE (data ya soko), au mahali PENGINE kwenye decision
// pipeline (bug inayoweza kukandamiza SELL)?" kwa uhakika. Kama
// '_w1BiasCount'/'_d1BiasCount' zenyewe zinaonyesha "buy" mara nyingi
// zaidi kuliko "sell" kwa UWIANO UNAOENDANA na jinsi 'decision'
// inavyoishia, basi chanzo ni DATA/TREND halisi (si bug). Kama trend
// ni MCHANGANYIKO (buy/sell karibu sawa) lakini 'decision' bado
// inaishia BUY karibu KILA WAKATI, basi kuna upendeleo (bug)
// mahali fulani KATI ya trend na uamuzi wa mwisho.
final Map<String, int> _w1BiasCount = {'buy': 0, 'sell': 0, 'none': 0};
final Map<String, int> _d1BiasCount = {'buy': 0, 'sell': 0, 'none': 0};

final Map<String, int> _decisionCount = {
  'wait': 0,
  'buy': 0,
  'strongBuy': 0,
  'sell': 0,
  'strongSell': 0,
};

/// Inarudisha ripoti ya asilimia halisi ya mara ngapi kila kigezo
/// kimefyatuka (kwa upande wowote - buy au sell) kati ya mizunguko
/// yote ya uchambuzi tangu injini ilipoanza (au tangu 'resetStats()'
/// ya mwisho). Itumike kujibu "je kigezo hiki ni nadra kihalali, au
/// halijawahi kufyatuka kabisa (bug)?" kwa uhakika, si kwa kukisia.
Map<String, dynamic> getSignalFrequencyStats() {
  if (_totalAnalysisRuns == 0) {
    return {
      'totalRuns': 0,
      'message': 'Bado hakuna mzunguko wa uchambuzi uliokamilika.',
    };
  }

  final percentages = <String, String>{};

  for (final entry in _componentFireCount.entries) {
    final pct = (entry.value / _totalAnalysisRuns) * 100;
    percentages[entry.key] = '${pct.toStringAsFixed(1)}% '
        '(${entry.value}/$_totalAnalysisRuns)';
  }

  return {
    'totalRuns': _totalAnalysisRuns,
    'frequencies': percentages,
  };
}

/// Chapisha ripoti hii kwa urahisi (mf. kwenye console/logs za server)
/// bila kuhitaji kusoma Map moja kwa moja.
void printSignalFrequencyStats() {
  final stats = getSignalFrequencyStats();

  if (stats['totalRuns'] == 0) {
    print('[DIAGNOSTIC] ${stats['message']}');
    return;
  }

  print('═══════════════════════════════════════');
  print('[DIAGNOSTIC] TAKWIMU ZA MARA NGAPI KILA KIGEZO KIMEFYATUKA');
  print('Jumla ya mizunguko iliyochambuliwa: ${stats['totalRuns']}');
  print('───────────────────────────────────────');

  final freq = stats['frequencies'] as Map<String, String>;
  for (final entry in freq.entries) {
    print('${entry.key.padRight(12)}: ${entry.value}');
  }

  print('═══════════════════════════════════════');
  print('[DIAGNOSTIC] MWELEKEO WA W1/D1 (chanzo cha TREND)');
  print('W1: buy=${_w1BiasCount['buy']} sell=${_w1BiasCount['sell']} '
      'none=${_w1BiasCount['none']}');
  print('D1: buy=${_d1BiasCount['buy']} sell=${_d1BiasCount['sell']} '
      'none=${_d1BiasCount['none']}');
  print('───────────────────────────────────────');
  print('[DIAGNOSTIC] MGAWANYO WA UAMUZI WA MWISHO');
  print(
    'wait=${_decisionCount['wait']} buy=${_decisionCount['buy']} '
    'strongBuy=${_decisionCount['strongBuy']} '
    'sell=${_decisionCount['sell']} '
    'strongSell=${_decisionCount['strongSell']}',
  );
  print('═══════════════════════════════════════');
  print(
    'TAFSIRI YA "KWA NINI BUY TU, HAKUNA SELL": Linganisha uwiano wa '
    'W1/D1 (buy dhidi ya sell) na uwiano wa uamuzi wa mwisho (buy '
    'dhidi ya sell). Kama uwiano UNAENDANA (mf. W1 ni 90% buy NA '
    'uamuzi wa mwisho ni ~90% buy) - upendeleo unatoka TREND YENYEWE '
    '(data ya soko/dirisha la muda, SI bug). Kama W1/D1 ni '
    'MCHANGANYIKO (mf. 50/50) LAKINI uamuzi wa mwisho bado ni BUY '
    'KARIBU KILA WAKATI - HILO ni ishara ya bug halisi kati ya trend '
    'na uamuzi wa mwisho inayohitaji kuchunguzwa zaidi.',
  );
}

/// Rudisha counters kwenye sifuri - muhimu kama unataka kupima
/// kipindi maalum (mf. baada ya kuanza upya server) badala ya
/// muunganiko wa muda wote tangu mwanzo.
void resetSignalFrequencyStats() {
  _totalAnalysisRuns = 0;
  for (final key in _componentFireCount.keys) {
    _componentFireCount[key] = 0;
  }
  for (final key in _w1BiasCount.keys) {
    _w1BiasCount[key] = 0;
  }
  for (final key in _d1BiasCount.keys) {
    _d1BiasCount[key] = 0;
  }
  for (final key in _decisionCount.keys) {
    _decisionCount[key] = 0;
  }
}

/// ONGEZO JIPYA: chapisha ni alama zipi kati ya 'expectedPairs'
/// (orodha uliyoipitisha kwenye startPairs()) ZIMEWAHI kuchambuliwa
/// (hata mara moja), zimechambuliwa mara ngapi, na lini mara ya
/// mwisho. Alama zenye "HAJAWAHI KABISA" ni ishara wazi kwamba
// hazijawahi kuingia kwenye foleni ya uchambuzi - tatizo liko kabla
/// ya _run() (mf. hazijawahi kupokea live tick/candle_update kutoka
/// Deriv - jambo la kawaida kwa forex nje ya saa za soko, au tatizo
/// la subscription).
void printSymbolCoverage(List<String> expectedPairs) {
  print('═══════════════════════════════════════');
  print('[DIAGNOSTIC] UFUATILIAJI WA ALAMA (SYMBOL COVERAGE)');
  print('───────────────────────────────────────');

  final neverRun = <String>[];

  for (final raw in expectedPairs) {
    final symbol = _normalize(raw);
    final count = _symbolRunCount[symbol];
    final last = _symbolLastRun[symbol];

    if (count == null || count == 0) {
      neverRun.add(symbol);
      print('$symbol : ❌ HAJAWAHI KUCHAMBULIWA KABISA');
    } else {
      final secondsAgo = last != null
          ? DateTime.now().difference(last).inSeconds
          : -1;
      print(
        '$symbol : ✅ mara $count | mara ya mwisho: ${secondsAgo}s zilizopita',
      );
    }
  }

  print('───────────────────────────────────────');
  print(
    'Jumla: ${expectedPairs.length - neverRun.length}/${expectedPairs.length} '
    'zimewahi kuchambuliwa. ${neverRun.length} hazijawahi kabisa.',
  );

  if (neverRun.isNotEmpty) {
    print('Alama HAZIJAWAHI kuchambuliwa: ${neverRun.join(", ")}');
    print(
      'SABABU ZINAZOWEZEKANA: (1) soko limefungwa kwa alama hizi (kwa '
      'mfano forex nje ya saa za biashara - synthetic indices hazina '
      'tatizo hili kwa sababu zinafanya kazi masaa 24), (2) '
      'subscribeCandles() haikufaulu kwa alama hizi, au (3) '
      'startPeriodicAnalysis() bado haijafika mzunguko wake wa kwanza '
      '(dakika 5) tangu kuanza kwa server.',
    );
  }

  print('═══════════════════════════════════════');
}

bool debugMode = true;

  void _log(String msg) {
    if (debugMode) print("[PROMAX ULTRA NEXT] $msg");
  }

  // ================= NORMALIZE =================
  // FIX: awali kulikuwa na replaceAll za no-op (R_→R_, 1HZ→1HZ, BOOM→BOOM,
  // CRASH→CRASH) ambazo hazikubadilisha chochote - zimeondolewa kwa usafi.
  String _normalize(String s) {
    return s.toUpperCase().trim();
  }

  // ================= START =================
  Future<void> startPairs(List<String> pairs) async {
    final deriv = DerivService.instance;

    await deriv.connect();
    _log("🚀 ENGINE STARTED");

    // 🚨 FIX (BUG KUBWA SANA - CHANZO HALISI cha "FRX/CRY/STPRNG
    // hazichambuliwi kamwe"): awali hapa 'p' (jina halisi la alama,
    // kama "frxEURUSD" - herufi mchanganyiko kama Deriv inavyolitaja)
    // lilikuwa likisawazishwa kuwa UPPERCASE ("FRXEURUSD") KABLA ya
    // kutumwa kwa deriv.subscribeCandles() - ambayo (kabla ya fix
    // iliyofanywa upande wa deriv_service.dart) ilikuwa ikituma jina
    // hilo LISILO SAHIHI moja kwa moja kwa Deriv halisi. Deriv haitambui
    // "FRXEURUSD" (jina lake halisi ni "frxEURUSD"), hivyo ilikuwa
    // ikirudisha candles 0 KIMYA KIMYA kwa kila alama yenye herufi
    // mchanganyiko kiasili (FRX*, CRY*, stpRNG*) - wakati alama zenye
    // UPPERCASE kiasili (R_50, 1HZ100V, BOOM500, JD50) hazikuathirika.
    //
    // Sasa 'p' (jina halisi, bila kubadilishwa) ndilo linalotumwa -
    // deriv.subscribeCandles() yenyewe italisawazisha kwa internal
    // bookkeeping (map keys) inapohitajika, bila kuathiri jina
    // linalotumwa kuwasiliana na Deriv.
    // 🚨 ONGEZO JIPYA (fix ya uwezekano wa "muunganiko kukatika chini
    // ya mzigo mkubwa"): awali alama zote (mf. 92) zilikuwa
    // zikitumiwa maombi YOTE (92 x TF 4 = maombi 368) KWA WAKATI
    // MMOJA bila mapumziko yoyote - "burst" kubwa ambayo INAWEZEKANA
    // kusababisha Deriv ku-rate-limit au kukata muunganiko wetu kwa
    // muda mfupi (jambo linaloweza kueleza "AuthorizationRequired"
    // isiyotarajiwa kwenye maombi mengine - kama 'balance' -
    // yanayotumwa wakati huo huo, endapo reconnect ya kimya
    // ilitokea). Sasa: mapumziko madogo (150ms) KATI YA ALAMA (si
    // kati ya kila TF - bado ni haraka vya kutosha) yanapunguza
    // "burst" hii kwa kiasi kikubwa.
    for (final p in pairs) {
      await deriv.subscribeCandles(p, tf: TF.h1);
      await deriv.subscribeCandles(p, tf: TF.h4);
      await deriv.subscribeCandles(p, tf: TF.d1);
      await deriv.subscribeCandles(p, tf: TF.w1);

      await Future.delayed(const Duration(milliseconds: 150));
    }

    // ⚠️ FIX: wsStream compatibility (safe fallback)
    // FIX (idempotency): kama startPairs() ikiitwa zaidi ya mara moja
    // (mf. baada ya reconnect), tulikuwa tunaunda listener/Timer mpya
    // kila wakati bila kufuta za zamani -> tick moja ingeweza kusababisha
    // _run() kuitwa mara nyingi kwa wakati mmoja, na Timer nyingi
    // zingeendelea kuishi milele (leak). Sasa zile za zamani zinafutwa
    // kwanza.
    await _wsSub?.cancel();
    _wsSub = deriv.stream.listen((event) {
      final type = event["msg_type"];
      final echo = event["echo_req"] ?? {};
      final raw = echo["ticks_history"];

      if (raw == null) return;

      final symbol = _normalize(raw);
      final now = DateTime.now();

      if (_lastEvent[symbol] != null &&
          now.difference(_lastEvent[symbol]!).inMilliseconds < 1200) {
        return;
      }

      _lastEvent[symbol] = now;

      if (type == "candles" ||
          type == "candles_update" ||
          type == "ohlc") {
        _queue.add(symbol);
      }
    });

    _queueTimer?.cancel();
    _queueTimer = Timer.periodic(const Duration(milliseconds: 800), (_) {
      _processQueue();
    });
  }

  // ================= PERIODIC (FORCED) ANALYSIS =================
  // FIX KUBWA: kazi hii awali ilikuwa imeandikwa NDANI ya mwili wa
  // startPairs() kama "local function" (angalia git history/awali).
  // Matokeo yake:
  //   1) Haikuwahi kuitwa mahali popote kwenye faili hii -> ilikuwa
  //      DEAD CODE kabisa, hivyo "re-scan ya kulazimishwa kila dakika 5"
  //      HAIKUWAHI kutokea kwenye engine halisi.
  //   2) Haikuwezekana kuiita kutoka nje ya startPairs() kwa sababu
  //      local function si method ya class -> kuita
  //      `MarketAnalysisService.instance.startPeriodicAnalysis(pairs)`
  //      kungeshindwa ku-compile.
  // Sasa ni method halisi ya class inayoweza kuitwa na caller yeyote
  // (mf. baada ya startPairs()) anayehitaji re-scan ya mara kwa mara.
  void startPeriodicAnalysis(List<String> pairs) {
    _globalAnalysisTimer?.cancel();

    _log("🚀 PERIODIC ANALYSIS STARTED");

    _globalAnalysisTimer = Timer.periodic(
      const Duration(minutes: 5),
      (_) async {
        _log("⏱ FORCED ANALYSIS ${DateTime.now()}");

        for (final pair in pairs) {
          await _run(pair);
        }

        _log("✅ PERIODIC ANALYSIS COMPLETE");

        // 🚨 ONGEZO JIPYA (hoja E - kwa ombi la mtumiaji): kazi hii
        // ilikuwepo TAYARI kwenye code (imejengwa awali) lakini
        // HAIKUWAHI KUITWA mahali popote - counters (_w1BiasCount,
        // _decisionCount) zilikuwa zikijazwa kimya kimya bila kuwahi
        // kuonekana. Sasa inachapishwa KILA mzunguko wa dakika 5,
        // ikitupa uwiano HALISI wa W1/D1 bias dhidi ya maamuzi ya
        // mwisho - hii ndiyo itakayothibitisha (au kukanusha) kama
        // "BUY tu" ni upendeleo wa data halisi ya soko, au tatizo la
        // mfumo.
        printSignalFrequencyStats();
      },
    );
  }

  // ================= STOP / CLEANUP =================
  // ONGEZA MPYA: hapakuwa na njia salama ya kuzima engine - timers na
  // stream subscription zingeendelea kuishi milele hata service
  // isipohitajika tena (mf. logout, dispose ya widget).
  Future<void> stop() async {
    _globalAnalysisTimer?.cancel();
    _globalAnalysisTimer = null;

    _queueTimer?.cancel();
    _queueTimer = null;

    await _wsSub?.cancel();
    _wsSub = null;

    _log("🛑 ENGINE STOPPED");
  }

  // ================= QUEUE =================
  Future<void> _processQueue() async {
    if (_queue.isEmpty) return;

    final symbol = _queue.first;
    _queue.remove(symbol);

    // FIX (suluhisho la "INSUFFICIENT H1" za muda mfupi mara baada ya
    // kuanzisha server - race condition halisi): awali, tick MOJA TU
    // (mf. jibu la kwanza la H1 kutoka Deriv baada ya
    // subscribeCandles) ilitosha kuingiza alama kwenye foleni na
    // kuita _run() papo hapo - hata kama H4/D1/W1 za alama hiyo hiyo
    // bado zinasubiriwa njiani (jambo la kawaida mara baada ya
    // startPairs() kutuma mamia ya maombi kwa mfululizo mmoja). Hii
    // ilisababisha _run() kuitwa MAPEMA MNO, kuandika "❌
    // INSUFFICIENT" bila sababu ya kweli, na kutumia (kupoteza)
    // 'cooldown' ya sekunde 2.5 kwenye jaribio lililokuwa tayari
    // limeshindwa - alama hiyo hiyo ingefanikiwa sekunde/dakika
    // chache baadaye bila tatizo lolote, lakini logi ilijaa "kelele"
    // isiyo na maana wakati wa uanzishaji.
    //
    // Sasa: kabla ya kuita _run(), tunahakikisha data ZOTE
    // zinazohitajika (H1>=120, H4>=50, D1>=50, W1>=20 - vigezo vile
    // vile halisi vinavyotumika na _run() yenyewe, angalia
    // DerivService.isReady()) tayari zimekamilika. Kama bado
    // hazijakamilika, tunaruka KIMYA KIMYA (bila log ya kushindwa,
    // bila kutumia cooldown) - tick inayofuata (au periodic scan ya
    // dakika 5 kupitia startPeriodicAnalysis) itajaribu tena
    // kiotomatiki bila hatua yoyote ya ziada inayohitajika.
    if (!DerivService.instance.isReady(symbol)) {
      return;
    }

    await _run(symbol);
  }

  // ================= RUN =================
  Future<void> _run(String pair) async {
    if (_isAnalyzing[pair] == true) {
      return;
    }

    _isAnalyzing[pair] = true;

    // FIX (bug mkubwa - "engine freeze" kwa alama moja moja):
    // Awali, ukaguzi wa cooldown ('_lastRun') ulikuwa na `return` NJE
    // ya try/finally. _isAnalyzing[pair] ilishawekwa `true` kabla ya
    // hapo, lakini kwa sababu return hiyo ilikuwa nje ya finally block,
    // haikuwahi kurudishwa `false`. Matokeo: mara tu candle-tick mbili
    // za pair fulani zikifika ndani ya 2.5s (jambo la kawaida sana),
    // pair hiyo ilifungwa MILELE - kila _run() ijayo ingesimama papo
    // hapo kwenye ukaguzi wa juu (_isAnalyzing == true) na alama hiyo
    // isingewahi kuchanganuliwa tena hadi app i-restart. Sasa mwili
    // WOTE wa kazi hii - ikiwemo return ya cooldown - uko ndani ya
    // try/finally ili _isAnalyzing irudi `false` daima.
    try {
      final now = DateTime.now();

      if (_lastRun[pair] != null &&
          now.difference(_lastRun[pair]!).inMilliseconds < 2500) {
        return;
      }

      _lastRun[pair] = now;

      final deriv = DerivService.instance;

      final symbol = deriv.normalizeSymbol(pair);

      final h1 = deriv.getCandles(symbol, TF.h1);
      final h4 = deriv.getCandles(symbol, TF.h4);
      final d1 = deriv.getCandles(symbol, TF.d1);
      final w1 = deriv.getCandles(symbol, TF.w1);

      // ONGEZO JIPYA: hesabu KILA JARIBIO la kuchambua alama hii - hata
      // kama itashindwa hapa chini kwa sababu ya data isiyotosha. Hii
      // inajibu moja kwa moja "je FRXEURUSD imewahi hata KUJARIBIWA
      // kuchambuliwa?" - tofauti na "imefaulu kuchambuliwa kikamilifu".
      _symbolRunCount[symbol] = (_symbolRunCount[symbol] ?? 0) + 1;
      _symbolLastRun[symbol] = DateTime.now();

      _log("📊 $symbol");
      _log("H1 = ${h1.length}");
      _log("H4 = ${h4.length}");
      _log("D1 = ${d1.length}");
      _log("W1 = ${w1.length}");

      if (h1.length < 120) {
        _log("❌ INSUFFICIENT H1 (${h1.length}/120)");
        return;
      }

      if (h4.length < 50) {
        _log("❌ INSUFFICIENT H4 (${h4.length}/50)");
        return;
      }

      if (d1.length < 50) {
        _log("❌ INSUFFICIENT D1 (${d1.length}/50)");
        return;
      }

      if (w1.length < 20) {
        _log("❌ INSUFFICIENT W1 (${w1.length}/20)");
        return;
      }

      final result = _analyze(symbol, w1, d1, h4, h1);

      _latest[symbol] = result;
      _controller.add(result);

      _log("✅ UPDATED $symbol | BUY:${result.canBuy} SELL:${result.canSell}");
    } catch (e, st) {
      _log("❌ RUN ERROR => $pair");
      _log("$e");
      _log("$st");
    } finally {
      _isAnalyzing[pair] = false;
    }
  }

  // ================= ANALYSIS =================
  MarketAnalysisResult _analyze(
    String pair,
    List<Candle> w1,
    List<Candle> d1,
    List<Candle> h4,
    List<Candle> h1,
  ) {
    final w1Bias = _bias(w1);
    final d1Bias = _bias(d1);

    // 🔍 ONGEZO JIPYA (kwa ombi la mtumiaji - "kwa nini BUY tu kwa
    // wiki mbili?"): tunachapisha tarehe HALISI ya candle ya MWISHO
    // ya W1/D1 - hii itatuonyesha WAZI kama data hii inasasishwa kweli
    // (tarehe za hivi karibuni, ndani ya siku/wiki 1) au imekwama
    // (stuck - tarehe za zamani sana, zisizolingana na "wiki mbili"
    // za sasa).
    if (w1.isNotEmpty) {
      final lastW1 = DateTime.fromMillisecondsSinceEpoch(
        w1.last.epoch * 1000,
        isUtc: true,
      );
      final ageInDays = DateTime.now().toUtc().difference(lastW1).inDays;
      _log(
        "🔍 W1 CANDLE YA MWISHO: $lastW1 (umri: siku $ageInDays) - "
        "${ageInDays > 10 ? '⚠️ INAWEZEKANA IMEKWAMA (stale)!' : 'inaonekana fresh'}",
      );
    } else {
      _log("🔍 W1 CANDLES: TUPU KABISA (orodha ina urefu 0)!");
    }

    if (d1.isNotEmpty) {
      final lastD1 = DateTime.fromMillisecondsSinceEpoch(
        d1.last.epoch * 1000,
        isUtc: true,
      );
      final ageInDays = DateTime.now().toUtc().difference(lastD1).inDays;
      _log(
        "🔍 D1 CANDLE YA MWISHO: $lastD1 (umri: siku $ageInDays) - "
        "${ageInDays > 2 ? '⚠️ INAWEZEKANA IMEKWAMA (stale)!' : 'inaonekana fresh'}",
      );
    } else {
      _log("🔍 D1 CANDLES: TUPU KABISA (orodha ina urefu 0)!");
    }

    final trendAligned =
        (w1Bias == d1Bias) && w1Bias != MarketBias.none;
_log("══════════════════════════════════════");
_log("TOP DOWN ANALYSIS");

_log("W1 BIAS : $w1Bias");
_log("D1 BIAS : $d1Bias");
_log("TREND ALIGN : $trendAligned");
_log("══════════════════════════════════════");


// ================= H4 SMART MONEY ANALYSIS =================

final h4Analysis =
    _analyzeH4(h4);

// 🚨🚨🚨 ONGEZO JIPYA (kutoka video za "Market Structure Trading
// Mastery" - kwa ombi la mtumiaji): "Internal vs External BoS/CHoCH"
// (eBoS/eCHoCH dhidi ya iBoS/iCHoCH) - External (H4, hapo juu) ni
// muundo wa MUDA MREFU (unaodumu), Internal (H1, hapa chini) ni
// muundo wa MUDA MFUPI - unaonyesha "pullback" ndani ya trend kubwa
// ya External. Hii inaruhusu ENTRY YENYE USAHIHI ZAIDI: hata kama
// External (H4) ni BUY imara, Internal (H1) CHoCH-down ikifuatiwa na
// Internal BOS-up upya inaonyesha WAZI kwamba pullback imeisha na
// trend kubwa inarudi kuendelea - wakati mzuri zaidi wa KUINGIA
// kuliko kuingia katikati ya "impulse move" bila uthibitisho wowote
// wa muda mfupi.
final internalStructure = _detectStructure(h1);

_log("INTERNAL (H1) BOS UP:${internalStructure.bosUp}");
_log("INTERNAL (H1) BOS DOWN:${internalStructure.bosDown}");
_log("INTERNAL (H1) CHOCH UP:${internalStructure.chochUp}");
_log("INTERNAL (H1) CHOCH DOWN:${internalStructure.chochDown}");

// ONGEZO JIPYA (kutoka TOP_DOWN.docx - "Major" chart patterns kwenye
// Daily/Weekly): tunatumia D1 structure (si H4/H1) kwa Chart Patterns
// - hizi zinahitaji "muda mrefu kuunda" ndiyo maana ni za maana zaidi
// (kama hati ilivyoeleza: "the longer it takes to form, the more
// significant it will likely play out").
final d1Structure = _detectStructure(d1);
final currentPrice = h1.isNotEmpty ? h1.last.close : 0.0;
final chartPatterns = _detectChartPatterns(d1Structure, currentPrice);

_log(
  "CHART PATTERNS (D1): DoubleTop=${chartPatterns.doubleTop} "
  "DoubleBottom=${chartPatterns.doubleBottom} "
  "H&S=${chartPatterns.headAndShoulders} "
  "InverseH&S=${chartPatterns.inverseHeadAndShoulders}",
);

// ONGEZO JIPYA (kutoka TOP_DOWN.docx - Fibonacci kwa pullback entry):
// tunatumia H4 swingHigh/swingLow (structure iliyopo tayari kwenye
// h4Analysis, angalia chini) kupima kama bei ya SASA iko ndani ya
// "eneo la dhahabu" (38.2%-78.6%) - eneo bora zaidi la kuingia
// (pullback), si katikati ya "impulse move".
final buyInFibZone = _inFibonacciZone(
  currentPrice: currentPrice,
  swingHigh: h4Analysis.structureSwingHigh,
  swingLow: h4Analysis.structureSwingLow,
  forBuy: true,
);

final sellInFibZone = _inFibonacciZone(
  currentPrice: currentPrice,
  swingHigh: h4Analysis.structureSwingHigh,
  swingLow: h4Analysis.structureSwingLow,
  forBuy: false,
);

_log("FIBONACCI ZONE (38.2%-78.6%): BUY=$buyInFibZone SELL=$sellInFibZone");

_log(
"H4 BOS UP:${h4Analysis.bosUp}"
);

_log(
"H4 BOS DOWN:${h4Analysis.bosDown}"
);

_log(
"H4 SWEEP HIGH:${h4Analysis.sweepHigh}"
);

_log(
"H4 SWEEP LOW:${h4Analysis.sweepLow}"
);

_log(
"H4 BUY SCORE:${h4Analysis.buyScore}"
);

_log(
"H4 SELL SCORE:${h4Analysis.sellScore}"
);

// 🚨🚨🚨 ONGEZO JIPYA (hoja B - kwa ombi la mtumiaji): "No Trade
// Zone" - usitoe signal ya BUY kama bei iko karibu SANA (chini ya
// 1 ATR) na resistance (structureSwingHigh) - hatari ya kukwama
// papo hapo. Vivyo hivyo, usitoe SELL kama bei iko karibu na
// support (structureSwingLow). Hii inazuia "kuchoma account" kwenye
// soko linalozunguka (ranging) karibu na kingo za range - tatizo
// lililoainishwa wazi kwenye uchambuzi wa nje.
// FIX: 'currentPrice' TAYARI imetangazwa hapo juu (Chart Patterns) -
// tunaitumia hiyo hiyo, si kuitangaza upya (ilikuwa ikisababisha
// hitilafu ya "already declared in this scope").
final ntzAtr = _atr(h1);

final distanceToResistance =
    (h4Analysis.structureSwingHigh - currentPrice).abs();
final distanceToSupport =
    (currentPrice - h4Analysis.structureSwingLow).abs();

final noTradeZoneBuy =
    ntzAtr > 0 &&
    h4Analysis.structureSwingHigh > 0 &&
    distanceToResistance < ntzAtr;

final noTradeZoneSell =
    ntzAtr > 0 &&
    h4Analysis.structureSwingLow > 0 &&
    distanceToSupport < ntzAtr;

_log(
  "NO TRADE ZONE: BUY-blocked=$noTradeZoneBuy "
  "(dist-to-resistance=${distanceToResistance.toStringAsFixed(5)} "
  "vs ATR=${ntzAtr.toStringAsFixed(5)}) | "
  "SELL-blocked=$noTradeZoneSell "
  "(dist-to-support=${distanceToSupport.toStringAsFixed(5)})",
);

    final last5 = h1.sublist(max(0, h1.length - 5));

    int bull = 0, bear = 0;
    for (final c in last5) {
      if (c.close > c.open) bull++;
      if (c.close < c.open) bear++;
    }

    final h1Buy = bull >= 3;
    final h1Sell = bear >= 3;

    // FIX (double counting ya score): hapa awali kulikuwa na ukaguzi wa
    // "engulfing" wa mkono (kwa kutumia h1.last/h1[length-2] moja kwa
    // moja) ambao ulikuwa ukiongeza +20 kwenye buyScore.priceAction /
    // sellScore.priceAction, KISHA chini kidogo `_detectPriceAction(h1)`
    // ilikuwa ikifanya ukaguzi wa engulfing (sahihi zaidi, wenye masharti
    // kamili ya "containment") na kuongeza +20 TENA kwa muundo ule ule
    // wa candle. Kwa vile masharti mawili yanapishana mara nyingi
    // (yanapotokea, karibu yanatokea pamoja), matokeo yalikuwa
    // priceAction score ya engulfing kuhesabiwa mara mbili (hadi +40
    // badala ya +20) bila sababu. Ukaguzi wa mkono umeondolewa na sasa
    // `_detectPriceAction()` peke yake ndiyo chanzo halali cha
    // engulfing (pamoja na pin bar, inside bar, doji, rejection).

    final buyScore = WeightedScore();
final sellScore = WeightedScore();

    // ================= HIGHER TIMEFRAME =================
    // 🚨🚨🚨 ONGEZO JIPYA (hoja A - kwa ombi la mtumiaji, baada ya
    // uchambuzi wa nje kuthibitisha tatizo halisi): uzito wa Trend
    // UMEPUNGUZWA sana (35 -> 12). AWALI: Trend(35)+Structure(30)=65
    // pekee zingeweza kusukuma uamuzi BILA uthibitisho wowote wa
    // liquidity sweep au order block - jambo linalofanya mfumo kuwa
    // "trend continuation detector" badala ya "institutional
    // entry engine" ya kweli. SASA: Trend ni MUKTADHA (context/filter)
    // yenye uzito mdogo, si "msukumo mkuu" wa uamuzi.
if (trendAligned &&
    w1Bias == MarketBias.buy) {
  buyScore.trend = 12;
}

if (trendAligned &&
    w1Bias == MarketBias.sell) {
  sellScore.trend = 12;
}

// ================= H4 STRUCTURE =================
// ONGEZO JIPYA (hoja A): 30 -> 18 - bado muhimu (BOS/CHOCH ni
// ishara halali), lakini si tena ya pili kwa ukubwa peke yake
// inayoweza (pamoja na Trend TU) kusukuma uamuzi bila liquidity/OB.

if (h4Analysis.bullish) {
  buyScore.structure = 18;
}

if (h4Analysis.bearish) {
  sellScore.structure = 18;
}

// ================= H4 LIQUIDITY =================
// ONGEZO JIPYA (hoja A): 15 -> 25 - Liquidity sweep ni ishara ya
// KUAMINIKA ZAIDI kwa "smart money" entry (institutional footprint)
// kuliko trend ya jumla - sasa ina uzito UNAOSTAHILI.

if (h4Analysis.sweepLow) {
  buyScore.liquidity = 25;
}

if (h4Analysis.sweepHigh) {
  sellScore.liquidity = 25;
}

// ================= H4 ORDER BLOCK =================
// ONGEZO JIPYA (hoja A): 15 -> 25 - Order Block (msingi wa SMC/ICT)
// sasa ina uzito sawa na Liquidity - hizi mbili kwa pamoja (50)
// zinapaswa kuwa MSINGI wa entry, si Trend/Structure.

if (h4Analysis.bullishOB) {
  buyScore.orderBlock = 25;
}

if (h4Analysis.bearishOB) {
  sellScore.orderBlock = 25;
}

// ================= H1 MOMENTUM =================
// ONGEZO JIPYA (hoja A): 20 -> 15 - kupunguzwa kidogo kuendana na
// uwiano mpya wa jumla.

if (h1Buy) {
  buyScore.momentum = 15;
}

if (h1Sell) {
  sellScore.momentum = 15;
}


// ================= PRICE ACTION =================

final priceAction =
    _detectPriceAction(h1);


if (priceAction.bullishEngulfing) {
  buyScore.priceAction += 20;
}


if (priceAction.bearishEngulfing) {
  sellScore.priceAction += 20;
}


if (priceAction.bullishPinBar) {
  buyScore.priceAction += 15;
}


if (priceAction.bearishPinBar) {
  sellScore.priceAction += 15;
}


if (priceAction.bullishRejection) {
  buyScore.priceAction += 15;
}


if (priceAction.bearishRejection) {
  sellScore.priceAction += 15;
}


if (priceAction.insideBar) {
  buyScore.priceAction += 5;
  sellScore.priceAction += 5;
}


if (priceAction.doji) {
  buyScore.priceAction -= 5;
  sellScore.priceAction -= 5;
}


// ================= ONGEZO JIPYA: PATTERNS KUTOKA "THE CANDLESTICK
// TRADING BIBLE" (kwa ombi la mtumiaji - kwenda sambamba na SMC/ICT
// tuliyokuwa nayo tayari) =================

if (priceAction.morningStar) {
  buyScore.priceAction += 20;
}

if (priceAction.eveningStar) {
  sellScore.priceAction += 20;
}

if (priceAction.dragonflyDoji) {
  buyScore.priceAction += 15;
}

if (priceAction.gravestoneDoji) {
  sellScore.priceAction += 15;
}

if (priceAction.tweezersBottom) {
  buyScore.priceAction += 12;
}

if (priceAction.tweezersTop) {
  sellScore.priceAction += 12;
}

// ONGEZO JIPYA (kutoka TOP_DOWN.docx - Chart Patterns kwenye D1,
// "Major" - uzito mkubwa zaidi kuliko candlestick patterns za H1,
// kwa sababu zinachukua muda mrefu ZAIDI kuunda - "the longer it
// takes to form, the more significant it will likely play out").
if (chartPatterns.doubleBottom || chartPatterns.inverseHeadAndShoulders) {
  buyScore.priceAction += 25;
}

if (chartPatterns.doubleTop || chartPatterns.headAndShoulders) {
  sellScore.priceAction += 25;
}

// ONGEZO JIPYA (kutoka TOP_DOWN.docx - Fibonacci "golden zone" kwa
// pullback entry - bonus ya ziada, si sehemu kuu ya score, kwa
// kuwa ni "confirmation ya wakati" (timing), si "smart money"
// confirmation kamili kama Liquidity/OrderBlock/Internal BOS).
if (buyInFibZone) {
  buyScore.priceAction += 10;
}

if (sellInFibZone) {
  sellScore.priceAction += 10;
}

_log(
    "Bull Engulf : ${priceAction.bullishEngulfing}");

_log(
    "Bear Engulf : ${priceAction.bearishEngulfing}");

_log("Dragonfly Doji (bullish) : ${priceAction.dragonflyDoji}");
_log("Gravestone Doji (bearish) : ${priceAction.gravestoneDoji}");
_log("Morning Star (bullish) : ${priceAction.morningStar}");
_log("Evening Star (bearish) : ${priceAction.eveningStar}");
_log("Tweezers Top (bearish) : ${priceAction.tweezersTop}");
_log("Tweezers Bottom (bullish) : ${priceAction.tweezersBottom}");

_log(
    "Bull PinBar : ${priceAction.bullishPinBar}");

_log(
    "Bear PinBar : ${priceAction.bearishPinBar}");

_log(
    "Inside Bar : ${priceAction.insideBar}");

_log(
    "Doji : ${priceAction.doji}");

_log(
    "Bull Reject : ${priceAction.bullishRejection}");

_log(
    "Bear Reject : ${priceAction.bearishRejection}");

// ================= EMA (ONGEZO JIPYA - halisi) =================
// FIX (data ya uongo iliyoondolewa): hapa ndipo EMA50/EMA200
// zinahesabiwa KWELI kutoka H1, na kutumika kama uthibitisho halisi
// wa mwelekeo - si tu kuripotiwa kama 'valid' bila kuathiri chochote.
final ema50Series = _calculateEMA(h1, 50);
final ema200Series = _calculateEMA(h1, 200);

// EMA inahitaji angalau candles 200 za H1 ili EMA200 iwe na maana -
// kama hazitoshi, 'emaDataSufficient=false' na EMA HAITUMIKI kwenye
// score (badala ya kudanganya na thamani ya uongo).
final emaDataSufficient = h1.length >= 200 &&
    ema50Series.isNotEmpty &&
    ema200Series.isNotEmpty;

bool emaBullish = false;
bool emaBearish = false;

if (emaDataSufficient) {
  final lastClose = h1.last.close;
  final lastEma50 = ema50Series.last;
  final lastEma200 = ema200Series.last;

  // Muundo wa kawaida wa "trend alignment": bei > EMA50 > EMA200 kwa
  // BUY (na kinyume chake kwa SELL) - hii ndiyo kanuni ya kawaida ya
  // uchambuzi wa kiufundi kupima mwelekeo wa muda wa kati.
  emaBullish = lastClose > lastEma50 && lastEma50 > lastEma200;
  emaBearish = lastClose < lastEma50 && lastEma50 < lastEma200;
}

// 🚨🚨🚨 ONGEZO JIPYA (hoja D - kwa ombi la mtumiaji): "Market Regime
// Filter" - mfumo haukuwa ukijua kama soko liko "trending" au
// "ranging" (linazunguka). Kwenye soko la ranging, mikakati ya
// "trend following" (mf. RSI veto softening kwa confluence>=4)
// inakuwa HATARI - ndiyo maana ilielezwa wazi kwenye uchambuzi wa
// nje: "Bei ikipanda kidogo: BUY. Ikishuka: SELL. Inakuwa inachoma
// account."
//
// Ishara rahisi ya "ranging": EMA50 na EMA200 ziko KARIBU SANA
// (chini ya asilimia ndogo ya bei) - mwelekeo wa muda wa kati
// haujakolea. Kwenye hali hii, tunazima "buyStrongTrendOverride"/
// "sellStrongTrendOverride" (softening ya RSI veto) - override hiyo
// ilikuwa imeundwa MAKUSUDI kwa ajili ya TREND IMARA, si soko
// linalozunguka.
bool isRanging = false;

if (emaDataSufficient && h1.last.close > 0) {
  final emaSpreadPercent =
      (ema50Series.last - ema200Series.last).abs() / h1.last.close;

  // Chini ya 0.1% ya bei - EMA50/200 ziko karibu mno, ishara ya
  // ranging/consolidation, si trend imara.
  isRanging = emaSpreadPercent < 0.001;
}

_log("MARKET REGIME: ${isRanging ? 'RANGING (softening ya RSI veto imezimwa)' : 'TRENDING'}");

if (emaBullish) {
  buyScore.ema = 10;
}

if (emaBearish) {
  sellScore.ema = 10;
}

_log("EMA50 (last): ${emaDataSufficient ? ema50Series.last : 'N/A - data haitoshi (<200 H1)'}");
_log("EMA200 (last): ${emaDataSufficient ? ema200Series.last : 'N/A - data haitoshi (<200 H1)'}");
_log("EMA Bullish : $emaBullish");
_log("EMA Bearish : $emaBearish");

// ================= RSI (ONGEZO JIPYA - halisi) =================
final rsiDataSufficient = h1.length >= 15;
final rsiValue = rsiDataSufficient ? _calculateRSI(h1, period: 14) : 50.0;

// Mwelekeo wa RSI (>50 unapendelea buy, <50 unapendelea sell).
final rsiBullish = rsiDataSufficient && rsiValue > 50;
final rsiBearish = rsiDataSufficient && rsiValue < 50;

// FIX (kanuni halisi ya kuepuka overtrading kwenye mwelekeo
// uliochoka): RSI>=70 = "overbought" (imenunuliwa kupita kiasi) -
// BUY mpya ni hatari zaidi hapa. RSI<=30 = "oversold" - SELL mpya ni
// hatari zaidi. Hii inatumika kama VETO ndani ya _makeDecision, si
// hapa tu kama score.
final rsiOverbought = rsiDataSufficient && rsiValue >= 70;
final rsiOversold = rsiDataSufficient && rsiValue <= 30;

if (rsiBullish) {
  buyScore.rsi = 5;
}

if (rsiBearish) {
  sellScore.rsi = 5;
}

_log("RSI(14) : ${rsiDataSufficient ? rsiValue.toStringAsFixed(1) : 'N/A - data haitoshi (<15 H1)'}");
_log("RSI Overbought(>=70) : $rsiOverbought");
_log("RSI Oversold(<=30) : $rsiOversold");

// ================= DIAGNOSTIC COUNTERS (ONGEZO JIPYA) =================
// Angalia maelezo marefu kwenye tamko la '_componentFireCount' hapo
// juu (karibu na mwanzo wa class). Hapa ndipo tunahesabu HALISI mara
// ngapi kila kigezo kimefyatuka (upande wowote - buy au sell) - si
// kubuni, ni kuhesabu matukio ya kweli kutoka kwenye score ilivyokuwa
// tayari imehesabiwa hapo juu.
_totalAnalysisRuns++;

if (buyScore.trend > 0 || sellScore.trend > 0) {
  _componentFireCount['trend'] = _componentFireCount['trend']! + 1;
}
if (buyScore.liquidity > 0 || sellScore.liquidity > 0) {
  _componentFireCount['liquidity'] = _componentFireCount['liquidity']! + 1;
}
if (buyScore.structure > 0 || sellScore.structure > 0) {
  _componentFireCount['structure'] = _componentFireCount['structure']! + 1;
}
if (buyScore.orderBlock > 0 || sellScore.orderBlock > 0) {
  _componentFireCount['orderBlock'] = _componentFireCount['orderBlock']! + 1;
}
if (buyScore.priceAction > 0 || sellScore.priceAction > 0) {
  _componentFireCount['priceAction'] =
      _componentFireCount['priceAction']! + 1;
}
if (buyScore.momentum > 0 || sellScore.momentum > 0) {
  _componentFireCount['momentum'] = _componentFireCount['momentum']! + 1;
}
if (buyScore.ema > 0 || sellScore.ema > 0) {
  _componentFireCount['ema'] = _componentFireCount['ema']! + 1;
}
if (buyScore.rsi > 0 || sellScore.rsi > 0) {
  _componentFireCount['rsi'] = _componentFireCount['rsi']! + 1;
}

// ONGEZO JIPYA: hesabu HALISI ya mwelekeo wa W1/D1 - angalia maelezo
// marefu kwenye tamko la '_w1BiasCount'/'_d1BiasCount' hapo juu.
final w1Key = w1Bias == MarketBias.buy
    ? 'buy'
    : (w1Bias == MarketBias.sell ? 'sell' : 'none');
_w1BiasCount[w1Key] = _w1BiasCount[w1Key]! + 1;

final d1Key = d1Bias == MarketBias.buy
    ? 'buy'
    : (d1Bias == MarketBias.sell ? 'sell' : 'none');
_d1BiasCount[d1Key] = _d1BiasCount[d1Key]! + 1;

   final buy =
    buyScore.total;

final sell =
    sellScore.total;
final buyConfidence =
    _calculateConfidence(
      buyScore,
    );


final sellConfidence =
    _calculateConfidence(
      sellScore,
    );


final confidence =
    buyConfidence.confidence >
    sellConfidence.confidence
        ? buyConfidence
        : sellConfidence;


final confluence =
    _buildConfluence(
      w1: w1Bias,
      d1: d1Bias,
      h4: h4Analysis,
      pa: priceAction,
      emaBullish: emaBullish,
      emaBearish: emaBearish,
      rsiBullish: rsiBullish,
      rsiBearish: rsiBearish,
    );


final decision =
    _makeDecision(
      buy: buy,
      sell: sell,
      confidence: confidence,
      h4: h4Analysis,
      confluence: confluence,
      rsiOverbought: rsiOverbought,
      rsiOversold: rsiOversold,
      // ONGEZO JIPYA (hoja C - kwa ombi la mtumiaji): buyScore/
      // sellScore zinapitishwa ili _makeDecision iweze kulazimisha
      // uthibitisho wa Liquidity AU OrderBlock (SMC halisi), si
      // Trend/Structure pekee - angalia maelezo marefu ndani ya
      // _makeDecision().
      buyLiquidity: buyScore.liquidity,
      buyOrderBlock: buyScore.orderBlock,
      sellLiquidity: sellScore.liquidity,
      sellOrderBlock: sellScore.orderBlock,
      // ONGEZO JIPYA (hoja B): No Trade Zone flags.
      noTradeZoneBuy: noTradeZoneBuy,
      noTradeZoneSell: noTradeZoneSell,
      // ONGEZO JIPYA (hoja D): Market Regime Filter.
      isRanging: isRanging,
      // ONGEZO JIPYA (kutoka video - "Internal vs External BOS").
      internalBosUp: internalStructure.bosUp,
      internalBosDown: internalStructure.bosDown,
    );

// ONGEZO JIPYA: hesabu HALISI ya uamuzi wa mwisho (wait/buy/
// strongBuy/sell/strongSell) - ikilinganishwa na
// '_w1BiasCount'/'_d1BiasCount' hapo juu, hii inatuonyesha WAZI kama
// upendeleo wa BUY unatoka TREND YENYEWE (data), au kama unaongezeka
// zaidi KATI ya trend na uamuzi wa mwisho (ishara ya bug).
final decisionKey = switch (decision.decision) {
  TradeDecision.wait => 'wait',
  TradeDecision.buy => 'buy',
  TradeDecision.strongBuy => 'strongBuy',
  TradeDecision.sell => 'sell',
  TradeDecision.strongSell => 'strongSell',
};
_decisionCount[decisionKey] = _decisionCount[decisionKey]! + 1;


// FIX #4 (ilisasishwa): 'confluenceOk'/'enoughConfirmations' za zamani
// zilitumia 'confluence.aligned'/'confirmations' za JUMLA (bila
// mwelekeo) - hitilafu iliyoelezwa kwenye ConfluenceAnalysis. Sasa
// SAFETY GATE hii ya pili inatumia 'buyAligned'/'sellAligned' MOJA
// KWA MOJA - sambamba kabisa na ulinzi ulio ndani ya _makeDecision
// (hakuna tena uwezekano wa kupishana kati ya gate mbili).
final rawIsBuy =
    (decision.decision == TradeDecision.buy ||
        decision.decision == TradeDecision.strongBuy) &&
    confluence.buyAligned;

final rawIsSell =
    (decision.decision == TradeDecision.sell ||
        decision.decision == TradeDecision.strongSell) &&
    confluence.sellAligned;

// FIX #5: 'signalCooldown' na '_lastSignalTime' zilikuwa dead code
// (hazijawahi kutekelezwa) -> engine ingeweza kutuma signal ile ile
// mara kwa mara kila 'periodic analysis' (dakika 5) bila kizuizi,
// hatari ya OVERTRADING kwenye setup moja. Sasa: signal mpya ya
// BUY/SELL inaruhusiwa TU ikiwa cooldown ya pair hii imepita.
bool isBuy = rawIsBuy;
bool isSell = rawIsSell;

if (rawIsBuy || rawIsSell) {
  final lastSignal = _lastSignalTime[pair];
  final now = DateTime.now();

  final withinCooldown = lastSignal != null &&
      now.difference(lastSignal) < signalCooldown;

  if (withinCooldown) {
    _log(
      "⏳ SIGNAL COOLDOWN ACTIVE for $pair "
      "(${now.difference(lastSignal).inSeconds}s < "
      "${signalCooldown.inSeconds}s) -> BLOCKED",
    );
    isBuy = false;
    isSell = false;
  } else {
    _lastSignalTime[pair] = now;
  }
}
_log(
"BUY CONFIDENCE:"
"${buyConfidence.confidence}% "
"${buyConfidence.quality}"
);


_log(
"SELL CONFIDENCE:"
"${sellConfidence.confidence}% "
"${sellConfidence.quality}"
);

_log("══════════════════════");

_log("BUY SCORE");

_log("Trend      : ${buyScore.trend}");

_log("Liquidity  : ${buyScore.liquidity}");

_log("Structure  : ${buyScore.structure}");

_log("OrderBlock : ${buyScore.orderBlock}");

_log("PriceAction: ${buyScore.priceAction}");

_log("Momentum   : ${buyScore.momentum}");

_log("TOTAL BUY  : ${buyScore.total}");

_log("══════════════════════");

_log("SELL SCORE");

_log("Trend      : ${sellScore.trend}");

_log("Liquidity  : ${sellScore.liquidity}");

_log("Structure  : ${sellScore.structure}");

_log("OrderBlock : ${sellScore.orderBlock}");

_log("PriceAction: ${sellScore.priceAction}");

_log("Momentum   : ${sellScore.momentum}");

_log("TOTAL SELL : ${sellScore.total}");

_log("══════════════════════════════");

_log("CONFLUENCE");

_log("Confirmations : ${confluence.confirmations}");

_log("Aligned : ${confluence.aligned}");

_log("Score : ${confluence.score}");

_log("══════════════════════════════");


    final atr = _atr(h1);
    final entry = h1.last.close;

    // 🚨 FIX (bug hatari sana - "position sizing explosion" kwenye
    // ATR ndogo mno): forex H1 candles za WIKENDI (soko limefungwa,
    // hakuna biashara) mara nyingi zina high==low (upeo wa sifuri).
    // Kama dirisha la ATR (candles 14 za mwisho) likijumuisha candles
    // hizi 'flat' (jambo la kawaida kwa H1 karibu na Ijumaa jioni/
    // Jumapili), wastani wa ATR unaweza kushuka karibu SIFURI - si
    // sifuri kamili (ambayo tayari ilikuwa ikizuiwa na ukaguzi wa
    // 'atr <= 0' hapa chini), bali ndogo sana (mf. 0.00001) ambayo
    // BADO inapita ukaguzi huo.
    //
    // Athari: stopDistance (= |entry - stopLoss| = atr) inakuwa ndogo
    // mno, na position sizing (lots = riskAmount / stopDistance)
    // 'INALIPUKA' kuwa kubwa kupita kiasi - hata mabadiliko madogo ya
    // bei baadaye yanazalisha hasara ya MAMIA YA ASILIMIA badala ya
    // 1% iliyokusudiwa. Hii ndiyo hasa iliyosababisha matokeo ya ajabu
    // tuliyoyaona kwenye backtest (FRXGBPCHF: -660% drawdown kutoka
    // trade MOJA TU) - alama za synthetic (zinazofanya biashara masaa
    // 24) hazikuathirika kabisa, kama ilivyotarajiwa kwa nadharia hii.
    //
    // FIX: ATR sasa ina KIWANGO CHA CHINI KABISA (floor) cha 0.05% ya
    // bei ya entry - kama ATR halisi iko chini ya hapo, tunatumia
    // floor hii badala yake kuhesabu stopLoss/takeProfit. Hii
    // inahakikisha stopDistance HAIWEZI KUWA NDOGO ISIVYO KAWAIDA,
    // kulinda dhidi ya "position sizing explosion" - MUHIMU kwa
    // USALAMA WA LIVE TRADING pia, si backtest tu.
    final minAtr = entry * 0.0005;
    final safeAtr = atr < minAtr ? minAtr : atr;

    // ================= SL/TP: STRUCTURE-AWARE (ONGEZO JIPYA) =================
    // FIX (SL/TP zenye ufahamu wa muundo wa soko - kwa ombi la
    // mtumiaji): awali SL/TP zilikuwa zikitumia ATR "kipofu" (umbali
    // wa kudhania, bila kujali muundo halisi wa soko - swingHigh/
    // swingLow/OB tuliyoshahesabu kabisa kwenye 'h4Analysis' hazikuwa
    // zikitumika KAMWE kwenye uamuzi wa SL/TP). Sasa: SL inawekwa
    // KIDOGO NYUMA ya kiwango cha KWELI cha muundo (swing ya
    // karibuni, au OB kama ipo na iko mbali zaidi) - kanuni ya
    // kawaida ya usimamizi wa hatari (weka SL mahali ambapo, kama
    // ikigongwa, inamaanisha KWELI wazo la trade limekosewa - si
    // mahali pa kudhania).
    //
    // TP inatokana na UMBALI HALISI wa SL hii mpya (bado uwiano wa
    // 1:3) - kwa hiyo TP NAYO inabadilika kulingana na muundo halisi,
    // si nafasi ya kudhania iliyotenganishwa na soko.
    double stopLossFinal;

    // 🚨🚨🚨 ONGEZO JIPYA (kwa ombi la mtumiaji - "trades.dart iendane
    // na uchambuzi wetu mpya"): SL sasa inazingatia PIA Internal (H1)
    // structure (iliyoongezwa leo), si H4 pekee. Kwa kuwa entries
    // sasa zinathibitishwa kwa usahihi zaidi (kupitia Internal BOS -
    // pullback imeisha - au Fibonacci Golden Zone), SL inaweza kuwa
    // KARIBU ZAIDI na entry (bado ndani ya muundo halali) bila
    // kupoteza usalama - hii inaboresha R:R (uwiano wa hatari kwa
    // faida) moja kwa moja, kwa sababu TP (1:3) inatokana na umbali
    // wa SL: SL ndogo zaidi = TP karibu zaidi = uwezekano mkubwa
    // zaidi wa kufikiwa kabla ya bei kugeuka. Tunachagua SL "IMARA
    // ZAIDI" (tighter, karibu zaidi na entry) kati ya H4 na Internal
    // (H1) - MRADI zote mbili ni HALALI (ndani ya mipaka ya usalama
    // ile ile: >0, upande sahihi, <=5xATR).
    if (isBuy) {
      double buyLevel = h4Analysis.structureSwingLow;

      if (h4Analysis.bullishOB && h4Analysis.obLow > 0) {
        buyLevel = min(buyLevel, h4Analysis.obLow);
      }

      // Buffer ndogo (0.2xATR) chini ya kiwango cha muundo - kanuni
      // ya kawaida ya kuepuka "stop hunting" karibu na viwango
      // dhahiri ambavyo wafanyabiashara wengine wanaweka SL zao.
      final h4StructureSL = buyLevel - (safeAtr * 0.2);
      final h4Distance = entry - h4StructureSL;

      final h4Valid = buyLevel > 0 &&
          h4StructureSL < entry &&
          h4Distance > 0 &&
          h4Distance <= safeAtr * 5;

      // ONGEZO JIPYA: internal (H1) swingLow - kiwango cha muundo wa
      // MUDA MFUPI, mara nyingi KARIBU ZAIDI na entry kuliko H4.
      final internalLevel = internalStructure.swingLow;
      final internalStructureSL = internalLevel - (safeAtr * 0.2);
      final internalDistance = entry - internalStructureSL;

      final internalValid = internalLevel > 0 &&
          internalStructureSL < entry &&
          internalDistance > 0 &&
          internalDistance <= safeAtr * 5;

      if (h4Valid && internalValid) {
        // Chagua ILIYO KARIBU ZAIDI (distance ndogo zaidi) - SL
        // "IMARA ZAIDI" (tighter) bado ndani ya muundo halali.
        stopLossFinal =
            internalDistance < h4Distance ? internalStructureSL : h4StructureSL;
      } else if (internalValid) {
        stopLossFinal = internalStructureSL;
      } else if (h4Valid) {
        stopLossFinal = h4StructureSL;
      } else {
        stopLossFinal = entry - safeAtr;
      }
    } else {
      double sellLevel = h4Analysis.structureSwingHigh;

      if (h4Analysis.bearishOB && h4Analysis.obHigh > 0) {
        sellLevel = max(sellLevel, h4Analysis.obHigh);
      }

      final h4StructureSL = sellLevel + (safeAtr * 0.2);
      final h4Distance = h4StructureSL - entry;

      final h4Valid = sellLevel > 0 &&
          h4StructureSL > entry &&
          h4Distance > 0 &&
          h4Distance <= safeAtr * 5;

      final internalLevel = internalStructure.swingHigh;
      final internalStructureSL = internalLevel + (safeAtr * 0.2);
      final internalDistance = internalStructureSL - entry;

      final internalValid = internalLevel > 0 &&
          internalStructureSL > entry &&
          internalDistance > 0 &&
          internalDistance <= safeAtr * 5;

      if (h4Valid && internalValid) {
        stopLossFinal =
            internalDistance < h4Distance ? internalStructureSL : h4StructureSL;
      } else if (internalValid) {
        stopLossFinal = internalStructureSL;
      } else if (h4Valid) {
        stopLossFinal = h4StructureSL;
      } else {
        stopLossFinal = entry + safeAtr;
      }
    }

    final stopDistanceFinal = (entry - stopLossFinal).abs();

    _log(
      "SL FINAL: $stopLossFinal (distance: ${stopDistanceFinal.toStringAsFixed(5)}, "
      "ATR: ${safeAtr.toStringAsFixed(5)}) - inatumia H4 na/au Internal "
      "(H1) structure, ile iliyo KARIBU ZAIDI (imara zaidi) kati ya "
      "hizo mbili zilizo halali.",
    );

    final takeProfitFinal = isBuy
        ? entry + stopDistanceFinal * 3
        : entry - stopDistanceFinal * 3;

    // ================= SAFETY =================
    if (entry <= 0 || atr <= 0) {
      return MarketAnalysisResult(
        symbol: pair,
        candles: h1,
        candlesH1: h1,
        candlesM15: h4,
        candlesM30: d1,
        candlesM5: const [],
        canBuy: false,
        canSell: false,
        // KUMBUKA (server 1): modeli ya server hii HAINA
        // 'isValidTrade' - imeondolewa kimakusudi (tofauti na toleo
        // la server 2).
        structureValid: false,
        emaValid: false,
        rsiValid: false,
        confirmationValid: false,
        filtersValid: false,
        ema50: const [],
        ema200: const [],
        indicators: {"error": "INVALID_PRICE_DATA"},
        entryCandles: const [],
        structurePoints: const [],
        conditionsMet: const [],
        reasonsFailed: const ["Invalid entry or ATR = 0"],
        stopLoss: 0,
        takeProfit: 0,
        structureBuy: false,
        structureSell: false,
        biasIsBuy: false,

        // FIX: 'isValidTrade' iliondolewa - MarketAnalysisResult ya
        // mradi huu HAINA field hii (tofauti na dhana yangu ya awali).
        // Popote palipohitajika kujua "je trade ni halali", tumia
        // 'canBuy || canSell' moja kwa moja badala yake.

        risk: RiskModel(
          entry: 0,
          stopLoss: 0,
          takeProfit: 0,
          lotSize: 0,
          direction: "NONE",
        ),
      );
    }
_log("==============================");
_log("FINAL DECISION:");
_log("${decision.decision}");
_log("TRADE ALLOWED:${decision.allowed}");
_log("==============================");

// ONGEZO JIPYA (kuondoa "pambo" halisi): 'conditionsMet' na
// 'reasonsFailed' zilikuwa TUPU KILA WAKATI hapo awali - licha ya
// majina yao kuahidi maelezo muhimu ya ukaguzi. Sasa zinajengwa
// kutoka vigezo halisi TAYARI tulizohesabu hapo juu - zinatoa
// maelezo ya KIBINADAMU ya KWA NINI uamuzi ulifikiwa (au
// haukufikiwa). Hii ni muhimu kwa ukaguzi (audit) na kwa server ya
// risk management kuelewa muktadha bila kulazimika kutafsiri namba
// za 'indicators' peke yake.
final conditionsMetList = <String>[];
final reasonsFailedList = <String>[];

if (isBuy || isSell) {
  final dir = isBuy;

  if (trendAligned) {
    conditionsMetList.add(
      "W1/D1 Trend Aligned (${dir ? 'BUY' : 'SELL'})",
    );
  }
  if (dir ? h4Analysis.bosUp : h4Analysis.bosDown) {
    conditionsMetList.add("H4 Break of Structure (BOS)");
  }
  if (dir ? h4Analysis.chochUp : h4Analysis.chochDown) {
    conditionsMetList.add("H4 Change of Character (CHOCH)");
  }
  if (dir ? h4Analysis.sweepHigh : h4Analysis.sweepLow) {
    conditionsMetList.add("H4 Liquidity Sweep");
  }
  if (dir ? h4Analysis.bullishOB : h4Analysis.bearishOB) {
    conditionsMetList.add("H4 Order Block (haijamitigatiwa)");
  }
  if (dir ? h4Analysis.momentumUp : h4Analysis.momentumDown) {
    conditionsMetList.add("H4 Momentum Breakout (candles 10)");
  }
  if (dir ? priceAction.bullishEngulfing : priceAction.bearishEngulfing) {
    conditionsMetList.add("H1 Engulfing Pattern");
  }
  if (dir ? priceAction.bullishPinBar : priceAction.bearishPinBar) {
    conditionsMetList.add("H1 Pin Bar");
  }
  if (dir
      ? priceAction.bullishRejection
      : priceAction.bearishRejection) {
    conditionsMetList.add("H1 Rejection Candle");
  }
  // ONGEZO JIPYA: patterns kutoka "The Candlestick Trading Bible".
  if (dir ? priceAction.morningStar : priceAction.eveningStar) {
    conditionsMetList.add(
      dir ? "H1 Morning Star (candles 3)" : "H1 Evening Star (candles 3)",
    );
  }
  if (dir ? priceAction.dragonflyDoji : priceAction.gravestoneDoji) {
    conditionsMetList.add(
      dir ? "H1 Dragonfly Doji" : "H1 Gravestone Doji",
    );
  }
  if (dir ? priceAction.tweezersBottom : priceAction.tweezersTop) {
    conditionsMetList.add(
      dir ? "H1 Tweezers Bottom" : "H1 Tweezers Top",
    );
  }
  // ONGEZO JIPYA (kutoka TOP_DOWN.docx/video - Chart Patterns,
  // Internal Structure, na Fibonacci).
  if (dir
      ? (chartPatterns.doubleBottom || chartPatterns.inverseHeadAndShoulders)
      : (chartPatterns.doubleTop || chartPatterns.headAndShoulders)) {
    conditionsMetList.add(
      dir
          ? (chartPatterns.doubleBottom
              ? "D1 Double Bottom"
              : "D1 Inverse Head & Shoulders")
          : (chartPatterns.doubleTop
              ? "D1 Double Top"
              : "D1 Head & Shoulders"),
    );
  }
  if (dir ? internalStructure.bosUp : internalStructure.bosDown) {
    conditionsMetList.add("Internal (H1) BOS - pullback imeisha");
  }
  if (dir ? buyInFibZone : sellInFibZone) {
    conditionsMetList.add("Fibonacci Golden Zone (38.2%-78.6%)");
  }
  if (dir ? emaBullish : emaBearish) {
    conditionsMetList.add("EMA50/EMA200 Alignment");
  }
  if (dir ? rsiBullish : rsiBearish) {
    conditionsMetList.add("RSI Confirms Direction");
  }
  if (dir ? h1Buy : h1Sell) {
    conditionsMetList.add("H1 Momentum (candles 5 za mwisho)");
  }
}

if (!decision.allowed) {
  if (!confidence.valid) {
    reasonsFailedList.add(
      "Confidence chini ya kizingiti "
      "(${confidence.confidence.toStringAsFixed(0)}% < 60%)",
    );
  }
  if (!confluence.buyAligned && !confluence.sellAligned) {
    reasonsFailedList.add(
      "Confluence haijafikia kizingiti "
      "(buy:${confluence.buyConfirmations}/6, "
      "sell:${confluence.sellConfirmations}/6, inahitajika >=3)",
    );
  }
  if (buy > sell && !h4Analysis.bullish) {
    reasonsFailedList.add("H4 structure haijathibitisha upande wa BUY");
  }
  if (sell > buy && !h4Analysis.bearish) {
    reasonsFailedList.add("H4 structure haijathibitisha upande wa SELL");
  }
  if (buy > sell && rsiOverbought && confluence.buyConfirmations < 4) {
    reasonsFailedList.add(
      "RSI Overbought na confluence haina nguvu ya kutosha (<4) "
      "kuruhusu 'strong trend override'",
    );
  }
  if (sell > buy && rsiOversold && confluence.sellConfirmations < 4) {
    reasonsFailedList.add(
      "RSI Oversold na confluence haina nguvu ya kutosha (<4) "
      "kuruhusu 'strong trend override'",
    );
  }
  // ONGEZO JIPYA (hoja C, B, D - kwa ombi la mtumiaji): sababu mpya
  // za kuzuia trade.
  if (buy > sell &&
      buyScore.liquidity == 0 &&
      buyScore.orderBlock == 0 &&
      !internalStructure.bosUp) {
    reasonsFailedList.add(
      "Hakuna uthibitisho wa 'smart money' (Liquidity sweep, Order "
      "Block, AU Internal BOS/H1) kwa upande wa BUY - Trend/Structure "
      "pekee hazitoshi",
    );
  }
  if (sell > buy &&
      sellScore.liquidity == 0 &&
      sellScore.orderBlock == 0 &&
      !internalStructure.bosDown) {
    reasonsFailedList.add(
      "Hakuna uthibitisho wa 'smart money' (Liquidity sweep, Order "
      "Block, AU Internal BOS/H1) kwa upande wa SELL - Trend/Structure "
      "pekee hazitoshi",
    );
  }
  if (buy > sell && noTradeZoneBuy) {
    reasonsFailedList.add(
      "BUY imezuiwa - bei iko karibu mno (chini ya ATR 1) na "
      "resistance (No Trade Zone)",
    );
  }
  if (sell > buy && noTradeZoneSell) {
    reasonsFailedList.add(
      "SELL imezuiwa - bei iko karibu mno (chini ya ATR 1) na "
      "support (No Trade Zone)",
    );
  }
  if (isRanging) {
    reasonsFailedList.add(
      "Soko liko 'ranging' (EMA50/200 karibu sana) - softening ya "
      "RSI veto imezimwa kwa usalama",
    );
  }
  if (reasonsFailedList.isEmpty) {
    reasonsFailedList.add(
      "Hakuna mwelekeo wenye ushindi wa wazi (buy na sell ziko karibu "
      "sawa, au masharti mengine ya _makeDecision hayajatimia)",
    );
  }
}

// ONGEZO JIPYA (aina ya data ilithibitishwa kutoka
// models/market_analysis_result.dart: List<Map<String, dynamic>>):
// 'structurePoints' sasa ina viwango HALISI vya bei vilivyotambuliwa
// kwenye H4 - swing high/low ya structure, na eneo la order block
// (kama lipo) - badala ya kubaki tupu daima.
final structurePointsList = <Map<String, dynamic>>[
  {
    "type": "swingHigh",
    "price": h4Analysis.structureSwingHigh,
  },
  {
    "type": "swingLow",
    "price": h4Analysis.structureSwingLow,
  },
  if (h4Analysis.bullishOB || h4Analysis.bearishOB)
    {
      "type": h4Analysis.bullishOB ? "bullishOrderBlock" : "bearishOrderBlock",
      "high": h4Analysis.obHigh,
      "low": h4Analysis.obLow,
      "mitigated": h4Analysis.mitigated,
    },
];

// ================= SMC EXTRA (ONGEZO JIPYA) =================
// Vipengele vifuatavyo vyote ni HALISI (vinahesabiwa kutoka data ya
// kweli), si "pambo" - kila kimoja kina maelezo ya kanuni iliyotumika.

// Fair Value Gaps + Imbalance (imbalance = uwepo wa FVG isiyojazwa
// bado, kwa mwelekeo husika - dhana zinazohusiana moja kwa moja
// kwenye SMC).
final fairValueGapsList = _detectFairValueGaps(h1);
final bullishImbalanceNow =
    fairValueGapsList.any((g) => g["direction"] == 1.0);
final bearishImbalanceNow =
    fairValueGapsList.any((g) => g["direction"] == -1.0);

// Premium/Discount Zone - kutumia swing high/low ya H4 (kutoka
// structurePointsList hapo juu) kama "range" ya sasa. Bei iliyo NUSU
// YA JUU ya range = "premium" (ghali - kuuza kunapendelewa); nusu ya
// chini = "discount" (rahisi - kununua kunapendelewa). Kanuni ya
// kawaida ya SMC.
final rangeHigh = h4Analysis.structureSwingHigh;
final rangeLow = h4Analysis.structureSwingLow;
final rangeMid = (rangeHigh + rangeLow) / 2;
final premiumZoneNow = rangeHigh > rangeLow && entry > rangeMid;
final discountZoneNow = rangeHigh > rangeLow && entry < rangeMid;

// Order Flow - tunatumia _bias() (iliyokwisha kuthibitika kwa
// W1/D1) HII HII kwenye H1, kubaini mwelekeo wa HH/HL (bullish
// order flow) au LH/LL (bearish order flow) wa muda mfupi zaidi -
// dhana TOFAUTI na BOS/CHOCH (ambazo ni MATUKIO ya kuvunja, si
// MFUATANO wa jumla wa muundo).
final h1OrderFlowBias = _bias(h1);
final bullishOrderFlowNow = h1OrderFlowBias == MarketBias.buy;
final bearishOrderFlowNow = h1OrderFlowBias == MarketBias.sell;

// Inducement - liquidity sweep ikifuatiwa na BOS ya UPANDE MWINGINE
// (mtego wa liquidity kabla ya mwendo halisi - dhana ya kawaida ya
// SMC: "sweep the lows, then break structure up" = mtego wa
// wauzaji kabla ya kupanda).
final inducementNow =
    (h4Analysis.sweepLow && h4Analysis.bosUp) ||
    (h4Analysis.sweepHigh && h4Analysis.bosDown);

// Multi-Candle Confirmation - candles 3 za H1 za mwisho ZOTE
// zikielekea upande mmoja (mwelekeo ulioshinda) - uthibitisho wa
// nguvu zaidi kuliko candle moja pekee.
bool multiCandleConfirmationNow = false;
if ((isBuy || isSell) && h1.length >= 3) {
  final last3 = h1.sublist(h1.length - 3);
  if (isBuy) {
    multiCandleConfirmationNow = last3.every((c) => c.close > c.open);
  } else if (isSell) {
    multiCandleConfirmationNow = last3.every((c) => c.close < c.open);
  }
}

// Rejection Block - kutumia 'priceAction' tuliyoshaihesabu (candle
// yenye "wick" ndefu inayokataa kiwango cha bei).
final rejectionBlockNow =
    priceAction.bullishRejection || priceAction.bearishRejection;

// Session Validity - kutumia _currentSession() (FINALLY inatumia
// 'MarketSession' enum iliyokuwa dead code). Kwa synthetic/crypto
// (zinazofanya biashara masaa 24 bila "sessions" za kweli),
// tunachukulia TRUE daima - dhana ya session inahusu forex pekee.
final currentSession = _currentSession();
final sessionValidNow =
    !pair.toUpperCase().startsWith('FRX') ||
    currentSession != MarketSession.unknown;

// Volatility Validity - ATR ya sasa (candles 14) ikilinganishwa na
// ATR ndefu zaidi (candles 50) - epuka masoko "yamekufa" (ATR ndogo
// mno kulinganisha na wastani wake) AU "yanaruka" baada ya habari
// kubwa (ATR kubwa mno kulinganisha na wastani - hatari ya slippage).
final atrLong = _atr(h1.length >= 50 ? h1.sublist(h1.length - 50) : h1);
final volatilityValidNow =
    atrLong > 0 && atr > (atrLong * 0.3) && atr < (atrLong * 3.0);

// Entry Points - maeneo yanayowezekana ya kuingia: bei ya soko ya
// sasa, na (kama ipo) eneo la order block kwa "retest" ya baadaye.
final entryPointsList = <Map<String, dynamic>>[
  {
    "type": "market",
    "price": entry,
  },
  if (h4Analysis.bullishOB || h4Analysis.bearishOB)
    {
      "type": "orderBlockRetest",
      "high": h4Analysis.obHigh,
      "low": h4Analysis.obLow,
    },
];

// ONGEZO JIPYA: print za console kwa vipengele vipya vya SMC Extra -
// kwa ajili ya uthibitisho wa macho (visual confirmation), sambamba
// na jinsi Structure/Liquidity/OB/EMA/RSI tayari zinavyochapishwa.
_log("══════════════════════════════");
_log("SMC EXTRA");
_log("Fair Value Gaps : ${fairValueGapsList.length} "
    "(unfilled: bullish=${fairValueGapsList.where((g) => g["direction"] == 1.0).length}, "
    "bearish=${fairValueGapsList.where((g) => g["direction"] == -1.0).length})");
_log("Bullish Imbalance : $bullishImbalanceNow");
_log("Bearish Imbalance : $bearishImbalanceNow");
_log("Premium Zone : $premiumZoneNow");
_log("Discount Zone : $discountZoneNow");
_log("Bullish Order Flow (H1 HH/HL) : $bullishOrderFlowNow");
_log("Bearish Order Flow (H1 LH/LL) : $bearishOrderFlowNow");
_log("Inducement (sweep + opposite BOS) : $inducementNow");
_log("Multi-Candle Confirmation (H1 x3) : $multiCandleConfirmationNow");
_log("Rejection Block : $rejectionBlockNow");
_log("Current Session : $currentSession");
_log("Session Valid : $sessionValidNow");
_log("ATR(14) vs ATR(50) : ${atr.toStringAsFixed(5)} vs ${atrLong.toStringAsFixed(5)}");
_log("Volatility Valid : $volatilityValidNow");
_log("Order Blocks (candles) : ${h4Analysis.obBaseCandle != null ? 1 : 0}");
_log("Entry Points : ${entryPointsList.length}");
_log("══════════════════════════════");

    return MarketAnalysisResult(
      symbol: pair,
      candles: h1,
      candlesH1: h1,
      candlesM15: h4,
      candlesM30: d1,
      candlesM5: const [],

      canBuy: isBuy,
      canSell: isSell,

      // KUMBUKA (server 1): modeli ya server hii HAINA 'isValidTrade'
      // - imeondolewa kimakusudi. Tumia 'canBuy || canSell' popote
      // panapohitajika dhana hii.

      // FIX (uongo uliondolewa): hizi zilikuwa 'true' bila masharti -
      // sasa zinaonyesha UKWELI wa kama data ilitosha kuhesabu kila
      // kimoja. 'structureValid' inaangalia masharti yale yale ya
      // ndani yanayotumika na _detectStructure/_detectLiquidity/
      // _detectInstitutionalOB (>=30 kwa H4, angalia _analyzeH4).
      structureValid: h4.length >= 30,
      emaValid: emaDataSufficient,
      rsiValid: rsiDataSufficient,
      confirmationValid: isBuy || isSell,
      filtersValid:
    confidence.confidence >= 60,

      // ONGEZO JIPYA (kuondoa "pambo" kwenye ngazi ya modeli): fields
      // hizi zote zilikuwa zikibaki kwenye thamani za DEFAULT za
      // modeli (false/0) KILA WAKATI, bila kujali matokeo halisi ya
      // uchambuzi - kwa sababu hazikuwahi kuwekwa (set) kabisa hapa.
      // Data zote hizi TAYARI zilikuwa zikihesabiwa mahali pengine
      // ndani ya _analyze()/_analyzeH4() - zilikuwa tu hazijafikishwa
      // kwenye matokeo ya mwisho.
      buyScore: buy,
      sellScore: sell,
      confidence: confidence.confidence,
      trendAlignment: trendAligned,

      bos: h4Analysis.bosUp || h4Analysis.bosDown,
      choch: h4Analysis.chochUp || h4Analysis.chochDown,
      liquiditySweep: h4Analysis.sweepHigh || h4Analysis.sweepLow,
      equalHighs: h4Analysis.equalHighs,
      equalLows: h4Analysis.equalLows,
      mitigation: h4Analysis.mitigated,

      // TP = 3xATR, SL = 1xATR kwa muundo wa sasa wa risk (angalia
      // 'stopLoss'/'takeProfit' chini) - hivyo Risk:Reward inayotarajiwa
      // ni 3.0 daima kwa muundo huu. Kama utabadilisha uwiano wa ATR
      // hapo chini siku moja, hakikisha unabadilisha hii pia.
      expectedRR: 3.0,

      // ONGEZO JIPYA (SMC EXTRA - angalia hesabu kamili hapo juu):
      fairValueGaps: fairValueGapsList,
      orderBlocks: h4Analysis.obBaseCandle != null
          ? [h4Analysis.obBaseCandle!]
          : const [],
      premiumZone: premiumZoneNow,
      discountZone: discountZoneNow,
      bullishOrderFlow: bullishOrderFlowNow,
      bearishOrderFlow: bearishOrderFlowNow,
      bullishImbalance: bullishImbalanceNow,
      bearishImbalance: bearishImbalanceNow,
      inducement: inducementNow,
      multiCandleConfirmation: multiCandleConfirmationNow,
      rejectionBlock: rejectionBlockNow,
      sessionValid: sessionValidNow,
      volatilityValid: volatilityValidNow,
      entryPoints: entryPointsList,

      // KUMBUKA: 'breakerBlock' na 'probability' zimebaki kwenye
      // default (false/0) KWA MAKUSUDI - hazina msingi wa uhakika wa
      // kuhesabiwa bado:
      //  - 'breakerBlock' inahitaji kufuatilia OB nyingi kwa muda (si
      //    moja tu ya karibuni kama ilivyo sasa) NA uthibitisho wa
      //    baadaye kwamba ilivunjika na kubadili "role" - miundombinu
      //    hii haipo bado.
      //  - 'probability' ingehitaji backtest ya kutosha (30+ trades)
      //    iliyopangwa kwa "bucket" za confidence ili kutoa asilimia
      //    ya ushindi HALISI ya kihistoria - kutunga namba bila hilo
      //    kungekuwa ni "pambo" jipya, si uboreshaji.

      // FIX (data ya uongo iliyoondolewa): ilikuwa 'const []' KILA
      // WAKATI - sasa ni matokeo HALISI ya _calculateEMA() (orodha
      // tupu TU kama kweli data haitoshi, si kwa chaguo-msingi).
      ema50: ema50Series,
      ema200: ema200Series,

indicators: {

  "buy": buy,

  "sell": sell,

  "confidence": confidence.confidence,

  "decision":
      decision.decision.toString(),

  "allowed":
      decision.allowed,

  "trendAligned":
      trendAligned,

  "confluence":
      confluence.score,

  "confirmations":
      confluence.confirmations,

  // ONGEZO JIPYA: uwazi kamili wa confluence yenye mwelekeo, na
  // EMA/RSI - vyote havikuonekana kabisa kwenye indicators awali.
  "buyConfirmations":
      confluence.buyConfirmations,

  "sellConfirmations":
      confluence.sellConfirmations,

  "buyAligned":
      confluence.buyAligned,

  "sellAligned":
      confluence.sellAligned,

  "ema50Last":
      emaDataSufficient ? ema50Series.last : null,

  "ema200Last":
      emaDataSufficient ? ema200Series.last : null,

  "emaBullish":
      emaBullish,

  "emaBearish":
      emaBearish,

  "rsi":
      rsiDataSufficient ? rsiValue : null,

  "rsiOverbought":
      rsiOverbought,

  "rsiOversold":
      rsiOversold,


  "buyConfidence":
      buyConfidence.confidence,


  "sellConfidence":
      sellConfidence.confidence,


  "buyQuality":
      buyConfidence.quality,


  "sellQuality":
      sellConfidence.quality,

  // ONGEZO JIPYA: haya yalikuwa yakihesabiwa ndani ya _analyze() lakini
  // HAYAKUWAHI kuwekwa kwenye matokeo - server/UI ya nje haikuwa na
  // njia ya kuyaona kabisa. Muhimu sana kwa server ya pili inayofanya
  // risk management yake YENYEWE - inahitaji muktadha kamili, si tu
  // "BUY/SELL/WAIT" ya mwisho.
  "w1Bias": w1Bias.toString(),
  "d1Bias": d1Bias.toString(),

  "h4BosUp": h4Analysis.bosUp,
  "h4BosDown": h4Analysis.bosDown,
  "h4ChochUp": h4Analysis.chochUp,
  "h4ChochDown": h4Analysis.chochDown,
  "h4SweepHigh": h4Analysis.sweepHigh,
  "h4SweepLow": h4Analysis.sweepLow,
  "h4BullishOB": h4Analysis.bullishOB,
  // ONGEZO JIPYA (kutoka video - "Internal vs External BOS/CHOCH").
  "internalBosUp": internalStructure.bosUp,
  "internalBosDown": internalStructure.bosDown,
  "internalChochUp": internalStructure.chochUp,
  "internalChochDown": internalStructure.chochDown,
  // ONGEZO JIPYA (kutoka TOP_DOWN.docx - Chart Patterns na Fibonacci).
  "doubleTop": chartPatterns.doubleTop,
  "doubleBottom": chartPatterns.doubleBottom,
  "headAndShoulders": chartPatterns.headAndShoulders,
  "inverseHeadAndShoulders": chartPatterns.inverseHeadAndShoulders,
  "buyInFibZone": buyInFibZone,
  "sellInFibZone": sellInFibZone,
  "h4BearishOB": h4Analysis.bearishOB,
  "h4MomentumUp": h4Analysis.momentumUp,
  "h4MomentumDown": h4Analysis.momentumDown,
  "h4BuyScore": h4Analysis.buyScore,
  "h4SellScore": h4Analysis.sellScore,

  "bullishEngulfing": priceAction.bullishEngulfing,
  "bearishEngulfing": priceAction.bearishEngulfing,
  "bullishPinBar": priceAction.bullishPinBar,
  "bearishPinBar": priceAction.bearishPinBar,
  "insideBar": priceAction.insideBar,
  "doji": priceAction.doji,
  "bullishRejection": priceAction.bullishRejection,
  "bearishRejection": priceAction.bearishRejection,
  // ONGEZO JIPYA: patterns kutoka "The Candlestick Trading Bible".
  "dragonflyDoji": priceAction.dragonflyDoji,
  "gravestoneDoji": priceAction.gravestoneDoji,
  "morningStar": priceAction.morningStar,
  "eveningStar": priceAction.eveningStar,
  "tweezersTop": priceAction.tweezersTop,
  "tweezersBottom": priceAction.tweezersBottom,

  // 🚨 ONGEZO JIPYA (fix ya bug halisi - "data haifiki UI"): fields
  // hizi zote zilikuwa zikihesabiwa na kuwekwa kama TOP-LEVEL fields
  // za MarketAnalysisResult - lakini 'signals_server.dart' inatuma
  // 'result.indicators' (Map hii hii) TU kwenda UI, si object nzima
  // ya MarketAnalysisResult. Bila kuziongeza HAPA pia, thamani hizi
  // zingebaki "zimefungwa" ndani ya server hii milele - zisizoweza
  // kufika kwa UI/server ya risk management licha ya kuhesabiwa
  // sahihi kabisa. Sasa zinapatikana kwenye payload ya WebSocket pia.
  "buyScoreTotal": buy,
  "sellScoreTotal": sell,
  "confidenceTotal": confidence.confidence,
  "trendAlignment": trendAligned,
  "bos": h4Analysis.bosUp || h4Analysis.bosDown,
  "choch": h4Analysis.chochUp || h4Analysis.chochDown,
  "liquiditySweep": h4Analysis.sweepHigh || h4Analysis.sweepLow,
  "equalHighsBool": h4Analysis.equalHighs,
  "equalLowsBool": h4Analysis.equalLows,
  "mitigation": h4Analysis.mitigated,
  "expectedRR": 3.0,

  "fairValueGapsCount": fairValueGapsList.length,
  "fairValueGaps": fairValueGapsList,
  "bullishImbalance": bullishImbalanceNow,
  "bearishImbalance": bearishImbalanceNow,
  "premiumZone": premiumZoneNow,
  "discountZone": discountZoneNow,
  "bullishOrderFlow": bullishOrderFlowNow,
  "bearishOrderFlow": bearishOrderFlowNow,
  "inducement": inducementNow,
  "multiCandleConfirmation": multiCandleConfirmationNow,
  "rejectionBlockZone": rejectionBlockNow,
  "currentSession": currentSession.toString(),
  "sessionValid": sessionValidNow,
  "atrShort": atr,
  "atrLong": atrLong,
  "volatilityValid": volatilityValidNow,
  "conditionsMet": conditionsMetList,
  "reasonsFailed": reasonsFailedList,

},
      entryCandles: h1.length >= 10 ? h1.sublist(h1.length - 10) : h1,
      // KUMBUKA: 'structurePoints' imebaki 'const []' kimakusudi -
      // tofauti na 'conditionsMet'/'reasonsFailed' (ambazo ni
      // List<String>, zilizothibitishwa na mfano wa
      // 'reasonsFailed: const ["Insufficient data"]' uliokuwepo
      structurePoints: structurePointsList,
      conditionsMet: conditionsMetList,
      reasonsFailed: reasonsFailedList,

      stopLoss: stopLossFinal,
      takeProfit: takeProfitFinal,

      structureBuy: isBuy,
      structureSell: isSell,
      biasIsBuy: isBuy,

      // FIX: 'isValidTrade' iliondolewa (angalia maelezo kwenye
      // fallback hapo juu) - MarketAnalysisResult ya mradi huu haina
      // field hii. 'canBuy'/'canSell' (tayari zipo juu) ndizo
      // zinazobeba taarifa hii.

      risk: RiskModel(
        entry: entry,
        stopLoss: stopLossFinal,
        takeProfit: takeProfitFinal,
        lotSize: 0.1,
        direction: isBuy
            ? "BUY"
            : isSell
                ? "SELL"
                : "NONE",
      ),
    );
  }

  // ================= HELPERS =================
MarketBias _bias(List<Candle> candles) {

if(candles.length < 50){
 return MarketBias.none;
}


int higherHigh = 0;
int higherLow = 0;

int lowerHigh = 0;
int lowerLow = 0;


for(int i=5;i<candles.length-5;i++){

final current = candles[i];


bool isHigh =
 current.high >
 candles[i-1].high &&
 current.high >
 candles[i+1].high;


bool isLow =
 current.low <
 candles[i-1].low &&
 current.low <
 candles[i+1].low;


if(isHigh){

if(current.high >
candles[i-5].high){

higherHigh++;

}else{

lowerHigh++;

}

}


if(isLow){

if(current.low >
candles[i-5].low){

higherLow++;

}else{

lowerLow++;

}

}

}


_log(
"STRUCTURE HH:$higherHigh HL:$higherLow LH:$lowerHigh LL:$lowerLow"
);


if(
higherHigh>=2 &&
higherLow>=2
){

return MarketBias.buy;

}


if(
lowerHigh>=2 &&
lowerLow>=2
){

return MarketBias.sell;

}


return MarketBias.none;

}
  

LiquidityAnalysis _detectLiquidity(
    List<Candle> candles,
) {
  if (candles.length < 20) {
    return const LiquidityAnalysis(
      sweepHigh: false,
      sweepLow: false,
      equalHighs: 0,
      equalLows: 0,
      highest: 0,
      lowest: 0,
    );
  }

  final last = candles.last;

  final atr = _atr(candles);
  final tolerance = atr * 0.15;

  // FIX (bug halisi ya kuhesabu): awali 'highest'/'lowest' zilikuwa
  // zikisasishwa (running max/min) NDANI ya loop hiyo hiyo iliyokuwa
  // ikilinganisha 'c.high' dhidi ya 'highest' - kwa hiyo candle
  // YOYOTE iliyoweka rekodi mpya ya juu zaidi ilikuwa ikijilinganisha
  // NA YENYEWE (diff=0) na kuhesabiwa kama "equal high" kiotomatiki.
  // Hii ilichanganya (ilikuza kwa uongo) equalHighs/equalLows, jambo
  // lililoathiri masharti ya 'sweepHigh'/'sweepLow' (yanayohitaji
  // equalHighs/equalLows >= 2) kutokutabirika. Sasa: PASS YA KWANZA
  // inapata 'highest'/'lowest' HALISI (bila kubadilika), KISHA PASS
  // YA PILI inahesabu ni candle ngapi zilizogusa karibu na hiyo
  // thamani ya mwisho (fixed reference) - hesabu sahihi ya "equal
  // highs/lows" (liquidity pool ya kweli).
  double highest = -double.infinity;
  double lowest = double.infinity;

  for (int i = candles.length - 20; i < candles.length - 1; i++) {
    final c = candles[i];
    if (c.high > highest) highest = c.high;
    if (c.low < lowest) lowest = c.low;
  }

  int equalHighs = 0;
  int equalLows = 0;

  for (int i = candles.length - 20; i < candles.length - 1; i++) {
    final c = candles[i];
    if ((c.high - highest).abs() < tolerance) equalHighs++;
    if ((c.low - lowest).abs() < tolerance) equalLows++;
  }

  final sweepHigh =
      last.high > highest &&
      last.close < highest &&
      equalHighs >= 2;

  final sweepLow =
      last.low < lowest &&
      last.close > lowest &&
      equalLows >= 2;

  return LiquidityAnalysis(
    sweepHigh: sweepHigh,
    sweepLow: sweepLow,
    equalHighs: equalHighs,
    equalLows: equalLows,
    highest: highest,
    lowest: lowest,
  );
}

StructureAnalysis _detectStructure(
  List<Candle> candles,
) {
  if (candles.length < 30) {
    return const StructureAnalysis(
      bosUp: false,
      bosDown: false,
      chochUp: false,
      chochDown: false,
      swingHigh: 0,
      swingLow: 0,
    );
  }

  // FIX (usafi wa code): variable 'last' (candles.last) haitumiki tena
  // moja kwa moja hapa - bosUp/bosDown/chochUp/chochDown sasa
  // zinatokana kikamilifu na orodha ya 'breaks' iliyopangwa (angalia
  // chini), si candle ya mwisho peke yake.

  // FIX / MABORESHO MAKUBWA (kwa ombi la mtumiaji - "kwa nini
  // hazitumii historical data zaidi kubaini structure"): awali
  // dirisha la kutafuta swingHigh/swingLow lilikuwa fupi SANA
  // (candles 20 za mwisho TU), na lilikuwa likichukua tu MAX/MIN ya
  // candles hizo - si swing points za KWELI (fractal/pivot za
  // uchambuzi wa muundo wa soko). Hii ilikuwa na tatizo kubwa: swing
  // ya ZAMANI ambayo BADO IKO HAI (haijavunjwa) lakini iko ZAIDI ya
  // candles 20 nyuma ilikuwa ikipuuzwa kabisa - BOS halisi (bei
  // ikivunja swing ya kweli ya wiki 2-3 zilizopita, ambayo bado ni
  // muhimu kwa sababu haijavunjwa tangu wakati huo) ingekosekana.
  //
  // SASA: tunatumia "fractal/pivot" HALISI - kanuni ya kawaida ya
  // uchambuzi wa muundo wa soko: candle ni "swing high" kama high yake
  // ni kubwa kuliko candles 2 KABLA na candles 2 BAADA yake (na
  // kinyume chake kwa "swing low"). Tunatafuta fractal hizi kwenye
  // dirisha REFU zaidi (candles 150 za mwisho, ~siku 25 za H4 - si
  // candles 20 tu), kisha tunachagua swing ya KARIBUNI ZAIDI ambayo
  // BADO HAIJAVUNJWA (hakuna candle yoyote tangu wakati huo
  // iliyofunga (close) juu/chini yake) - hata kama swing hiyo iko
  // mbali zaidi ya candles 20 za mwisho.
  final lookback = min(150, candles.length - 1);
  final windowStart = candles.length - 1 - lookback;

  const fractalArm = 2; // candles 2 kila upande wa swing

  final swingHighs = <_SwingPoint>[];
  final swingLows = <_SwingPoint>[];

  for (int i = windowStart + fractalArm;
      i < candles.length - 1 - fractalArm;
      i++) {
    final c = candles[i];

    bool isSwingHigh = true;
    bool isSwingLow = true;

    for (int j = i - fractalArm; j <= i + fractalArm; j++) {
      if (j == i) continue;
      if (candles[j].high >= c.high) isSwingHigh = false;
      if (candles[j].low <= c.low) isSwingLow = false;
    }

    if (isSwingHigh) {
      swingHighs.add(_SwingPoint(index: i, price: c.high));
    }

    if (isSwingLow) {
      swingLows.add(_SwingPoint(index: i, price: c.low));
    }
  }

  // Tafuta swing high/low ya KARIBUNI ZAIDI ambayo BADO HAIJAVUNJWA -
  // tunaanzia swing ya mwisho kabisa (karibuni zaidi) tukienda nyuma,
  // na kuchukua ya KWANZA tunayoipata isiyovunjwa.
  double? activeSwingHigh;
  double? activeSwingLow;

  for (int k = swingHighs.length - 1; k >= 0; k--) {
    final sp = swingHighs[k];
    bool broken = false;

    for (int m = sp.index + 1; m < candles.length - 1; m++) {
      if (candles[m].close > sp.price) {
        broken = true;
        break;
      }
    }

    if (!broken) {
      activeSwingHigh = sp.price;
      break;
    }
  }

  for (int k = swingLows.length - 1; k >= 0; k--) {
    final sp = swingLows[k];
    bool broken = false;

    for (int m = sp.index + 1; m < candles.length - 1; m++) {
      if (candles[m].close < sp.price) {
        broken = true;
        break;
      }
    }

    if (!broken) {
      activeSwingLow = sp.price;
      break;
    }
  }

  // Fallback: kama hakuna fractal halisi iliyopatikana kwenye dirisha
  // (jambo linalowezekana kwenye soko tulivu/lisilo na muundo wazi),
  // tumia max/min ya dirisha refu - angalau tunapata namba halisi, si
  // null.
  final swingHigh = activeSwingHigh ??
      candles
          .sublist(windowStart, candles.length - 1)
          .map((c) => c.high)
          .reduce(max);

  final swingLow = activeSwingLow ??
      candles
          .sublist(windowStart, candles.length - 1)
          .map((c) => c.low)
          .reduce(min);

  // FIX / MABORESHO MAKUBWA #2 (hoja sahihi kabisa ya mtumiaji:
  // "structure si tukio la candle moja - ni HALI inayoendelea, kama
  // mchambuzi wa kweli anavyoiona akifungua chati wakati wowote, bila
  // kusubiri candle mpya - kwa kutumia TOP-DOWN, Fibonacci, Elliott
  // Wave kwenye candles ZILIZOPO tayari"): awali 'bosUp'/'bosDown'
  // zilikuwa zikiuliza TU "je candle ya SASA imevunja swing" - tukio
  // la nadra sana (flash event) linalotoa 'false' mara nyingi hata
  // kama tuko wazi kwenye structure fulani. Sasa tunatafuta TUKIO LA
  // MWISHO LA KUVUNJA (BOS) LOLOTE - la juu AU chini - miongoni mwa
  // swing points ZOTE za dirisha (si candle ya mwisho tu), kisha
  // MWELEKEO wa tukio hilo la mwisho unakuwa "structure regime ya
  // SASA" - hii INADUMU (inabaki BUY au SELL) kwa candles nyingi
  // mfululizo, hadi structure itakapovunjika tena upande mwingine -
  // sawa kabisa na jinsi structure "inavyoonekana" ukiangalia chati
  // wakati wowote, si tu kwenye candle iliyopita ya breakout.
  final breaks = <_BreakEvent>[];

  for (final sp in swingHighs) {
    for (int m = sp.index + 1; m < candles.length; m++) {
      if (candles[m].close > sp.price) {
        breaks.add(_BreakEvent(m, true));
        break;
      }
    }
  }

  for (final sp in swingLows) {
    for (int m = sp.index + 1; m < candles.length; m++) {
      if (candles[m].close < sp.price) {
        breaks.add(_BreakEvent(m, false));
        break;
      }
    }
  }

  breaks.sort((a, b) => a.index.compareTo(b.index));

  final bosUp = breaks.isNotEmpty && breaks.last.isUp;

  final bosDown = breaks.isNotEmpty && !breaks.last.isUp;

  // CHOCH (change of character): sasa ni "mabadiliko HALISI ya
  // structure regime yaliyotokea HIVI KARIBUNI" (ndani ya candles 5
  // za mwisho) - yaani tukio la mwisho la kuvunja lilitofautiana
  // MWELEKEO na tukio lililotangulia (mf. tulikuwa bearish, ghafla
  // tumevunja upande wa juu - mabadiliko halisi ya tabia), SI tu
  // mwendelezo wa mwelekeo ule ule (ambao ni BOS ya kawaida, si
  // CHOCH).
  bool chochUp = false;
  bool chochDown = false;

  if (breaks.isNotEmpty &&
      (candles.length - 1 - breaks.last.index) <= 5) {
    final isRegimeChange = breaks.length < 2 ||
        breaks[breaks.length - 2].isUp != breaks.last.isUp;

    if (isRegimeChange) {
      chochUp = breaks.last.isUp;
      chochDown = !breaks.last.isUp;
    }
  }

  return StructureAnalysis(
    bosUp: bosUp,
    bosDown: bosDown,
    chochUp: chochUp,
    chochDown: chochDown,
    swingHigh: swingHigh,
    swingLow: swingLow,
    // ONGEZO JIPYA: swing points 5 za mwisho (bei tu) kwa Chart
    // Pattern detection (Double Top/Bottom, Head & Shoulders).
    recentSwingHighs: swingHighs
        .skip(max(0, swingHighs.length - 5))
        .map((s) => s.price)
        .toList(),
    recentSwingLows: swingLows
        .skip(max(0, swingLows.length - 5))
        .map((s) => s.price)
        .toList(),
  );
}
InstitutionalOrderBlock _detectInstitutionalOB(
    List<Candle> candles,
) {
  if (candles.length < 30) {
    return const InstitutionalOrderBlock(
      bullish: false,
      bearish: false,
      mitigated: false,
      strength: 0,
      high: 0,
      low: 0,
    );
  }

  final last = candles.last;

  // FIX / MABORESHO MAKUBWA #3 (hoja hiyo hiyo sahihi ya mtumiaji -
  // "Order Block pia ni HALI inayoendelea, si tukio la candle moja"):
  // awali dirisha lilikuwa fupi SANA (candles 8 za mwisho TU) na
  // algorithm ilisimama kwenye candle YA KWANZA ya chini/juu
  // iliyopatikana - bila kujali kama candle hiyo kwa KWELI ilikuwa
  // msingi (base) unaofaa/halali wa OB inayotumika SASA (jambo
  // lililoonekana kwenye logi - "OB Bullish:false" mara nyingi hata
  // wakati structure nyingine zilikuwa na nguvu). Sasa tunatafuta OB
  // ZINAZOFAA (msingi ambao bei ya SASA iko upande sahihi wake NA
  // haijamitigatiwa) kwenye dirisha refu zaidi (candles 100), tukichagua
  // ile ya KARIBUNI ZAIDI - hali inayodumu kwa candles nyingi
  // mfululizo (kama mchambuzi wa kweli angeiona kwenye chati), si
  // tukio la flash la candle moja.
  final lookback = min(100, candles.length - 3);
  final windowStart = candles.length - 1 - lookback;

  Candle? bullishBase;
  int bullishBaseIndex = -1;

  Candle? bearishBase;
  int bearishBaseIndex = -1;

  for (int i = candles.length - 2; i >= windowStart; i--) {
    final c = candles[i];

    // Kandidati ya bullish OB: down-candle ambayo bei ya SASA iko
    // JUU yake (tumeshaivunja/kuiacha nyuma kama msingi wa support),
    // NA haijamitigatiwa (hakuna candle yoyote tangu kuundwa kwake
    // iliyorudi ndani ya eneo lake).
    if (bullishBase == null &&
        c.close < c.open &&
        last.close > c.high) {
      bool mitigated = false;

      for (int m = i + 1; m < candles.length - 1; m++) {
        if (candles[m].low <= c.high) {
          mitigated = true;
          break;
        }
      }

      if (!mitigated) {
        bullishBase = c;
        bullishBaseIndex = i;
      }
    }

    // Kandidati ya bearish OB: up-candle ambayo bei ya SASA iko CHINI
    // yake, NA haijamitigatiwa.
    if (bearishBase == null &&
        c.close > c.open &&
        last.close < c.low) {
      bool mitigated = false;

      for (int m = i + 1; m < candles.length - 1; m++) {
        if (candles[m].high >= c.low) {
          mitigated = true;
          break;
        }
      }

      if (!mitigated) {
        bearishBase = c;
        bearishBaseIndex = i;
      }
    }

    if (bullishBase != null && bearishBase != null) break;
  }

  final bullish = bullishBase != null;
  final bearish = bearishBase != null;

  double strength = 0;

  if (bullish) {
    strength = (last.close - bullishBase!.high).abs();
  }

  if (bearish) {
    strength = max(strength, (bearishBase!.low - last.close).abs());
  }

  // FIX: kwa vile sasa tunathibitisha 'haijamitigatiwa' KABLA ya
  // kukubali base kama halali (angalia loop hapo juu - candidate
  // yoyote iliyomitigatiwa haikubaliwi kamwe), OB tuliyoipata hapa ni
  // KWA UFAFANUZI isiyomitigatiwa. 'mitigated' inabaki 'false' hapa -
  // si kwa sababu hatujakagua, bali kwa sababu tayari imekaguliwa na
  // KUPITISHWA kama sehemu ya utafutaji wenyewe. Field hii
  // imebakizwa kwa uwiano wa API (angalia matumizi ya
  // 'bullishOB = institutionalOB.bullish && !institutionalOB.mitigated').
  const mitigated = false;

  return InstitutionalOrderBlock(
    bullish: bullish,
    bearish: bearish,
    mitigated: mitigated,
    strength: strength,
    high: bullishBase?.high ??
        bearishBase?.high ??
        0,
    low: bullishBase?.low ??
        bearishBase?.low ??
        0,
    baseCandle: bullish
        ? bullishBase
        : (bearish ? bearishBase : null),
  );
}

// ================= FAIR VALUE GAP (ONGEZO JIPYA - halisi) =================
// FIX (data ya uongo iliyoondolewa): 'fairValueGaps' kwenye
// MarketAnalysisResult ilikuwa ikibaki tupu KILA WAKATI - FVG
// haikuwahi kuhesabiwa popote. Hii ni hesabu HALISI kwa kanuni ya
// kawaida ya SMC/ICT: FVG (pengo la thamani halisi) linatokea kati ya
// candles TATU mfululizo - candle ya 1 na candle ya 3 zikiwa na
// "pengo" ambalo candle ya 2 (ya kati) haikulijaza kabisa. Tunaangalia
// TU pengo ambazo BADO HAZIJAJAZWA (unfilled) - candle yoyote ya
// baadaye ikiingia ndani ya pengo hilo, linahesabiwa "limejazwa" na
// halijumuishwi tena.
//
// Aina ya matokeo (List<Map<String,double>>) imethibitishwa kutoka
// models/market_analysis_result.dart - kwa vile Map lazima iwe na
// thamani za 'double' TU, mwelekeo unaonyeshwa kama namba (1.0 =
// bullish, -1.0 = bearish) badala ya String.
List<Map<String, double>> _detectFairValueGaps(List<Candle> candles) {
  if (candles.length < 10) return const [];

  final gaps = <Map<String, double>>[];
  final lookback = min(50, candles.length - 2);
  final windowStart = max(2, candles.length - lookback);

  for (int i = windowStart; i < candles.length; i++) {
    final left = candles[i - 2];
    final right = candles[i];

    // Bullish FVG: low ya candle ya tatu iko JUU ya high ya candle ya
    // kwanza - pengo halisi la kuruka juu bila biashara ndani yake.
    if (right.low > left.high) {
      final gapHigh = right.low;
      final gapLow = left.high;

      bool filled = false;
      for (int j = i + 1; j < candles.length; j++) {
        if (candles[j].low <= gapLow) {
          filled = true;
          break;
        }
      }

      if (!filled) {
        gaps.add({
          "high": gapHigh,
          "low": gapLow,
          "direction": 1.0,
        });
      }
    }

    // Bearish FVG: high ya candle ya tatu iko CHINI ya low ya candle
    // ya kwanza.
    if (right.high < left.low) {
      final gapHigh = left.low;
      final gapLow = right.high;

      bool filled = false;
      for (int j = i + 1; j < candles.length; j++) {
        if (candles[j].high >= gapHigh) {
          filled = true;
          break;
        }
      }

      if (!filled) {
        gaps.add({
          "high": gapHigh,
          "low": gapLow,
          "direction": -1.0,
        });
      }
    }
  }

  return gaps;
}

// ================= TRADING SESSION (ONGEZO JIPYA) =================
// FIX: 'MarketSession' enum ilikuwa 'dead code' tangu mwanzo (imebakizwa
// kwa usalama wa API - angalia maelezo kwenye tamko lake). Sasa
// FINALLY ina matumizi halisi - kubaini session ya soko ya SASA kwa
// saa za UTC (makadirio ya kawaida ya sekta - si sahihi 100% kwa
// tofauti za DST za baadhi ya masoko).
MarketSession _currentSession() {
  final hour = DateTime.now().toUtc().hour;

  final inSydney = hour >= 21 || hour < 6;
  final inTokyo = hour >= 23 || hour < 8;
  final inLondon = hour >= 7 && hour < 16;
  final inNewYork = hour >= 12 && hour < 21;

  if (inLondon || inNewYork) {
    return inLondon ? MarketSession.london : MarketSession.newYork;
  }
  if (inTokyo) return MarketSession.asia;
  if (inSydney) return MarketSession.sydney;

  return MarketSession.unknown;
}

PriceActionAnalysis _detectPriceAction(
  List<Candle> candles,
) {
  if (candles.length < 3) {
    return const PriceActionAnalysis(
      bullishEngulfing: false,
      bearishEngulfing: false,
      bullishPinBar: false,
      bearishPinBar: false,
      insideBar: false,
      doji: false,
      bullishRejection: false,
      bearishRejection: false,
    );
  }

  final last = candles.last;
  final prev = candles[candles.length - 2];

  final body = (last.close - last.open).abs();
  final upper =
      last.high - max(last.close, last.open);
  final lower =
      min(last.close, last.open) - last.low;

  final bullishEngulf =
      prev.close < prev.open &&
      last.close > last.open &&
      last.open <= prev.close &&
      last.close >= prev.open;

  final bearishEngulf =
      prev.close > prev.open &&
      last.close < last.open &&
      last.open >= prev.close &&
      last.close <= prev.open;

  final bullishPin =
      lower > body * 2 &&
      upper < body;

  final bearishPin =
      upper > body * 2 &&
      lower < body;

  final inside =
      last.high < prev.high &&
      last.low > prev.low;

  final doji =
      body <=
      (last.high - last.low) * 0.10;

  final bullishReject =
      lower >
      (upper + body);

  final bearishReject =
      upper >
      (lower + body);

  // ================= ONGEZO JIPYA: PATTERNS KUTOKA "THE CANDLESTICK
  // TRADING BIBLE" =================

  final dragonflyDoji =
      doji &&
      upper <= body * 0.5 &&
      lower > (last.high - last.low) * 0.6;

  final gravestoneDoji =
      doji &&
      lower <= body * 0.5 &&
      upper > (last.high - last.low) * 0.6;

  bool morningStar = false;
  bool eveningStar = false;

  if (candles.length >= 3) {
    final c1 = candles[candles.length - 3];
    final c2 = candles[candles.length - 2];
    final c3 = candles[candles.length - 1];

    final c1Body = (c1.close - c1.open).abs();
    final c2Body = (c2.close - c2.open).abs();
    final c1Midpoint = (c1.open + c1.close) / 2;

    final c1Bearish = c1.close < c1.open;
    final c2Small = c1Body > 0 && c2Body < c1Body * 0.5;
    final c3Bullish = c3.close > c3.open;

    morningStar =
        c1Bearish &&
        c2Small &&
        c3Bullish &&
        c3.close > c1Midpoint;

    final c1Bullish = c1.close > c1.open;
    final c3Bearish = c3.close < c3.open;

    eveningStar =
        c1Bullish &&
        c2Small &&
        c3Bearish &&
        c3.close < c1Midpoint;
  }

  bool tweezersTop = false;
  bool tweezersBottom = false;

  if (candles.length >= 2) {
    final rangeTolerance = (last.high - last.low) * 0.1;

    final prevBullish = prev.close > prev.open;
    final prevBearish = prev.close < prev.open;
    final lastBullish = last.close > last.open;
    final lastBearish = last.close < last.open;

    final highsMatch = (last.high - prev.high).abs() <= rangeTolerance;
    final lowsMatch = (last.low - prev.low).abs() <= rangeTolerance;

    tweezersTop = prevBullish && lastBearish && highsMatch;
    tweezersBottom = prevBearish && lastBullish && lowsMatch;
  }

  return PriceActionAnalysis(
    bullishEngulfing: bullishEngulf,
    bearishEngulfing: bearishEngulf,
    bullishPinBar: bullishPin,
    bearishPinBar: bearishPin,
    insideBar: inside,
    doji: doji,
    bullishRejection: bullishReject,
    bearishRejection: bearishReject,
    dragonflyDoji: dragonflyDoji,
    gravestoneDoji: gravestoneDoji,
    morningStar: morningStar,
    eveningStar: eveningStar,
    tweezersTop: tweezersTop,
    tweezersBottom: tweezersBottom,
  );
}

ConfluenceAnalysis _buildConfluence({
  required MarketBias w1,
  required MarketBias d1,
  required H4Analysis h4,
  required PriceActionAnalysis pa,
  required bool emaBullish,
  required bool emaBearish,
  required bool rsiBullish,
  required bool rsiBearish,
}) {
  // FIX (bug halisi ya mantiki): angalia maelezo marefu kwenye class
  // ConfluenceAnalysis hapo juu. Kila chanzo sasa kinahesabiwa KATIKA
  // upande wake sahihi TU (buy au sell), si kwa uwepo tu bila
  // kujali mwelekeo. Vyanzo 6 sasa vinawezekana (viliongezwa EMA na
  // RSI - ambavyo hapo awali havikuwahi kutumika kwenye confluence
  // kabisa licha ya kudaiwa 'valid').
  int buyConfirmations = 0;
  int sellConfirmations = 0;

  if (w1 == MarketBias.buy && d1 == MarketBias.buy) {
    buyConfirmations++;
  }
  if (w1 == MarketBias.sell && d1 == MarketBias.sell) {
    sellConfirmations++;
  }

  if (h4.bullish) {
    buyConfirmations++;
  }
  if (h4.bearish) {
    sellConfirmations++;
  }

  if (pa.bullishEngulfing) {
    buyConfirmations++;
  }
  if (pa.bearishEngulfing) {
    sellConfirmations++;
  }

  if (pa.bullishPinBar) {
    buyConfirmations++;
  }
  if (pa.bearishPinBar) {
    sellConfirmations++;
  }

  if (emaBullish) {
    buyConfirmations++;
  }
  if (emaBearish) {
    sellConfirmations++;
  }

  if (rsiBullish) {
    buyConfirmations++;
  }
  if (rsiBearish) {
    sellConfirmations++;
  }

  // Kizingiti kimebaki 3 (sawa na awali) - lakini sasa ni 3 KATIKA
  // UPANDE MMOJA, si mchanganyiko wa ishara zinazopingana.
  final buyAligned = buyConfirmations >= 3;
  final sellAligned = sellConfirmations >= 3;

  final strongerConfirmations = max(buyConfirmations, sellConfirmations);

  return ConfluenceAnalysis(
    aligned: buyAligned || sellAligned,
    confirmations: strongerConfirmations,
    // Vyanzo 6 sasa vinawezekana (vilikuwa 4) - mgawanyo umesasishwa.
    score: strongerConfirmations / 6,
    buyConfirmations: buyConfirmations,
    sellConfirmations: sellConfirmations,
    buyAligned: buyAligned,
    sellAligned: sellAligned,
  );
}

ConfidenceResult _calculateConfidence(
    WeightedScore score,
) {

  double confidence = 0;

  // FIX / MABORESHO: uzito ulisambazwa upya kutoa nafasi kwa EMA na
  // RSI (ambazo sasa zinahesabiwa kikamilifu - angalia
  // _calculateEMA/_calculateRSI) badala ya kubaki kama vigezo vya
  // uongo visivyotumika. Jumla bado ni 100%:
  //   Trend 25 + Structure 20 + Liquidity 10 + OrderBlock 10 +
  //   PriceAction 10 + Momentum 10 + EMA 10 + RSI 5 = 100

  // TREND 25%
  if (score.trend > 0) {
    confidence += 25;
  }


  // STRUCTURE 20% (ilikuwa 25%)
  if (score.structure > 0) {
    confidence += 20;
  }


  // LIQUIDITY 10% (ilikuwa 15%)
  if (score.liquidity > 0) {
    confidence += 10;
  }


  // ORDER BLOCK 10% (ilikuwa 15%)
  if (score.orderBlock > 0) {
    confidence += 10;
  }


  // PRICE ACTION 10%
  if (score.priceAction > 0) {
    confidence += 10;
  }


  // MOMENTUM 10%
  if (score.momentum > 0) {
    confidence += 10;
  }

  // EMA 10% (ONGEZO JIPYA - halisi)
  if (score.ema > 0) {
    confidence += 10;
  }

  // RSI 5% (ONGEZO JIPYA - halisi)
  if (score.rsi > 0) {
    confidence += 5;
  }


bool strong =
     confidence >= 75;


  bool valid =
      confidence >= 60;


  String quality;


  if(confidence >= 85){

    quality = "VERY_STRONG";

  }
  else if(confidence >= 75){

    quality = "STRONG";

  }
  else if(confidence >= 60){

    quality = "GOOD";

  }
  else{

    quality = "WEAK";

  }


 return ConfidenceResult(

    confidence: confidence,

    strong: strong,

    valid: valid,

    quality: quality,

);

}
DecisionAnalysis _makeDecision({

required double buy,

required double sell,

required ConfidenceResult confidence,

required H4Analysis h4,

required ConfluenceAnalysis confluence,

// RSI overbought/oversold veto - filta ya kanuni ya kawaida ya
// uchambuzi wa kiufundi - kuingia mwelekeoni ambao tayari "umechoka"
// kihistoria ni hatari zaidi KATIKA SOKO LINALOZUNGUKA (ranging).
required bool rsiOverbought,

required bool rsiOversold,

// 🚨🚨🚨 ONGEZO JIPYA (hoja C - kwa ombi la mtumiaji, baada ya
// uchambuzi wa nje kuthibitisha tatizo halisi): AWALI, Trend+Structure
// PEKEE (kabla ya hoja A: pointi 65/100) vingeweza kusukuma uamuzi
// KABISA bila uthibitisho wowote wa "smart money" (liquidity
// sweep/order block). Hii ilifanya mfumo kuwa "trend continuation
// detector" - Trend Bias (W1/D1) na Entry Signal (wakati HALISI wa
// kuingia) hazikuwa zimetenganishwa. SASA: Trend Bias ni MUKTADHA TU
// (lazima uwepo - filter), LAKINI Entry HAIRUHUSIWI ('allowed=true')
// isipokuwa KUNA uthibitisho MOJA ANGALAU wa "smart money" (Liquidity
// sweep AU Order Block) - hizi ndizo ishara za MAHALI PENYE thamani
// (location-aware), si tu MWELEKEO (direction-only) kama Trend
// pekee.
required double buyLiquidity,

required double buyOrderBlock,

required double sellLiquidity,

required double sellOrderBlock,

required bool noTradeZoneBuy,

required bool noTradeZoneSell,

// ONGEZO JIPYA (hoja D - kwa ombi la mtumiaji): "Market Regime
// Filter" - kama 'true' (soko linazunguka/ranging), softening ya
// RSI veto (buyStrongTrendOverride/sellStrongTrendOverride)
// INAZIMWA - override hiyo ni hatari kwenye ranging market.
required bool isRanging,

// ONGEZO JIPYA (kutoka video - "Internal vs External BOS/CHOCH"):
// Internal (H1) structure - njia ya ziada ya uthibitisho wa "smart
// money"/entry timing, kando na Liquidity/OrderBlock (H4).
required bool internalBosUp,

required bool internalBosDown,

}) {

// ONGEZO JIPYA (hoja C): uthibitisho wa "smart money" - angalau
// MOJA kati ya Liquidity sweep au Order Block lazima iwepo kwa
// upande husika, vinginevyo Trend/Structure PEKEE hazitoshi kufungua
// trade - "tafuta BUY setup" (kusubiri location nzuri), si "BUY NOW"
// kiotomatiki mara W1/D1 ikiwa bullish.
// ONGEZO JIPYA (kutoka video - "Internal vs External BOS"): Internal
// (H1) BOS inayoendana na upande husika NAYO inahesabiwa kama
// uthibitisho halali wa "smart money"/entry timing - si Liquidity/OB
// (H4) pekee tena. Hii inaruhusu ENTRY sahihi zaidi hata kwenye
// hali ambapo H4 haina liquidity sweep/OB wazi lakini H1 (internal)
// inaonyesha structure inayoendana na mwelekeo (pullback imeisha,
// trend inaendelea).
final buySmartMoneyConfirmed =
    buyLiquidity > 0 || buyOrderBlock > 0 || internalBosUp;
final sellSmartMoneyConfirmed =
    sellLiquidity > 0 || sellOrderBlock > 0 || internalBosDown;


// FIX: awali hapa palikuwa na ukaguzi wa 'confluence.aligned' (ONE
// generic boolean isiyojali mwelekeo - angalia maelezo kwenye
// ConfluenceAnalysis/_buildConfluence). Sasa BUY inahitaji
// 'confluence.buyAligned' na SELL inahitaji 'confluence.sellAligned'
// - kila upande unathibitishwa na ishara za upande huo TU.

// ONGEZO JIPYA / MABORESHO (kanuni thabiti ya uchambuzi wa kiufundi,
// SI kubahatisha): tuligundua kwenye logi halisi kwamba setup NZURI
// ZAIDI za mfumo (Confirmations 4/6, Confidence 80% STRONG) mara
// nyingi zilikuwa zikizuiwa na veto ya RSI - kwa sababu MWELEKEO
// MKALI unaosababisha Structure+Trend+Momentum kukubaliana kwa
// pamoja ndio huo huo unaosukuma RSI kufika ncha (70+/30-).
//
// Hii ni ukweli ULIOTHIBITIKA wa uchambuzi wa kiufundi: kwenye TREND
// IMARA ya kweli, RSI HUBAKI overbought/oversold kwa muda MREFU bila
// kubadilika - hii SI ishara ya "soko limechoka", ni ishara ya
// NGUVU ya trend. Veto ya RSI 70/30 ina maana ZAIDI kwenye soko
// linalozunguka (ranging), si kwenye trend yenye uthibitisho mkubwa.
//
// Sasa: veto ya RSI INALEGEZWA (si kuondolewa kabisa) PEKEE pale
// confluence ikiwa na uthibitisho mkubwa (>=4 kati ya vyanzo 6
// vinavyowezekana - Trend, H4, Engulfing, PinBar, EMA, RSI) - kiwango
// hiki kinaonyesha trend ya kweli, si tu momentum ya muda mfupi.
// Kwenye hali dhaifu zaidi (confirmations 3), veto inabaki kali kama
// awali - kwa sababu hapo hatuna uthibitisho wa kutosha kujua kama ni
// trend ya kweli au ni "overextension" hatari.
final buyStrongTrendOverride = confluence.buyConfirmations >= 4 && !isRanging;
final sellStrongTrendOverride = confluence.sellConfirmations >= 4 && !isRanging;

if(!confidence.valid){

return const DecisionAnalysis(

decision:
TradeDecision.wait,

allowed:false,

);

}


if(
buy > sell &&
h4.bullish &&
confluence.buyAligned &&
buySmartMoneyConfirmed &&
!noTradeZoneBuy &&
(!rsiOverbought || buyStrongTrendOverride)
){


if(
confidence.strong
){

return const DecisionAnalysis(

decision:
TradeDecision.strongBuy,

allowed:true,

);

}


return const DecisionAnalysis(

decision:
TradeDecision.buy,

allowed:true,

);

}



if(
sell > buy &&
h4.bearish &&
confluence.sellAligned &&
sellSmartMoneyConfirmed &&
!noTradeZoneSell &&
(!rsiOversold || sellStrongTrendOverride)
){


if(
confidence.strong
){

return const DecisionAnalysis(

decision:
TradeDecision.strongSell,

allowed:true,

);

}


return const DecisionAnalysis(

decision:
TradeDecision.sell,

allowed:true,

);

}



return const DecisionAnalysis(

decision:
TradeDecision.wait,

allowed:false,

);

}
// ================= H4 ANALYSIS ENGINE =================


H4Analysis _analyzeH4(
    List<Candle> candles
){

if(candles.length < 20){

return H4Analysis(

bosUp:false,
bosDown:false,

chochUp:false,
chochDown:false,

sweepHigh:false,
sweepLow:false,

bullishOB:false,
bearishOB:false,

momentumUp:false,
momentumDown:false,

equalHighs:false,
equalLows:false,
mitigated:false,

structureSwingHigh:0,
structureSwingLow:0,
obHigh:0,
obLow:0,

buyScore:0,
sellScore:0,

);

}



final last =
candles.last;


final liquidity =
    _detectLiquidity(candles);

final structure =
    _detectStructure(candles);

final institutionalOB =
    _detectInstitutionalOB(candles);


_log(
    "EQ HIGHS:${liquidity.equalHighs}");

_log(
    "EQ LOWS:${liquidity.equalLows}");

_log(
    "LIQ HIGH:${liquidity.highest}");

_log(
    "LIQ LOW:${liquidity.lowest}");

// ================= SWING (MOMENTUM - dirisha fupi) =================
// FIX (dead code iliyounganishwa): 'high'/'low' hapa chini zilikuwa
// zikihesabiwa (dirisha fupi la candles 10, tofauti na dirisha la
// candles 20 la _detectStructure) lakini HAZIKUWAHI KUTUMIKA popote -
// zilihesabiwa bure kila mzunguko bila kuathiri uamuzi wowote. Sasa
// zinatumika kama ishara HALISI ya ziada ("H4 momentum breakout") -
// bei ikivunja juu/chini ya swing ya karibuni zaidi (candles 10, ~siku
// 1.7) inaonyesha kasi ya muda mfupi inayounga mkono BOS ya muda
// mrefu zaidi (candles 20).


double high =
0;

double low =
double.infinity;


for(
int i=candles.length-10;
i<candles.length-1;
i++
){

if(candles[i].high > high){

high =
candles[i].high;

}


if(candles[i].low < low){

low =
candles[i].low;

}

}

final momentumUp = last.close > high;
final momentumDown = last.close < low;

_log("H4 MOMENTUM UP (10-candle breakout) : $momentumUp");
_log("H4 MOMENTUM DOWN (10-candle breakout) : $momentumDown");


// ================= CHOCH =================


final bosUp = structure.bosUp;

final bosDown = structure.bosDown;

final chochUp = structure.chochUp;

final chochDown = structure.chochDown;

// ================= LIQUIDITY =================


final sweepHigh =
    liquidity.sweepHigh;

final sweepLow =
    liquidity.sweepLow;

_log(
    "SWING HIGH:${structure.swingHigh}");

_log(
    "SWING LOW:${structure.swingLow}");

_log(
    "BOS UP:$bosUp");

_log(
    "BOS DOWN:$bosDown");

_log(
    "CHOCH UP:$chochUp");

_log(
    "CHOCH DOWN:$chochDown");


// ================= ORDER BLOCK =================


final bullishOB =
    institutionalOB.bullish &&
    !institutionalOB.mitigated;

final bearishOB =
    institutionalOB.bearish &&
    !institutionalOB.mitigated;



double buy=0;

double sell=0;


if (bosUp) {
  buy += 30;
}


if (bosDown) {
  sell += 30;
}


if (chochUp) {
  buy += 20;
}


if (chochDown) {
  sell += 20;
}

if (sweepLow) {
  buy += 25;
}


if (sweepHigh) {
  sell += 25;
}

if (bullishOB) {
  buy += min(
    35,
    20 + institutionalOB.strength,
  );
}


if (bearishOB) {
  sell += min(
    35,
    20 + institutionalOB.strength,
  );
}

// ONGEZO JIPYA: ishara ya H4 momentum (dirisha fupi la candles 10) -
// angalia maelezo kwenye eneo la "SWING (MOMENTUM)" hapo juu na
// kwenye H4Analysis.bullish/bearish kuhusu kwa nini hii iliongezwa.
if (momentumUp) {
  buy += 20;
}

if (momentumDown) {
  sell += 20;
}

_log(
    "OB Bullish:$bullishOB");

_log(
    "OB Bearish:$bearishOB");

_log(
    "OB Strength:${institutionalOB.strength}");

_log(
    "OB Mitigated:${institutionalOB.mitigated}");


return H4Analysis(

bosUp:bosUp,

bosDown:bosDown,

chochUp:chochUp,

chochDown:chochDown,

sweepHigh:sweepHigh,

sweepLow:sweepLow,

bullishOB:bullishOB,

bearishOB:bearishOB,

momentumUp:momentumUp,

momentumDown:momentumDown,

// FIX (kuondoa "pambo"): angalia maelezo marefu kwenye tamko la
// fields hizi ndani ya class H4Analysis - hapo awali data hii
// ilihesabiwa lakini ikapotea kimya kimya, isipofika kwenye matokeo
// ya mwisho. Kizingiti cha ">=2" kwa equalHighs/equalLows kinaendana
// na kile kinachotumika tayari kwenye _detectLiquidity() kuamua
// 'sweepHigh'/'sweepLow' (angalia hapo juu) - uthabiti wa kimantiki.
equalHighs: liquidity.equalHighs >= 2,

equalLows: liquidity.equalLows >= 2,

mitigated: institutionalOB.mitigated,

structureSwingHigh: structure.swingHigh,

structureSwingLow: structure.swingLow,

obHigh: institutionalOB.high,

obLow: institutionalOB.low,

obBaseCandle: institutionalOB.baseCandle,

buyScore:buy,

sellScore:sell,

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

  // ================= EMA (ONGEZO JIPYA - halisi) =================
  // FIX (data ya uongo iliyoondolewa): awali MarketAnalysisResult
  // ilikuwa ikirudisha 'ema50: const []' na 'ema200: const []' KILA
  // WAKATI - orodha tupu - huku ikidai 'emaValid: true'. Hakuna EMA
  // iliyowahi kuhesabiwa mahali popote kwenye faili nzima. Sasa hii
  // ni hesabu HALISI ya Exponential Moving Average kutoka bei za
  // kufunga (close) za H1, kwa fomula ya kawaida:
  //   EMA[0] = SMA ya candles 'period' za kwanza (seed)
  //   EMA[i] = (close[i] - EMA[i-1]) * multiplier + EMA[i-1]
  //   multiplier = 2 / (period + 1)
  // Orodha inayorudishwa ina urefu wa (candles.length - period + 1) -
  // yaani thamani halisi TU, bila kujaza namba za uongo mahali
  // ambapo EMA haijafikika bado.
  List<double> _calculateEMA(List<Candle> candles, int period) {
    if (candles.length < period || period <= 0) return const [];

    final closes = candles.map((c) => c.close).toList();
    final multiplier = 2 / (period + 1);

    double emaPrev =
        closes.sublist(0, period).reduce((a, b) => a + b) / period;

    final result = <double>[emaPrev];

    for (int i = period; i < closes.length; i++) {
      final emaCurrent = (closes[i] - emaPrev) * multiplier + emaPrev;
      result.add(emaCurrent);
      emaPrev = emaCurrent;
    }

    return result;
  }

  // ================= RSI (ONGEZO JIPYA - halisi) =================
  // FIX (data ya uongo iliyoondolewa): kama EMA - 'rsiValid: true'
  // ilikuwa ikidaiwa bila RSI kuwahi kuhesabiwa. Hii ni hesabu ya RSI
  // (Relative Strength Index) ya kipindi 'period' (kawaida 14),
  // ikitumia wastani rahisi wa gain/loss (SMA-based, si Wilder's
  // exponential smoothing kamili tangu mwanzo wa historia - toleo hili
  // ni sahihi vya kutosha kwa uamuzi wa sasa lakini si sawa 100% na
  // baadhi ya majukwaa yanayotumia Wilder smoothing tangu candle ya
  // kwanza kabisa). Inarudisha thamani MOJA - RSI ya sasa (0-100).
  double _calculateRSI(List<Candle> candles, {int period = 14}) {
    if (candles.length < period + 1) {
      // Data haitoshi - 50 (neutral) inatumika kama alama isiyo na
      // upendeleo, TU baada ya caller kuangalia 'rsiValid' kwanza.
      return 50;
    }

    double gainSum = 0;
    double lossSum = 0;

    for (int i = candles.length - period; i < candles.length; i++) {
      final change = candles[i].close - candles[i - 1].close;
      if (change > 0) {
        gainSum += change;
      } else {
        lossSum += -change;
      }
    }

    final avgGain = gainSum / period;
    final avgLoss = lossSum / period;

    if (avgLoss == 0) return 100;

    final rs = avgGain / avgLoss;
    return 100 - (100 / (1 + rs));
  }

  // FIX (bug halisi yenye athari kubwa): '_latest' inahifadhiwa KILA
  // WAKATI kwa jina la alama LILILOSAWAZISHWA (UPPERCASE, angalia
  // _normalize() na jinsi '_latest[symbol]=result' inavyowekwa ndani
  // ya _run()/_processQueue()). Kabla ya fix hii, 'latestFor(pair)'
  // ilikuwa ikitafuta MOJA KWA MOJA bila kusawazisha 'pair' kwanza -
  // caller yeyote (mf. signals_server.dart) aliyepitisha jina la alama
  // lisilo UPPERCASE (kama vile "frxEURUSD" badala ya "FRXEURUSD")
  // angepata 'null' KIMYA KIMYA hata kama data ipo kabisa - jambo
  // linalofanya vipengele kama snapshot za awali (`_sendSnapshot`)
  // kuruka alama bila taarifa yoyote ya hitilafu.
  MarketAnalysisResult? latestFor(String pair) => _latest[_normalize(pair)];

  // =====================================================================
  // ================= BACKTEST HALISI (ONGEZO JIPYA) ===================
  // =====================================================================
  //
  // MADHUMUNI: kupima mkakati (mantiki ile ile ya _analyze() inayotumika
  // LIVE - si nakala tofauti) dhidi ya miaka ya data HALISI kutoka Deriv,
  // ili kupata win rate/profit factor/drawdown HALISI kabla ya kuweka
  // pesa halisi - kama tulivyokubaliana awali.
  //
  // KANUNI ZA UAMINIFU zilizotumika hapa (soma kwa makini - hizi ndizo
  // zinazotofautisha "backtest halisi" na "backtest ya kujidanganya"):
  //
  //  1) HAKUNA LOOKAHEAD BIAS: kila hatua ya wakati (kila H1 candle)
  //     inaona TU candles zilizofungwa (closed) HADI wakati huo - kamwe
  //     candle za baadaye. W1/D1/H4 zinapunguzwa (truncate) kila hatua
  //     kuendana na saa ya H1 inayochambuliwa.
  //  2) MANTIKI MOJA: _analyze() ile ile inayotumika LIVE ndiyo
  //     inayoitwa hapa - hakuna "backtest logic" tofauti na "live
  //     logic" ambayo mara nyingi husababisha matokeo ya uongo
  //     (backtest inayoonekana nzuri lakini live haifanani nayo).
  //  3) USAHIHI WA SL/TP: badala ya kuangalia H1 pekee (ambapo SL na TP
  //     zote zinaweza kuwa ndani ya candle moja - "haujui ni ipi
  //     iliyoguswa kwanza"), tunatumia M15 (dakika 15) kutafuta ni ipi
  //     kati ya SL/TP iliyofikiwa KWANZA. Kama zote mbili zinagusika
  //     ndani ya M15 candle MOJA, tunachukua SL kama ilivyofikiwa
  //     kwanza (dhana ya KIHAFIDHINA - "conservative assumption") ili
  //     kutolea matokeo bora zaidi kuliko ukweli.
  //  4) GHARAMA HALISI: spread na commission zinatolewa kwenye kila
  //     trade (win au lose) - bila hizi, backtest nyingi "zinaonekana
  //     kufanya kazi" kwenye karatasi lakini zinapoteza pesa halisi kwa
  //     sababu ya gharama za muamala pekee.
  //  5) POSITION SIZING YA HATARI (risk-based): badala ya lot size
  //     fixed (kama LIVE _analyze() inavyofanya kwa sasa - 0.1 kwa
  //     alama zote), hapa lot size inahesabiwa kulingana na asilimia
  //     ya balance unayotaka kuhatarisha kwa kila trade na umbali wa
  //     stop loss - hii ndiyo njia sahihi ya kupima utendaji wa akaunti
  //     halisi (equity curve halisi, siyo bahati nasibu ya lot fixed).
  //  6) TRADE MOJA KWA WAKATI: kama tayari kuna trade wazi kwenye alama
  //     hii, signal mpya HAZIFUNGULIWI hadi ile ya kwanza ifunge - hii
  //     inalingana na jinsi injini ya LIVE inavyofanya kazi (haifungui
  //     mbili juu ya ile ile bila kufunga ya kwanza).
  //  7) ONYO LA SAMPULI NDOGO: BacktestResult.summary() inatoa onyo la
  //     wazi kama trades ni chache mno (<30) kuaminika kitakwimu.
  //
  // KIZUIZI KILICHOBAKI (uwazi, si udanganyifu): 'pointValuePerLot'
  // inachukulia uhusiano wa moja kwa moja (linear) kati ya mabadiliko
  // ya bei na faida/hasara ya fedha - hii ni sahihi kwa alama nyingi za
  // synthetic za Deriv, lakini SI sahihi kikamilifu kwa jozi za fedha
  // za forex (ambazo thamani ya pip inategemea lot size na currency
  // pair). Kama unataka usahihi wa 100% kwa FX, tunahitaji jedwali la
  // pip-value kwa kila jozi - nitaongeza hilo ukiliomba.
  Future<BacktestResult> runBacktest({
    required String symbol,
    required DateTime start,
    required DateTime end,
    double startingBalance = 1000,
    double riskPercentPerTrade = 1.0,
    double spreadCost = 0,
    double commissionPerLot = 0,
    double pointValuePerLot = 1.0,
    double? fixedLotSize, // ukiweka hii, risk-based sizing inapuuzwa
    // ONGEZO JIPYA: ukomo wa busara wa 'lots' - kinga dhidi ya "lots
    // explosion" (angalia maelezo marefu chini kwenye eneo la
    // kufungua trade) inayotokea pale 'pointValuePerLot' haiendani na
    // bei ghafi ya alama husika (mf. forex). 100 ni ukomo wa
    // kawaida/mkubwa wa kutosha kwa akaunti nyingi za retail -
    // ongeza tu kama unajua kwa uhakika alama zako zinahitaji zaidi.
    double maxLots = 100,
    int lookbackDays = 400,
    bool verbose = false,
  }) async {
    final deriv = DerivService.instance;
    final wasDebug = debugMode;

    // Zima logs za kina za _analyze() wakati wa backtest (maelfu ya
    // hatua) - vinginevyo console inajaa na backtest inapungua kasi
    // sana. 'verbose:true' ikiruhusu kuwasha tena kwa uchunguzi.
    debugMode = verbose;

    try {
      // FIX (bug ile ile ya casing - angalia maelezo marefu kwenye
      // startPairs()/subscribeCandles()): 'pair' (UPPERCASE) inabaki
      // kwa MATUMIZI YA NDANI TU (jina la matokeo, _analyze(), print
      // messages) - kwa maombi HALISI kwa Deriv (fetchHistoricalRange)
      // tunatumia 'symbol' (parameter halisi kama ilivyotolewa na
      // caller, bila kubadilishwa) ili FRX/CRY/STPRNG (herufi
      // mchanganyiko kiasili) zisitumwe kwa jina lisilo sahihi.
      final pair = deriv.normalizeSymbol(symbol);

      final bufferedStart = start.subtract(Duration(days: lookbackDays));

      // Historia ndefu HALISI (pagination kamili) - kila TF inatoka
      // Deriv MOJA KWA MOJA kwa granularity yake (hakuna 'conversion').
      final d1Hist = await deriv.fetchHistoricalRange(
        symbol,
        TF.d1,
        start: bufferedStart,
        end: end,
      );

      final h4Hist = await deriv.fetchHistoricalRange(
        symbol,
        TF.h4,
        start: bufferedStart,
        end: end,
      );

      final h1Hist = await deriv.fetchHistoricalRange(
        symbol,
        TF.h1,
        start: bufferedStart,
        end: end,
      );

      // M15 inahitajika TU kuanzia 'start' halisi (kwa ajili ya
      // kuiga (simulate) ni lini SL/TP inagusika baada ya trade
      // kufunguliwa) - si kabla, hivyo haihitaji lookback buffer.
      final m15Hist = await deriv.fetchHistoricalRange(
        symbol,
        TF.m15,
        start: start,
        end: end,
      );

      if (h1Hist.isEmpty || d1Hist.isEmpty || h4Hist.isEmpty) {
        // FIX: print moja kwa moja (si _log) - _log inafungwa na
        // 'debugMode' ambayo tumeizima kwa makusudi (verbose:false)
        // ili kuzuia mafuriko ya logs za kila hatua. Ujumbe huu wa
        // kushindwa lazima uonekane KILA WAKATI, hata verbose:false.
        print("❌ BACKTEST: data haitoshi kwa $pair kwenye kipindi hiki");
        return BacktestResult(
          symbol: pair,
          start: start,
          end: end,
          startingBalance: startingBalance,
          endingBalance: startingBalance,
          trades: const [],
          equityCurve: [startingBalance],
        );
      }

      final startEpoch = start.toUtc().millisecondsSinceEpoch ~/ 1000;
      final endEpoch = end.toUtc().millisecondsSinceEpoch ~/ 1000;

      // 🔍 ONGEZO JIPYA (diagnostic - kutafuta chanzo cha "trade 1 tu
      // kila wakati"): chapisha wazi ni data kiasi gani HALISI
      // ilipatikana ikilinganishwa na kile kilichoombwa - hii
      // itatuonyesha kama tatizo liko kwenye upatikanaji wa historia
      // (h1Hist haifiki mbali vya kutosha nyuma), au mahali pengine.
      final h1FirstDate =
          DateTime.fromMillisecondsSinceEpoch(h1Hist.first.epoch * 1000)
              .toUtc();
      final h1LastDate =
          DateTime.fromMillisecondsSinceEpoch(h1Hist.last.epoch * 1000)
              .toUtc();

      print(
        "🔍 DIAGNOSTIC $pair: h1Hist ina ${h1Hist.length} candles, "
        "kuanzia $h1FirstDate hadi $h1LastDate | "
        "Backtest inaomba: $start hadi $end (startEpoch=$startEpoch)",
      );

      if (h1Hist.first.epoch > startEpoch) {
        print(
          "⚠️ DIAGNOSTIC $pair: H1 data HAIFIKI nyuma hadi 'start' "
          "iliyoombwa! Data inaanzia $h1FirstDate lakini backtest "
          "inahitaji kuanzia $start - hii inaweza kupunguza sana "
          "muda halisi wa backtest.",
        );
      }

      double balance = startingBalance;
      final equityCurve = <double>[startingBalance];
      final trades = <BacktestTrade>[];

      int h4Ptr = 0;
      int d1Ptr = 0;
      int m15Ptr = 0;

      List<Candle> w1Slice = const [];
      int lastD1PtrForW1 = -1;

      // Trade iliyo wazi kwa sasa (moja tu kwa alama hii kwa wakati
      // mmoja - angalia kanuni #6 hapo juu).
      _OpenBacktestPosition? open;

      // 🔍 ONGEZO JIPYA (diagnostic): hesabu bars ngapi HASA
      // zilikidhi masharti ya kutafuta signal (bar.epoch>=startEpoch
      // NA h1/h4/d1/w1 zote za kutosha) - hii inaonyesha "dirisha
      // halisi la fursa" bila kujali kama signal ilitokea au la.
      int eligibleBars = 0;
      int signalsFound = 0;

      for (int i = 0; i < h1Hist.length; i++) {
        final bar = h1Hist[i];

        if (bar.epoch > endEpoch) break;

        // Sogeza pointers za H4/D1 mbele - candles ZILIZOFUNGWA TU
        // (epoch <= wakati wa H1 ya sasa) ndizo zinazoonekana.
        while (h4Ptr < h4Hist.length && h4Hist[h4Ptr].epoch <= bar.epoch) {
          h4Ptr++;
        }
        while (d1Ptr < d1Hist.length && d1Hist[d1Ptr].epoch <= bar.epoch) {
          d1Ptr++;
        }

        // Dirisha lililozuiwa (bounded window) kuepuka gharama kubwa ya
        // O(n^2) kwenye historia ndefu, huku likibaki na data ya
        // kutosha kwa ajili ya masharti yote ya ndani (>=120/50/50/20).
        final h1Slice = h1Hist.sublist(max(0, i + 1 - 300), i + 1);
        final h4Slice = h4Hist.sublist(max(0, h4Ptr - 200), h4Ptr);
        final d1Slice = d1Hist.sublist(max(0, d1Ptr - 400), d1Ptr);

        // Jenga W1 upya TU pale D1 mpya imeongezeka (mara moja kwa
        // siku), si kila H1 candle - hii inapunguza gharama ya
        // computation kwa kiasi kikubwa bila kuathiri usahihi.
        if (d1Ptr != lastD1PtrForW1) {
          w1Slice = deriv.buildWeekly(d1Slice);
          lastD1PtrForW1 = d1Ptr;
        }

        // ---------- KUFUNGA TRADE ILIYO WAZI (kama ipo) ----------
        if (open != null) {
          // FIX (bug ya compile - null-safety promotion): Dart
          // haiwezi ku-promote 'open' kuwa isiyo-null ndani ya 'while'
          // loop kwa sababu 'open' inarekebishwa (open = null;) mahali
          // pengine ndani ya mwili wa loop hiyo hiyo - uchambuzi wa
          // Dart wa 'flow analysis' hauamini tena kuwa haitakuwa null
          // kwenye kila kuzunguka (iteration) inayowezekana. Suluhisho:
          // kamata thamani isiyo-null KWENYE variable mpya 'pos' mara
          // moja tu, kisha tumia 'pos' (si 'open') humu ndani.
          final pos = open;

          while (m15Ptr < m15Hist.length &&
              m15Hist[m15Ptr].epoch <= pos.entryEpoch) {
            m15Ptr++;
          }

          // 🚨 FIX (BUG HATARI SANA - LOOKAHEAD BIAS): awali scan hii
          // ilikuwa ikiangalia M15 candles KUANZIA m15Ptr HADI
          // 'endEpoch' (MWISHO WA BACKTEST NZIMA - miaka 2 mbeleni!) -
          // kwenye JARIBIO MOJA, bila kujali H1 bar ('bar', 'i')
          // tunayoichambua HASA SASA kwenye mzunguko wa nje. Hii ni
          // LOOKAHEAD BIAS halisi: kwenye wakati wa H1 bar #500 (mf.
          // mwaka 1 wa data), simulation ilikuwa na UWEZO WA KUONA
          // M15 candles za MWAKA 2 - jambo lisilowezekana kwa injini
          // ya kweli inayochambua wakati halisi. Zaidi ya hilo, KAMA
          // hakuna SL/TP hit iliyopatikana KATIKA SCAN HIYO YOTE
          // (jambo linalowezekana), position ILIBAKI WAZI kwa MUDA
          // WOTE uliobaki wa backtest (miaka mingi), na hatimaye
          // ilifungwa kwa bei ya "SASA" (leo) dhidi ya entry ya
          // MIAKA kadhaa iliyopita - hii ndiyo iliyosababisha matokeo
          // ya ajabu kama "Max drawdown: 660.5%" na balance HASI
          // tulizoziona kwenye FRXGBPCHF.
          //
          // FIX: scan sasa IMEZUIWA (bounded) HADI 'bar.epoch' (wakati
          // wa H1 bar ya SASA kwenye mzunguko wa nje) - si zaidi ya
          // hapo. Hii inahakikisha simulation "inaona" TU data
          // ambayo ingekuwepo KWELI kwa wakati huo, bila kuangalia
          // mbeleni. Kama SL/TP haijafikiwa bado ndani ya kikomo hiki,
          // tunaendelea kusubiri (position inabaki wazi) na
          // kuchunguza tena kwenye H1 bar INAYOFUATA - hatua kwa
          // hatua, sahihi kabisa.
          int scan = m15Ptr;
          while (scan < m15Hist.length) {
            final m = m15Hist[scan];

            // FIX kuu: 'bar.epoch' (SASA), si 'endEpoch' (mwisho wa
            // backtest nzima).
            if (m.epoch > bar.epoch) break;

            final hitSl = pos.isBuy
                ? m.low <= pos.stopLoss
                : m.high >= pos.stopLoss;
            final hitTp = pos.isBuy
                ? m.high >= pos.takeProfit
                : m.low <= pos.takeProfit;

            if (hitSl || hitTp) {
              final outcome = (hitSl && hitTp)
                  ? "BOTH_TOUCHED_SL_ASSUMED" // kanuni #3: kihafidhina
                  : (hitSl ? "SL" : "TP");

              final exitPrice = (outcome == "TP") ? pos.takeProfit : pos.stopLoss;

              final trade = _closeBacktestTrade(
                symbol: pair,
                open: pos,
                exitEpoch: m.epoch,
                exitPrice: exitPrice,
                outcome: outcome,
                balanceBefore: balance,
                spreadCost: spreadCost,
                commissionPerLot: commissionPerLot,
                pointValuePerLot: pointValuePerLot,
              );

              balance = trade.balanceAfter;
              trades.add(trade);
              equityCurve.add(balance);
              open = null;
              m15Ptr = scan + 1;

              // 🔍 ONGEZO JIPYA (diagnostic isiyofungwa na debugMode):
              final closeDate = DateTime.fromMillisecondsSinceEpoch(
                m.epoch * 1000,
              ).toUtc();

              print(
                "🔴 BACKTEST CLOSE $pair [$closeDate] outcome=$outcome "
                "exitPrice=$exitPrice netPnl=${trade.netPnl} "
                "balance=$balance",
              );

              break;
            }

            scan++;
          }

          // 🚨 ONGEZO JIPYA (ulinzi wa ziada - "safety net"): hata
          // baada ya fix ya lookahead hapo juu, tunaongeza kikomo cha
          // MUDA WA JUU zaidi wa kushikilia trade (siku 30) - endapo
          // kwa sababu YOYOTE (data mbovu, hitilafu nyingine
          // isiyotarajiwa) position ikikwama bila kufunga kwa muda
          // mrefu isivyo kawaida, tunaifunga kwa nguvu kwa bei ya SASA
          // badala ya kuiacha ivuje hadi mwisho wa backtest nzima na
          // kutoa matokeo ya ajabu kama tuliyoyaona.
          if (open != null) {
            final heldSeconds = bar.epoch - open.entryEpoch;
            const maxHoldSeconds = 30 * 24 * 3600; // siku 30

            if (heldSeconds > maxHoldSeconds) {
              print(
                "⚠️ BACKTEST: $pair trade imeshikiliwa zaidi ya siku 30 "
                "bila SL/TP kufikiwa - inafungwa kwa nguvu kwa bei ya "
                "sasa (usalama dhidi ya matokeo yasiyo ya kawaida).",
              );

              final trade = _closeBacktestTrade(
                symbol: pair,
                open: open,
                exitEpoch: bar.epoch,
                exitPrice: bar.close,
                outcome: "MAX_HOLD_TIME_EXCEEDED",
                balanceBefore: balance,
                spreadCost: spreadCost,
                commissionPerLot: commissionPerLot,
                pointValuePerLot: pointValuePerLot,
              );

              balance = trade.balanceAfter;
              trades.add(trade);
              equityCurve.add(balance);
              open = null;
            }
          }
        }

        // ---------- KUTAFUTA SIGNAL MPYA (kama hakuna trade wazi) ----
        if (open == null &&
            bar.epoch >= startEpoch &&
            h1Slice.length >= 120 &&
            h4Slice.length >= 50 &&
            d1Slice.length >= 50 &&
            w1Slice.length >= 20) {
          eligibleBars++;

          final result = _analyze(pair, w1Slice, d1Slice, h4Slice, h1Slice);

          // FIX: 'result.isValidTrade' iliondolewa - MarketAnalysisResult
          // ya mradi huu haina field hii. 'canBuy || canSell' ni sawa
          // kimantiki (ndivyo 'isValidTrade' ilivyokuwa ikihesabiwa
          // kwenye faili la SERVER2-ENGINE awali).
          if (result.canBuy || result.canSell) {
            signalsFound++;

            final entry = result.risk.entry;
            final sl = result.risk.stopLoss;
            final tp = result.risk.takeProfit;
            final stopDistance = (entry - sl).abs();

            if (stopDistance > 0 && entry > 0) {
              final riskAmount = balance * (riskPercentPerTrade / 100);

              final lots = fixedLotSize ??
                  (riskAmount / (stopDistance * pointValuePerLot));

              // 🚨 FIX (bug hatari - "lots explosion" kwa alama zenye
              // bei ghafi ndogo): tulithibitisha live kwenye FRXAUDUSD
              // - stopDistance ilikuwa bei ghafi ndogo mno (0.0008,
              // kawaida kwa forex yenye bei ~0.6) ikilinganishwa na
              // 'pointValuePerLot' ya default (1.0, sahihi TU kwa
              // alama zenye bei ghafi kubwa kama synthetics/crypto -
              // JD50~49000, BTC~91000). Matokeo: lots=12466 (haiwezekani
              // kabisa - forex halisi hutumia 0.01-100 lots), na
              // Average R:-624 (badala ya -1.0 iliyokusudiwa).
              //
              // SASA: 'lots' inapopita ukomo wa busara (maxLots),
              // hii ni ISHARA kwamba 'pointValuePerLot' HAIENDANI na
              // alama hii mahususi (forex inahitaji pip-value HALISI,
              // si default ya 1.0) - badala ya kuruhusu position
              // isiyowezekana kuharibu matokeo kimya kimya, trade
              // INARUKWA na onyo wazi linatolewa.
              if (lots > 0 && lots <= maxLots) {
                open = _OpenBacktestPosition(
                  isBuy: result.canBuy,
                  entryEpoch: bar.epoch,
                  entryPrice: entry,
                  stopLoss: sl,
                  takeProfit: tp,
                  lots: lots,
                  riskAmount: riskAmount,
                );

                // 🔍 ONGEZO JIPYA (diagnostic isiyofungwa na debugMode):
                // print hii inaonekana KILA WAKATI trade inapofunguka
                // wakati wa backtest - inatuonyesha entry/SL/TP/lots
                // halisi zilizotumika, ili tuweze kuthibitisha kama
                // ni za busara au la.
                final entryDate = DateTime.fromMillisecondsSinceEpoch(
                  bar.epoch * 1000,
                ).toUtc();

                print(
                  "🟢 BACKTEST OPEN $pair [$entryDate] "
                  "${result.canBuy ? "BUY" : "SELL"} "
                  "entry=$entry sl=$sl tp=$tp "
                  "stopDistance=$stopDistance lots=$lots "
                  "riskAmount=$riskAmount balance=$balance",
                );
              } else if (lots > maxLots) {
                print(
                  "⚠️ BACKTEST $pair: signal ilipatikana lakini "
                  "lots=$lots INAPITA ukomo wa busara (maxLots=$maxLots). "
                  "'pointValuePerLot' ($pointValuePerLot) HAIENDANI na "
                  "alama hii (stopDistance=$stopDistance ni bei ghafi "
                  "ndogo mno kwa default hii - kawaida kwa forex). "
                  "Trade HAIKUFUNGULIWA - toa 'pointValuePerLot' sahihi "
                  "kwa alama hii kabla ya kuamini matokeo ya backtest.",
                );
              } else {
                print(
                  "⚠️ BACKTEST $pair: signal ilipatikana lakini lots<=0 "
                  "(riskAmount=$riskAmount, stopDistance=$stopDistance) "
                  "- trade HAIKUFUNGULIWA.",
                );
              }
            } else {
              print(
                "⚠️ BACKTEST $pair: signal ilipatikana lakini "
                "stopDistance<=0 au entry<=0 (entry=$entry, sl=$sl) "
                "- trade HAIKUFUNGULIWA.",
              );
            }
          }
        }
      }

      // 🔍 ONGEZO JIPYA (diagnostic): muhtasari wa "fursa" zilizopatikana
      // dhidi ya trades zilizofunguliwa HALISI - hii inaonyesha kama
      // tatizo liko kwenye "hakuna fursa" (eligibleBars ndogo) au
      // "fursa zipo lakini hazizalishi signal" (signalsFound ndogo
      // ikilinganishwa na eligibleBars) au "signal zinapatikana lakini
      // hazifunguliwi trade" (signalsFound > trades.length).
      print(
        "🔍 DIAGNOSTIC $pair MUHTASARI: eligibleBars=$eligibleBars "
        "(bars zenye data ya kutosha na ndani ya kipindi), "
        "signalsFound=$signalsFound (canBuy||canSell ilikuwa true), "
        "tradesOpened=${trades.length} (kabla ya kufunga mwishoni)",
      );

      // Trade iliyobaki wazi mwishoni mwa kipindi - funga kwa bei ya
      // mwisho iliyopo (alama ya "haijafunga kihalisia", si TP wala SL).
      if (open != null) {
        final lastPrice = m15Hist.isNotEmpty
            ? m15Hist.last.close
            : h1Hist.last.close;

        final trade = _closeBacktestTrade(
          symbol: pair,
          open: open,
          exitEpoch: m15Hist.isNotEmpty ? m15Hist.last.epoch : h1Hist.last.epoch,
          exitPrice: lastPrice,
          outcome: "OPEN_AT_END",
          balanceBefore: balance,
          spreadCost: spreadCost,
          commissionPerLot: commissionPerLot,
          pointValuePerLot: pointValuePerLot,
        );

        balance = trade.balanceAfter;
        trades.add(trade);
        equityCurve.add(balance);
      }

      final result = BacktestResult(
        symbol: pair,
        start: start,
        end: end,
        startingBalance: startingBalance,
        endingBalance: balance,
        trades: trades,
        equityCurve: equityCurve,
      );

      // FIX: print moja kwa moja (si _log) kwa sababu ile ile hapo juu -
      // matokeo ya mwisho ya backtest lazima yaonekane KILA WAKATI,
      // yasitegemee 'verbose'/'debugMode'.
      print(result.summary());

      return result;
    } finally {
      debugMode = wasDebug;
    }
  }

  BacktestTrade _closeBacktestTrade({
    required String symbol,
    required _OpenBacktestPosition open,
    required int exitEpoch,
    required double exitPrice,
    required String outcome,
    required double balanceBefore,
    required double spreadCost,
    required double commissionPerLot,
    required double pointValuePerLot,
  }) {
    final priceMove = open.isBuy
        ? (exitPrice - open.entryPrice)
        : (open.entryPrice - exitPrice);

    final grossPnl = priceMove * open.lots * pointValuePerLot;

    final costs =
        (spreadCost * open.lots * pointValuePerLot) +
            (commissionPerLot * open.lots);

    final netPnl = grossPnl - costs;

    final rMultiple =
        open.riskAmount > 0 ? netPnl / open.riskAmount : 0.0;

    return BacktestTrade(
      symbol: symbol,
      isBuy: open.isBuy,
      entryEpoch: open.entryEpoch,
      exitEpoch: exitEpoch,
      entryPrice: open.entryPrice,
      stopLoss: open.stopLoss,
      takeProfit: open.takeProfit,
      exitPrice: exitPrice,
      lots: open.lots,
      riskAmount: open.riskAmount,
      grossPnl: grossPnl,
      costs: costs,
      netPnl: netPnl,
      rMultiple: rMultiple,
      outcome: outcome,
      balanceAfter: balanceBefore + netPnl,
    );
  }
}

// Msaidizi wa ndani (private kwa faili hili): trade iliyo wazi wakati wa
// backtest, kabla haijafungwa.
class _OpenBacktestPosition {
  final bool isBuy;
  final int entryEpoch;
  final double entryPrice;
  final double stopLoss;
  final double takeProfit;
  final double lots;
  final double riskAmount;

  const _OpenBacktestPosition({
    required this.isBuy,
    required this.entryEpoch,
    required this.entryPrice,
    required this.stopLoss,
    required this.takeProfit,
    required this.lots,
    required this.riskAmount,
  });
}