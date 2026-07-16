// =====================================================================
// backtest_validation.dart (v2 - ALAMA ZOTE)
// =====================================================================
//
// MAHALI: C:\Users\HP 840 G3\wisty_server\signals\models\backtest_validation.dart
//
// MABADILIKO KUTOKA TOLEO LA KWANZA:
//   1. Sasa inapata orodha ya alama ZOTE moja kwa moja kutoka Deriv
//      (kupitia getMarketPairs()) badala ya orodha ya alama 8-11
//      zilizowekwa waziwazi - hii inatupatia SAMPULI KUBWA ZAIDI ya
//      trades (jumla kutoka alama nyingi), muhimu kwa uhakika wa
//      kitakwimu.
//   2. 'backtestDays' imepunguzwa kutoka 730 kwenda 365 - tuligundua
//      kwamba Deriv haina data zaidi ya ~mwaka 1 kwa alama nyingi
//      (angalia logi za awali) - kuomba zaidi ya hapo hakuongezi
//      chochote, ni upotevu wa muda tu.
//   3. Ripoti ya JUMLA (aggregate) sasa ni sehemu kuu ya matokeo - si
//      tu jedwali la kila alama peke yake.
//
// MUHIMU: hii itachukua MUDA MREFU (huenda saa kadhaa) kwa sababu ya
// idadi kubwa ya alama (zinaweza kuwa 90+) na pagination ya historia
// kwa kila moja. Ripoti ya maendeleo inachapishwa kila alama ili
// uweze kufuatilia bila kusubiri mwisho kabisa kujua kinachoendelea.
// Unaweza kuisimamisha wakati wowote (Ctrl+C) na bado kuwa na matokeo
// ya alama zilizokwisha kuchambuliwa kwenye console.

import '../services/deriv_service.dart';
import '../services/market_analysis_service.dart';

const int backtestDays = 365; // mwaka 1 - inaendana na data halisi ya Deriv

// Alama za kuruka (skip) - kwa sababu zozote maalum (mf. hazina data ya
// kutosha, au si za kipaumbele). Acha tupu kuchambua ZOTE.
const skipSymbols = <String>[];

// 🚨 ONGEZO JIPYA (fix ya bug halisi - "lots explosion" kwa forex):
// tuligundua LIVE kwamba 'pointValuePerLot' ya default (1.0) inatoa
// matokeo ya UONGO kabisa kwa forex (mf. FRXAUDUSD ilionyesha
// "Average R: -624" badala ya -1.0 iliyokusudiwa) - kwa sababu bei
// ghafi ya forex ni ndogo (~0.5-1.5) ikilinganishwa na synthetics/
// crypto (mamia/maelfu). Injini (market_analysis_service.dart) sasa
// ina ulinzi wa "maxLots" unaozuia trade zisizo za busara kabisa
// zisifunguliwe - lakini bado ni bora kutoa 'pointValuePerLot' sahihi
// zaidi tangu mwanzo badala ya kutegemea ulinzi huo peke yake.
//
// ⚠️ MUHIMU: namba hii (100000) ni MAKADIRIO ya kawaida ya "standard
// lot" ya forex (units 100,000) - SI sahihi 100% kwa kila jozi (pip
// value halisi inategemea currency ya akaunti yako na jozi mahususi).
// Kwa usahihi kamili, unahitaji jedwali la pip-value kwa kila jozi.
double _pointValueFor(String symbol) {
  final s = symbol.toUpperCase();

  if (s.startsWith('FRX')) {
    // Forex - bei ghafi ndogo, inahitaji "contract size" kubwa zaidi
    // kufanya lots ziwe za busara (0.01-10 badala ya maelfu).
    return 100000;
  }

  // Synthetics (BOOM/CRASH/JD/R_/1HZ/STPRNG) na crypto (CRY*) - bei
  // ghafi tayari ni kubwa (mamia/maelfu), 1.0 inatosha.
  return 1.0;
}

