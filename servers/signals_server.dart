import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:web_socket_channel/io.dart';

import '../services/market_analysis_service.dart';
import '../models/market_analysis_result.dart';
import '../services/deriv_service.dart';

/// ================= GLOBAL STATE =================
final Map<String, List<WebSocketChannel>> _clients = {};
final Map<WebSocketChannel, StreamSubscription> _subscriptions = {};
final Map<WebSocketChannel, Timer> _heartbeats = {};
final Map<String, DateTime> _lastSent = {};

final derivService = DerivService.instance;

const int cooldownSeconds = 3;

// 🚨🚨🚨 FIX YA BUG HALISI (kwa ombi la mtumiaji - "0% kila mahali,
// snapshot 0 pairs"): 'allPairs28' ilikuwa ORODHA TULI (hardcoded,
// kutoka '../models/all_pairs.dart') yenye alama 28 TU - tofauti
// KABISA na Server 2 ambayo inatumia 'getMarketPairs()' (kwa nguvu,
// alama 89+). Kama majina ndani ya 'allPairs28' hayakuendana KABISA
// na yale halisi ya Deriv (au yalikuwa machache mno), 'latestFor()'
// ilikuwa ikirudisha 'null' kwa KILA alama - snapshot ikabaki TUPU
// KABISA ("0 pairs"), na clients wapya (mfano baada ya reconnect)
// hawakuwahi kupata data yoyote ya awali. Sasa 'allPairs28'
// imeondolewa KABISA - orodha ya alama sasa inapatikana KWA NGUVU
// (dynamic) kupitia 'getMarketPairs()', sawa KABISA na Server 2 -
// hakuna tena hatari ya "list mbili tofauti zisizoendana".
List<String> _allPairs = [];

// FIX (bug halisi yenye athari kubwa - sababu kuu clients hawakuwa
// wakipokea signal walizojisajilia): injini (MarketAnalysisService)
// INAHIFADHI NA KUTUMA 'result.symbol' KILA WAKATI kwa jina
// LILILOSAWAZISHWA (UPPERCASE - angalia _normalize() ndani ya
// market_analysis_service.dart). Awali, faili hii ilikuwa ikitumia
// 'pair' KAMA ALIVYOTUMA CLIENT (bila kusawazisha) kama KEY ya
// '_clients' map. Kwa hiyo: client akijisajili na "frxEURUSD" (herufi
// ndogo/kati), akaunti hiyo iliwekwa kwenye '_clients["frxEURUSD"]',
// lakini injini ilipotangaza matokeo, ilikuwa ikitafuta
// '_clients["FRXEURUSD"]' (UPPERCASE, kutoka result.symbol) - MAJINA
// MAWILI TOFAUTI YASIYOLINGANA - client ASINGEWAHI kupokea signal
// yoyote ile, licha ya kuonekana "amejisajili" kikamilifu bila
// hitilafu yoyote. Sasa KILA MAHALI KWENYE FAILI HII kunatumia jina
// LILILOSAWAZISHWA (UPPERCASE) kama chanzo pekee cha ukweli - sawa
// kabisa na mkataba wa injini.
String _normalize(String s) => s.trim().toUpperCase();

/// Inatafuta jina sahihi (halisi, kama lilivyo kwenye allPairs28) kwa
/// kulinganisha KIMWELEKEO kisicho na mzigo wa herufi kubwa/ndogo, na
/// kurudisha jina hilo LILILOSAWAZISHWA (UPPERCASE) kwa matumizi ya
/// ndani. Kurudisha null kama halijapatikana - hii inazuia clients
/// kujisajili kwenye alama zisizokuwepo/zisizoungwa mkono.
String? _resolvePair(String raw) {
  final normalizedInput = _normalize(raw);

  for (final p in _allPairs) {
    if (_normalize(p) == normalizedInput) {
      return normalizedInput;
    }
  }

  return null;
}

