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

/// ================= ALL PAIRS =================
final List<String> allPairs28 = [
  'FRXEURUSD', 'FRXAUDCAD', 'FRXGBPUSD', 'FRXUSDJPY',
  'FRXUSDCAD', 'FRXUSDCHF', 'FRXEURGBP', 'FRXEURJPY',
  'FRXAUDJPY', 'FRXGBPJPY', 'FRXAUDUSD', 'FRXNZDUSD',
  'FRXUSDSGD', 'FRXUSDHKD', 'FRXEURAUD', 'FRXEURCAD',
  'FRXGBPAUD', 'FRXGBPCHF', 'FRXNZDJPY', 'FRXCHFJPY',
  'FRXCADJPY', 'FRXAUDNZD', 'FRXGBPNZD', 'FRXEURCHF',
  'FRXUSDNOK', 'FRXUSDSEK', 'FRXUSDZAR', 'FRXUSDMXN'
];

/// ================= ENTRY POINT =================
void main() async {
  final server = await HttpServer.bind(InternetAddress.anyIPv4, 8080);
  print('📡 Signals WebSocket server running on ws://0.0.0.0:8080/signals');

  await for (HttpRequest request in server) {
    if (request.uri.path == '/signals') {
      if (!WebSocketTransformer.isUpgradeRequest(request)) {
        request.response
          ..statusCode = HttpStatus.badRequest
          ..write('WebSocket connections only')
          ..close();
        continue;
      }

      final socket = await WebSocketTransformer.upgrade(request);
      final channel = IOWebSocketChannel(socket);

      _handleSocket(channel);
    } else {
      request.response
        ..statusCode = HttpStatus.notFound
        ..write('Not Found')
        ..close();
    }
  }
}

/// ================= HANDLE SOCKET =================
void _handleSocket(WebSocketChannel socket) {
  final service = MarketAnalysisService.instance;
  print('📡 Client connected to /signals');

  // Send current data immediately
  _sendAllPairsLatest(socket);

  // Subscribe to live updates
  final sub = service.analysisStream.listen(
    (_) => _sendAllPairsLatest(socket),
    onError: (err) => print("⚠ Analysis stream error: $err"),
  );
  _subscriptions[socket] = sub;

  // Heartbeat every 15s
  _heartbeats[socket]?.cancel();
  _heartbeats[socket] = Timer.periodic(
    const Duration(seconds: 15),
    (_) {
      try {
        socket.sink.add(jsonEncode({
          "type": "ping",
          "timestamp": DateTime.now().toUtc().toIso8601String()
        }));
      } catch (_) {
        _cleanup(socket);
      }
    },
  );

  // Listen to client messages
  socket.stream.listen(
    (msg) => _handleClientMessage(socket, msg),
    onDone: () => _cleanup(socket),
    onError: (_) => _cleanup(socket),
  );
}

/// ================= HANDLE CLIENT MESSAGE =================
void _handleClientMessage(WebSocketChannel socket, dynamic msg) {
  if (msg == 'ping') {
    socket.sink.add(jsonEncode({"type": "pong"}));
    return;
  }

  try {
    final data = jsonDecode(msg);
    if (data['subscribe'] != null) {
      final pair = data['subscribe'].toString();
      print('📩 Client requested subscription for pair: $pair');
      _clients.putIfAbsent(pair, () => []).add(socket);
    }
  } catch (_) {}
}

/// ================= SEND ALL PAIRS =================
void _sendAllPairsLatest(WebSocketChannel socket) {
  final service = MarketAnalysisService.instance;
  final Map<String, dynamic> payload = {};

  for (var pair in allPairs28) {
    final result = service.latestForAllPairsMap()[pair];
    payload[pair] = result != null ? _buildPayload(pair, result) : _emptyPayload(pair);
  }

  try {
    socket.sink.add(jsonEncode(payload));
  } catch (_) {
    _cleanup(socket);
  }
}

/// ================= BUILD PAYLOAD =================
Map<String, dynamic> _buildPayload(String pair, MarketAnalysisResult analysis) {
  final candles = analysis.candles;
  final entryPrice = candles.isNotEmpty ? candles.last.close : 0.0;

  return {
    "symbol": pair,
    "status": analysis.canBuy
        ? "BUY"
        : analysis.canSell
            ? "SELL"
            : "waiting",
    "canBuy": analysis.canBuy,
    "canSell": analysis.canSell,
    "bias": analysis.biasIsBuy ? "BUY" : "SELL",
    "entryPrice": entryPrice,
    "stopLoss": analysis.stopLoss,
    "takeProfit": analysis.takeProfit,
    "conditionsMet": analysis.conditionsMet,
    "failedConditions": analysis.reasonsFailed,
    "candleCount": candles.length,
    "timestamp": DateTime.now().toUtc().toIso8601String(),
  };
}

/// ================= EMPTY PAYLOAD =================
Map<String, dynamic> _emptyPayload(String pair) {
  return {
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
}

/// ================= CLEANUP =================
void _cleanup(WebSocketChannel socket) {
  if (_subscriptions.containsKey(socket)) {
    _subscriptions[socket]?.cancel();
    _subscriptions.remove(socket);
  }

  _heartbeats[socket]?.cancel();
  _heartbeats.remove(socket);

  _clients.forEach((_, list) => list.remove(socket));

  try {
    socket.sink.close();
  } catch (_) {}

  print('❌ Client disconnected');
}