// 🚨 ONGEZO JIPYA #2 (fix ya bug ya pili iliyofichika ndani ya fix ya
// kwanza): 'spreadCost' NAYO inahitaji kuendana na aina ya alama, kwa
// sababu ile ile ya 'pointValuePerLot'. Formula ya gharama ni:
//   costs = spreadCost * lots * pointValuePerLot
// 'spreadCost=0.5' ilikuwa sahihi kwa synthetics (bei ghafi kubwa,
// mamia/maelfu) - lakini mara tu 'pointValuePerLot' ya forex
// ilipopandishwa kwenda 100000 (fix ya kwanza), gharama HIYO HIYO
// '0.5' ikawa IKIZIDISHWA na 100000 - ikitoa "gharama ya spread" ya
// zaidi ya $6000 kwenye trade MOJA (badala ya senti chache za pip
// halisi za forex)! Hii ilisababisha maafa yale yale (Average R:
// -624) kuendelea HATA baada ya 'lots' kuwa sahihi. 'spreadCost'
// LAZIMA iwe KWA BEI GHAFI (raw price units - sawa na 'stopDistance'),
// SI kiasi cha fedha moja kwa moja.
double _spreadFor(String symbol) {
  final s = symbol.toUpperCase();

  if (s.startsWith('FRX')) {
    // Makadirio ya spread halisi ya forex kwa bei ghafi (mf. pip 2-3
    // kwa jozi nyingi kuu - 0.0002-0.0003). Rekebisha kwa alama zako
    // mahususi kama unajua spread halisi kutoka Deriv.
    return 0.0003;
  }

  // Synthetics/crypto - bei ghafi kubwa, spread ya '0.5' bado
  // inafaa kama makadirio ya jumla.
  return 0.5;
}

Future<void> main() async {
  await runFullMarketBacktest();
}