/// ================= MAIN =================
Future<void> main() async {
  HttpServer server;

  try {
    server = await HttpServer.bind(InternetAddress.anyIPv4, 8080);
  } catch (e) {
    // FIX: awali kama port 8080 ilikuwa tayari inatumika (mf. process
    // ya zamani bado inaendesha), programu ingeanguka na 'stack trace'
    // isiyo na maana wazi. Sasa ujumbe wa hitilafu ni wazi zaidi.
    print("❌ IMESHINDWA KUFUNGUA PORT 8080: $e");
    print("   (Je, kuna mchakato mwingine tayari unatumia port hii?)");
    return;
  }

  print('📡 WISTY SIGNAL SERVER ws://0.0.0.0:8080/signals');

  final service = MarketAnalysisService.instance;

  // 🚨 FIX (angalia maelezo marefu hapo juu kuhusu 'allPairs28'):
  // tunaunganisha na Deriv KWANZA, kisha kupata orodha KAMILI ya
  // alama KWA NGUVU (dynamic) - sawa KABISA na Server 2. Hii
  // inahakikisha Server 1 na Server 2 ZINACHAMBUA ALAMA ZILE ZILE
  // HASA, bila hatari ya "orodha mbili tofauti zisizoendana".
  print("🔌 Kuunganisha na Deriv kupata orodha ya alama...");

  await derivService.connect();

  // 🚨🚨🚨 FIX YA BUG HALISI YA MWISHO (kwa ombi la mtumiaji - "KILA
  // alama 'haitambuliki'"): tuligundua kwamba 'await for (HttpRequest
  // request in server)' (inayoshughulikia wateja) HAIANZI mpaka hatua
  // hii ikamilike - kwa hiyo HAIKUWA "race condition" ya muda. Badala
  // yake: 'getMarketPairs()' ilikuwa ikirudisha ORODHA TUPU KABISA
  // (kushindwa kikamilifu, si "bado inasubiri") - na code ya AWALI
  // haikuwa ikiangalia hilo KABISA, ikiendelea mbele na
  // '_allPairs=[]' MILELE kwa kikao (session) kizima cha server. Kwa
  // hiyo KILA client aliyejaribu kujisajili (subscribe) kwa ALAMA
  // YOYOTE alipata "haitambuliki" - si kwa sababu ya muda, bali kwa
  // sababu orodha halisi ilikuwa TUPU tangu mwanzo hadi mwisho.
  //
  // Sasa: tunajaribu tena (retry, na muda unaoongezeka - 5s, 10s,
  // 20s...) HADI orodha isiwe tupu - na server HAIANZI KUPOKEA
  // WATEJA KABISA mpaka hili likamilike (badala ya kuendelea kimya
  // kimya na orodha tupu).
  const maxPairsAttempts = 6;
  int pairsAttempt = 0;

  while (_allPairs.isEmpty && pairsAttempt < maxPairsAttempts) {
    pairsAttempt++;

    print(
      "🔌 Kupata orodha ya alama (jaribio $pairsAttempt/$maxPairsAttempts)...",
    );

    _allPairs = await derivService.getMarketPairs();

    if (_allPairs.isEmpty && pairsAttempt < maxPairsAttempts) {
      final waitSeconds = 5 * pairsAttempt;
      print(
        "⚠️ getMarketPairs() imerudisha orodha TUPU - kusubiri "
        "sekunde $waitSeconds kisha kujaribu tena...",
      );
      await Future.delayed(Duration(seconds: waitSeconds));
    }
  }

  if (_allPairs.isEmpty) {
    print(
      "❌❌❌ HITILAFU KUBWA: getMarketPairs() imeshindwa mara zote "
      "$maxPairsAttempts - HAKUNA alama zitakazopatikana kwa server "
      "hii. Angalia Deriv App ID/Token ya Server 1, au muunganiko wa "
      "mtandao. Server bado itaendesha (kuepuka kuanguka kabisa), "
      "lakini clients HAWATAWEZA kujisajili kwa alama yoyote hadi "
      "hili litatuliwe (anzisha upya server baada ya kurekebisha).",
    );
  }

  print("📊 SIGNALS SERVER: alama ${_allPairs.length} zimepatikana kwa nguvu.");

  await service.startPairs(_allPairs);
  service.startPeriodicAnalysis(_allPairs);

  service.analysisStream.listen((result) {
    _handleEngineSignal(result);
  });

  await for (HttpRequest request in server) {
    if (request.uri.path != '/signals') {
      request.response
        ..statusCode = HttpStatus.notFound
        ..close();
      continue;
    }

    if (!WebSocketTransformer.isUpgradeRequest(request)) {
      request.response
        ..statusCode = HttpStatus.badRequest
        ..write('WebSocket only')
        ..close();
      continue;
    }

    final socket = await WebSocketTransformer.upgrade(request);
    final channel = IOWebSocketChannel(socket);

    _handleSocket(channel);
  }
}

