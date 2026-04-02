import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:web_socket_channel/io.dart';

import '../services/market_analysis_service.dart';
import '../models/models.dart';

/// ================= GLOBALS =================
final Map<String, List<WebSocketChannel>> _clients = {};
final Map<WebSocketChannel, StreamSubscription> _subscriptions = {};
final Map<WebSocketChannel, Timer> _heartbeats = {};

bool showOnlySignals = false;

/// ================= ALL PAIRS =================
final List<String> allPairs28 = [
  'frxEURUSD','frxAUDCAD','frxGBPUSD','frxUSDJPY',
  'frxUSDCAD','frxUSDCHF','frxEURGBP','frxEURJPY',
  'frxAUDJPY','frxGBPJPY','frxAUDUSD','frxNZDUSD',
  'frxUSDSGD','frxUSDHKD','frxEURAUD','frxEURCAD',
  'frxGBPAUD','frxGBPCHF','frxNZDJPY','frxCHFJPY',
  'frxCADJPY','frxAUDNZD','frxGBPNZD','frxEURCHF',
  'frxUSDNOK','frxUSDSEK','frxUSDZAR','frxUSDMXN'
];

/// ================= ENTRY =================
void main() async {
  final server = await HttpServer.bind(InternetAddress.anyIPv4, 8080);
  print('📡 Server running ws://0.0.0.0:8080/signals');

  final service = MarketAnalysisService.instance;
  await service.startPairs(allPairs28);

  /// 🔥 GLOBAL STREAM → BROADCAST
  service.analysisStream.listen((result) {
    if (showOnlySignals && !result.canBuy && !result.canSell) return;

    print("📊 ${result.symbol} BUY=${result.canBuy} SELL=${result.canSell}");

    _broadcastUpdate(result.symbol);
  });

  await for (HttpRequest request in server) {
    if (request.uri.path == '/signals') {
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
    } else {
      request.response
        ..statusCode = HttpStatus.notFound
        ..close();
    }
  }
}

/// ================= SOCKET =================
void _handleSocket(WebSocketChannel socket) {
  print('✅ Client connected');

  _sendAllPairsLatest(socket);

  final sub = MarketAnalysisService.instance.analysisStream.listen(
    (_) => _sendAllPairsLatest(socket),
    onError: (_) => _cleanup(socket),
  );

  _subscriptions[socket] = sub;

  /// 💓 HEARTBEAT
  _heartbeats[socket]?.cancel();
  _heartbeats[socket] = Timer.periodic(
    const Duration(seconds: 15),
    (_) {
      try {
        socket.sink.add(jsonEncode({"type": "ping"}));
      } catch (_) {
        _cleanup(socket);
      }
    },
  );

  socket.stream.listen(
    (msg) => _handleClientMessage(socket, msg),
    onDone: () => _cleanup(socket),
    onError: (_) => _cleanup(socket),
  );
}

/// ================= CLIENT MSG =================
void _handleClientMessage(WebSocketChannel socket, dynamic msg) {
  if (msg == 'ping') {
    _sendSafe(socket, {"type": "pong"});
    return;
  }

  try {
    final data = jsonDecode(msg);

    if (data['subscribe'] != null) {
      final pair = data['subscribe'].toString();

      _clients.putIfAbsent(pair, () => []);

      /// 🔥 NO DUPLICATES
      if (!_clients[pair]!.contains(socket)) {
        _clients[pair]!.add(socket);
      }

      print('📩 Subscribed: $pair');
    }

    /// 🔥 unsubscribe support
    if (data['unsubscribe'] != null) {
      final pair = data['unsubscribe'].toString();
      _clients[pair]?.remove(socket);
      print('📤 Unsubscribed: $pair');
    }
  } catch (_) {}
}

/// ================= SEND ALL =================
void _sendAllPairsLatest(WebSocketChannel socket) {
  final service = MarketAnalysisService.instance;
  final Map<String, dynamic> payload = {};

  for (var pair in allPairs28) {
    final result = service.latestFor(pair);
    payload[pair] = result != null
        ? _buildPayload(result)
        : _emptyPayload(pair);
  }

  _sendSafe(socket, payload);
}

/// ================= BROADCAST =================
void _broadcastUpdate(String pair) {
  final sockets = _clients[pair];
  if (sockets == null || sockets.isEmpty) return;

  final result = MarketAnalysisService.instance.latestFor(pair);
  if (result == null) return;

  final payload = _buildPayload(result);

  /// 🔥 SAFE COPY (NO CRASH)
  for (var socket in List<WebSocketChannel>.from(sockets)) {
    _sendSafe(socket, payload);
  }
}

/// ================= PAYLOAD =================
Map<String, dynamic> _buildPayload(MarketAnalysisResult a) {
  final candles = a.candles;
  final entryPrice = candles.isNotEmpty ? candles.last.close : 0.0;

  return {
    "symbol": a.symbol,
    "status": a.canBuy
        ? "BUY"
        : a.canSell
            ? "SELL"
            : "waiting",
    "canBuy": a.canBuy,
    "canSell": a.canSell,
    "bias": a.biasIsBuy ? "BUY" : "SELL",
    "entryPrice": entryPrice,
    "stopLoss": a.stopLoss,
    "takeProfit": a.takeProfit,
    "conditionsMet": a.conditionsMet,
    "failedConditions": a.reasonsFailed,
    "candleCount": candles.length,
    "timestamp": DateTime.now().toUtc().toIso8601String(),
  };
}

Map<String, dynamic> _emptyPayload(String pair) => {
      "symbol": pair,
      "status": "waiting",
      "canBuy": false,
      "canSell": false,
      "entryPrice": 0.0,
      "stopLoss": 0.0,
      "takeProfit": 0.0,
      "conditionsMet": [],
      "failedConditions": [],
      "candleCount": 0,
      "timestamp": DateTime.now().toUtc().toIso8601String(),
    };

/// ================= SAFE SEND =================
void _sendSafe(WebSocketChannel socket, Map<String, dynamic> data) {
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

  /// 🔥 SAFE REMOVE
  for (var entry in _clients.entries) {
    entry.value.remove(socket);
  }

  try {
    socket.sink.close();
  } catch (_) {}

  print('❌ Client disconnected');
}