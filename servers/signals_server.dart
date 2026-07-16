import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:web_socket_channel/io.dart';

import '../services/market_analysis_service.dart';
import '../models/market_analysis_result.dart';
import '../models/all_pairs.dart';
import '../services/deriv_service.dart';

/// ================= GLOBAL STATE =================
final Map<String, List<WebSocketChannel>> _clients = {};
final Map<WebSocketChannel, StreamSubscription> _subscriptions = {};
final Map<WebSocketChannel, Timer> _heartbeats = {};
final Map<String, DateTime> _lastSent = {};

final derivService = DerivService.instance;

const int cooldownSeconds = 3;

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

  for (final p in allPairs28) {
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

  await service.startPairs(allPairs28);
  service.startPeriodicAnalysis(allPairs28);

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

      if (!derivService.isReady(resolved)) {
        _safeSend(socket, {
          "type": "error",
          "message": "Alama '$resolved' bado haiko tayari (data haitoshi bado).",
        });
        return;
      }

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

  for (final pair in allPairs28) {
    // FIX: 'latestFor()' sasa inasawazisha jina lenyewe ndani
    // (angalia fix kwenye market_analysis_service.dart), hivyo hii
    // itapata matokeo sahihi bila kujali herufi za 'pair' kama
    // zilivyoandikwa kwenye allPairs28.
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