/// ================= ENGINE SIGNAL HANDLER =================
void _handleEngineSignal(MarketAnalysisResult result) {
  // result.symbol tayari ni UPPERCASE (kutoka injini) - hakuna haja ya
  // kusawazisha tena hapa, lakini tunatumia _normalize() kwa uwazi wa
  // nia (defensive - endapo injini itabadilika siku moja).
  final symbol = _normalize(result.symbol);

  final last = _lastSent[symbol];

  if (last != null &&
      DateTime.now().difference(last).inSeconds < cooldownSeconds) {
    return;
  }

  _lastSent[symbol] = DateTime.now();

  print("🔥 SIGNAL $symbol "
      "${result.canBuy ? "BUY" : result.canSell ? "SELL" : "WAIT"}");

  _broadcastSignal(result, symbol);
}

/// ================= SOCKET HANDLER =================
void _handleSocket(WebSocketChannel socket) {
  print('✅ Client connected');

  _sendSnapshot(socket);

  _subscriptions[socket]?.cancel();
  _subscriptions[socket] =
      MarketAnalysisService.instance.analysisStream.listen((result) {
    _sendUpdate(socket, result);
  });

  _heartbeats[socket]?.cancel();
  _heartbeats[socket] = Timer.periodic(
    const Duration(seconds: 20),
    (_) => _safeSend(socket, {"type": "ping"}),
  );

  socket.stream.listen(
    (msg) => _handleClient(socket, msg),
    onDone: () => _cleanup(socket),
    onError: (_) => _cleanup(socket),
    cancelOnError: true,
  );
}