Future<void> runFullMarketBacktest() async {
  final deriv = DerivService.instance;

  await deriv.connect();

  print('⏳ Inapata orodha ya alama zote kutoka Deriv...');
  final allPairs = await deriv.getMarketPairs();

  final symbolsToTest =
      allPairs.where((p) => !skipSymbols.contains(p)).toList();

  print(
    '📋 Alama ${symbolsToTest.length} zitachambuliwa (kutoka '
    '${allPairs.length} zilizopatikana, ${skipSymbols.length} '
    'zimerukwa).',
  );
  print(
    '⏱️ MUHIMU: hii inaweza kuchukua muda mrefu (saa kadhaa) - '
    'ripoti ya maendeleo itaonekana kila alama.',
  );

  final results = <String, BacktestResult>{};
  int completed = 0;
  int failed = 0;

  for (final symbol in symbolsToTest) {
    completed++;

    print('');
    print(
      '⏳ [$completed/${symbolsToTest.length}] Backtest: $symbol '
      '(siku $backtestDays) ...',
    );

    try {
      final result = await MarketAnalysisService.instance.runBacktest(
        symbol: symbol,
        start: DateTime.now().subtract(const Duration(days: backtestDays)),
        end: DateTime.now(),
        startingBalance: 1000,
        riskPercentPerTrade: 1.0,

        // ⚠️ Makadirio ya jumla ya spread - si sahihi 100% kwa kila
        // alama (forex vs synthetics vs crypto zina spread tofauti
        // sana). Kwa uchambuzi wa mwisho kabisa kabla ya pesa halisi,
        // hii inahitaji kuboreshwa kwa Map<String,double> ya spread
        // halisi kwa kila alama.
        // FIX: spreadCost sasa inachaguliwa kulingana na aina ya
        // alama (angalia _spreadFor() hapo juu) - badala ya '0.5'
        // moja iliyokuwa ikisababisha maafa kwa forex.
        spreadCost: _spreadFor(symbol),

        // FIX: pointValuePerLot sasa inachaguliwa kulingana na aina
        // ya alama (angalia _pointValueFor() hapo juu) - badala ya
        // default ya 1.0 pekee inayosababisha "lots explosion" kwa
        // forex.
        pointValuePerLot: _pointValueFor(symbol),

        lookbackDays: 400,
        verbose: false,
      );

      results[symbol] = result;

      print(
        '   ✅ $symbol: trades=${result.totalTrades} '
        'winRate=${result.winRatePct.toStringAsFixed(1)}% '
        'return=${result.totalReturnPct.toStringAsFixed(1)}%',
      );
    } catch (e) {
      failed++;
      print('   ❌ Backtest ya $symbol imeshindwa: $e');
    }

    // Pumziko kati ya alama - epuka kulemea muunganisho wa Deriv.
    await Future.delayed(const Duration(seconds: 2));
  }

  // =====================================================================
  // RIPOTI YA JUMLA (AGGREGATE) - hii ndiyo muhimu zaidi
  // =====================================================================
  print('');
  print('═══════════════════════════════════════════════════════════');
  print('RIPOTI YA JUMLA - ALAMA ZOTE ZILIZOCHAMBULIWA');
  print('═══════════════════════════════════════════════════════════');
  print(
    'Alama zilizochambuliwa kikamilifu: ${results.length}/'
    '${symbolsToTest.length} (zilizoshindwa: $failed)',
  );
  print('');

  final allTrades = results.values.expand((r) => r.trades).toList();

  final totalTrades = allTrades.length;
  final totalWins = allTrades.where((t) => t.netPnl > 0).length;
  final totalLosses = allTrades.where((t) => t.netPnl <= 0).length;
  final overallWinRate =
      totalTrades == 0 ? 0.0 : (totalWins / totalTrades) * 100;

  final grossProfit = allTrades
      .where((t) => t.netPnl > 0)
      .fold(0.0, (a, t) => a + t.netPnl);
  final grossLoss = allTrades
      .where((t) => t.netPnl <= 0)
      .fold(0.0, (a, t) => a + t.netPnl.abs());
  final overallProfitFactor = grossLoss == 0 ? null : grossProfit / grossLoss;

  final avgRMultiple = totalTrades == 0
      ? 0.0
      : allTrades.fold(0.0, (a, t) => a + t.rMultiple) / totalTrades;

  print('───────────────────────────────────────────────────────────');
  print('JUMLA YA TRADES (alama zote pamoja): $totalTrades');
  print('Ushindi: $totalWins | Hasara: $totalLosses');
  print('Win Rate ya JUMLA: ${overallWinRate.toStringAsFixed(1)}%');
  print(
    'Profit Factor ya JUMLA: '
    '${overallProfitFactor?.toStringAsFixed(2) ?? "N/A (hakuna hasara)"}',
  );
  print('Average R (jumla): ${avgRMultiple.toStringAsFixed(2)}');
  print('───────────────────────────────────────────────────────────');

  if (totalTrades < 30) {
    print(
      '⚠️⚠️⚠️ ONYO KUBWA: hata baada ya kuunganisha alama zote, '
      'jumla ya trades ($totalTrades) BADO ni chini ya 30 - HII NI '
      'SAMPULI NDOGO MNO KUAMINIKA KITAKWIMU. Namba za win rate/profit '
      'factor hapo juu HAZIWEZI kutumika kufanya maamuzi ya pesa '
      'halisi. Chaguo: (1) legeza vizingiti vya confluence kidogo ili '
      'kupata trades zaidi (kwa tahadhari), au (2) subiri wiki/miezi '
      'zaidi ili data ipya ijikusanye yenyewe kupitia matumizi ya '
      'moja kwa moja ya mfumo.',
    );
  } else {
    print(
      '✅ Sampuli ya trades ($totalTrades) imefikia kiwango cha chini '
      'cha uaminifu wa kitakwimu (30+). Bado kumbuka: matokeo ya '
      'nyuma hayahakikishii ya baadaye.',
    );
  }

  // ---------- Jedwali la kila alama (zilizo na trades TU) ----------
  print('');
  print('═══════════════════════════════════════════════════════════');
  print('MCHANGANUO WA KILA ALAMA (zenye trades >0 tu)');
  print('═══════════════════════════════════════════════════════════');
  print(
    'Alama        | Trades | Win%  | PF    | MaxDD% | Return%',
  );
  print('-' * 68);

  final sorted = results.entries.where((e) => e.value.totalTrades > 0).toList()
    ..sort((a, b) => b.value.totalTrades.compareTo(a.value.totalTrades));

  for (final entry in sorted) {
    final r = entry.value;
    print(
      '${entry.key.padRight(13)}| '
      '${r.totalTrades.toString().padLeft(6)} | '
      '${r.winRatePct.toStringAsFixed(1).padLeft(5)} | '
      '${(r.profitFactor?.toStringAsFixed(2) ?? "N/A").padLeft(5)} | '
      '${r.maxDrawdownPct.toStringAsFixed(1).padLeft(6)} | '
      '${r.totalReturnPct.toStringAsFixed(1).padLeft(8)}',
    );
  }

  final zeroTradeCount = results.length - sorted.length;
  print('-' * 68);
  print(
    'Alama zenye trades 0 (hakuna signal iliyofikia kizingiti '
    'mwaka mzima): $zeroTradeCount',
  );

  print('');
  print(
    '⚠️ KUMBUKA LA MWISHO: namba hizi ni MATOKEO YA NYUMA (mwaka 1 '
    'pekee, kutokana na ukomo wa data ya Deriv) - hazihakikishii '
    'utendaji wa baadaye. "spreadCost:0.5" ni makadirio ya jumla, si '
    'sahihi kwa kila alama.',
  );
}