/// ================= CLIENT EVENTS =================
void _handleClient(WebSocketChannel socket, dynamic msg) {
  try {
    final data = jsonDecode(msg as String);
    if (data is! Map) return;

    final subscribe = data['subscribe'];
    final unsubscribe = data['unsubscribe'];

    if (subscribe != null) {
      // FIX: sasa tunatumia _resolvePair() (kulinganisha bila kujali
      // herufi kubwa/ndogo) badala ya 'allPairs28.contains(pair)' ya
      // moja kwa moja - awali kama client alituma jina la alama kwa
      // herufi tofauti kidogo na zilivyoandikwa ndani ya allPairs28,
      // ombi lote lilikataliwa KIMYA KIMYA bila ujumbe wowote wa
      // hitilafu kwa client.
      final resolved = _resolvePair(subscribe.toString());

      if (resolved == null) {
        _safeSend(socket, {
          "type": "error",
          "message": "Alama '$subscribe' haitambuliki au haiungwi mkono.",
        });
        return;
      }

      // 🚨🚨🚨 FIX YA BUG HALISI (kwa ombi la mtumiaji - "0% kila
      // mahali milele, hata baada ya dakika 5+"): AWALI hapa kulikuwa
      // na 'if (!derivService.isReady(resolved)) { ...kataa... }' -
      // kama alama haikuwa "tayari" (candles za kutosha) KWA WAKATI
      // HUSISO WA USAJILI, ombi lilikataliwa na ujumbe wa "error" -
      // LAKINI 'api_service.dart' (Flutter client) HAIKUWAHI
      // KUSHUGHULIKIA ujumbe wa aina "error" KABISA (haujaribu tena
      // kiotomatiki) - client alibaki "amejisajili" kwa mtazamo wake,
      // lakini kihalisia HAKUWAHI kuongezwa kwenye '_clients[resolved]'
      // - HAKUWAHI KUPOKEA BROADCAST YOYOTE kwa alama hiyo kwa kikao
      // (session) kizima, hata Server 1 ikiwa tayari BAADAYE. Kama
      // Server 1 na app zilianza karibu wakati mmoja (kawaida sana -
      // mtumiaji anafungua app mara Server 1 ikianzishwa upya), ALAMA
      // NYINGI/ZOTE zingekuwa "hazijawa tayari" wakati huo, na kikao
      // kizima kingebaki "0% milele" - kikithibitishwa na majaribio.
      //
      // Sasa: usajili UNAKUBALIWA KILA WAKATI (bila kujali 'isReady')
      // - hii ni SALAMA KABISA: broadcasts ('_broadcastSignal') tayari
      // hazitumwi mpaka '_run()' ikamilishe uchambuzi WA KWANZA
      // HALISI kwa alama hiyo - kizuizi cha 'isReady' hapa kilikuwa
      // hakina maana (redundant) na kilisababisha hasara halisi.
      _clients.putIfAbsent(resolved, () => []);
      if (!_clients[resolved]!.contains(socket)) {
        _clients[resolved]!.add(socket);
      }

      _safeSend(socket, {
        "type": "subscribed",
        "symbol": resolved,
      });
    }

    if (unsubscribe != null) {
      final resolved = _resolvePair(unsubscribe.toString());
      if (resolved == null) return;

      _clients[resolved]?.remove(socket);

      // FIX (usafi wa kumbukumbu): orodha tupu za '_clients' hazikuwa
      // zikifutwa - baada ya muda mrefu, map hii ingekusanya funguo
      // nyingi zenye orodha tupu bila mpangilio. Sasa tunaifuta funguo
      // nzima ikiwa haina wateja tena.
      if (_clients[resolved]?.isEmpty ?? false) {
        _clients.remove(resolved);
      }
    }
  } catch (e) {
    print("⚠️ _handleClient parse error: $e");
  }
}

/// ================= UPDATE =================
void _sendUpdate(WebSocketChannel socket, MarketAnalysisResult result) {
  final symbol = _normalize(result.symbol);

  final sockets = _clients[symbol];
  if (sockets == null || !sockets.contains(socket)) return;

  // FIX (uwiano na _broadcastSignal): sasa inatuma 'indicators' NZIMA
  // pia - angalia maelezo marefu kwenye _broadcastSignal() kuhusu
  // kwa nini hii ni muhimu kwa server ya risk management.
  _safeSend(socket, {
    "type": "update",
    "symbol": symbol,
    "direction": result.canBuy
        ? "BUY"
        : result.canSell
            ? "SELL"
            : "WAIT",
    "confidence": (result.indicators["confidence"] ?? 0).toDouble(),
    "entry": result.risk.entry,
    "stopLoss": result.risk.stopLoss,
    "takeProfit": result.risk.takeProfit,
    "indicators": result.indicators,
    "timestamp": DateTime.now().toUtc().toIso8601String(),
  });
}

/// ================= BROADCAST =================
void _broadcastSignal(MarketAnalysisResult result, String symbol) {
  final sockets = _clients[symbol];
  if (sockets == null || sockets.isEmpty) return;

  final confidence = (result.indicators["confidence"] ?? 0).toDouble();

  // FIX (uwiano na usanifu wa mfumo mzima): server HII ni ya
  // UCHAMBUZI TU - haifanyi risk management wala kutuma trade (hilo
  // linafanywa na server nyingine, baada ya UI kupokea uchambuzi huu
  // na kuupitisha kwake). Kwa hiyo:
  //   1) "ui.tradeEnabled"/"autoExecute" ZIMEONDOLEWA - kuamua kama
  //      trade "inaruhusiwa" ni jukumu la server ya risk management,
  //      SI la server hii ya uchambuzi. Kutuma maamuzi hayo kutoka
  //      hapa kungeweza kupishana/kukinzana na uamuzi wa server ya
  //      pili (ambayo ina taarifa zaidi - risk ya akaunti, positions
  //      zilizo wazi tayari, n.k.).
  //   2) Payload sasa INA 'indicators' NZIMA (si sehemu chache tu
  //      kama awali - confidence/entry/SL/TP pekee) - hii ndiyo
  //      taarifa kamili (W1/D1 bias, H4 BOS/CHOCH/Sweep/OB/Momentum,
  //      EMA/RSI, confluence yenye mwelekeo, price action patterns)
  //      ambayo server ya risk management inahitaji kufanya uamuzi
  //      wake WENYEWE, wa kujitegemea - badala ya kutegemea muhtasari
  //      uliopunguzwa (BUY/SELL/WAIT + confidence tu).
  final payload = {
    "type": "signal",
    "symbol": symbol,
    "direction": result.canBuy
        ? "BUY"
        : result.canSell
            ? "SELL"
            : "WAIT",
    "confidence": confidence,
    "entry": result.risk.entry,
    "stopLoss": result.risk.stopLoss,
    "takeProfit": result.risk.takeProfit,
    "lotSize": result.risk.lotSize,
    // Taarifa KAMILI ya uchambuzi - angalia maelezo hapo juu.
    "indicators": result.indicators,
    "timestamp": DateTime.now().toUtc().toIso8601String(),
  };

  for (final socket in List<WebSocketChannel>.from(sockets)) {
    _safeSend(socket, payload);
  }
}

/// ================= SNAPSHOT =================
void _sendSnapshot(WebSocketChannel socket) {
  final service = MarketAnalysisService.instance;

  final snapshot = <String, dynamic>{};

  for (final pair in _allPairs) {
    // FIX: 'latestFor()' sasa inasawazisha jina lenyewe ndani
    // (angalia fix kwenye market_analysis_service.dart), hivyo hii
    // itapata matokeo sahihi bila kujali herufi za 'pair' kama
    // zilivyoandikwa kwenye '_allPairs' (sasa ya nguvu/dynamic, si
    // 'allPairs28' tuli ya zamani).
    final r = service.latestFor(pair);
    if (r == null) continue;

    final symbol = _normalize(r.symbol);

    snapshot[symbol] = {
      "symbol": symbol,
      "direction": r.canBuy
          ? "BUY"
          : r.canSell
              ? "SELL"
              : "WAIT",
      "confidence": (r.indicators["confidence"] ?? 0).toDouble(),
      "entry": r.risk.entry,
      "stopLoss": r.risk.stopLoss,
      "takeProfit": r.risk.takeProfit,
      // FIX (uwiano na _broadcastSignal/_sendUpdate): angalia
      // maelezo marefu kwenye _broadcastSignal() - snapshot ya
      // kwanza ya client mpya sasa ina muktadha kamili pia, si
      // muhtasari uliopunguzwa TU.
      "indicators": r.indicators,
      "timestamp": DateTime.now().toUtc().toIso8601String(),
    };
  }

  _safeSend(socket, {
    "type": "snapshot",
    "pairs": snapshot,
  });
}

/// ================= SAFE SEND =================
void _safeSend(WebSocketChannel socket, Map<String, dynamic> data) {
  try {
    socket.sink.add(jsonEncode(data));
  } catch (_) {
    _cleanup(socket);
  }
}

/// ================= CLEANUP =================
void _cleanup(WebSocketChannel socket) {
  _subscriptions[socket]?.cancel();
  _subscriptions.remove(socket);

  _heartbeats[socket]?.cancel();
  _heartbeats.remove(socket);

  // FIX (usafi wa kumbukumbu - sawa na fix ya unsubscribe hapo juu):
  // baada ya kumtoa socket kutoka kila orodha, funguo zenye orodha
  // tupu zinafutwa badala ya kubaki milele kwenye map.
  final emptyKeys = <String>[];

  for (final e in _clients.entries) {
    e.value.remove(socket);
    if (e.value.isEmpty) {
      emptyKeys.add(e.key);
    }
  }

  for (final k in emptyKeys) {
    _clients.remove(k);
  }

  try {
    socket.sink.close();
  } catch (_) {}

  print("❌ Client disconnected");
}