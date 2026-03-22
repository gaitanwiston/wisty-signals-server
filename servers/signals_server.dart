// signals_server.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:web_socket_channel/io.dart';

import '../services/market_analysis_service.dart';
import '../models/market_analysis_result.dart';

final Map<String, List<WebSocketChannel>> _clients = {};
final Map<WebSocketChannel, StreamSubscription> _subscriptions = {};
final Map<WebSocketChannel, Timer> _heartbeats = {};

void main() async {
  final server = await HttpServer.bind(InternetAddress.anyIPv4, 8080);
  print('📡 Signals WebSocket server running on ws://localhost:8080/signals');

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

/// ================= HANDLE SOCKET LOGIC =================
void _handleSocket(WebSocketChannel socket) {
  final service = MarketAnalysisService.instance;
  String pair = 'FRXEURUSD';

  print('📡 Client connected to /signals');

  // Send latest analysis immediately
  void sendLatest() {
    final latest = service.latestFor(pair);
    if (latest != null) {
      socket.sink.add(jsonEncode(_buildPayload(pair, latest)));
    } else {
      socket.sink.add(jsonEncode({
        "pair": pair,
        "status": "waiting",
        "timestamp": DateTime.now().toUtc().toIso8601String(),
      }));
    }
  }

  sendLatest();

  // Listen for analysis updates
  final sub = service.analysisStream.listen(
    (MarketAnalysisResult analysis) {
      if (analysis.symbol.toUpperCase() == pair) {
        socket.sink.add(jsonEncode(_buildPayload(pair, analysis)));
      }
    },
    onError: (err) => print("⚠ Analysis stream error: $err"),
  );

  _subscriptions[socket] = sub;
  _clients.putIfAbsent(pair, () => []).add(socket);

  // Heartbeat
  _heartbeats[socket]?.cancel();
  _heartbeats[socket] = Timer.periodic(
    const Duration(seconds: 15),
    (_) => socket.sink.add('ping'),
  );

  // Listen to client messages
  socket.stream.listen(
    (msg) {
      pair = _handleClientMessage(socket, msg, pair);
    },
    onDone: () => _cleanup(socket, pair),
    onError: (_) => _cleanup(socket, pair),
  );
}

/// ================= HANDLE CLIENT MESSAGE =================
String _handleClientMessage(
    WebSocketChannel socket, dynamic msg, String currentPair) {
  try {
    final data = jsonDecode(msg);
    if (data['pair'] != null) {
      final newPair = data['pair'].toUpperCase();
      if (newPair != currentPair) {
        print('📩 Switching pair: $currentPair → $newPair');

        _removeClient(socket, currentPair);
        _clients.putIfAbsent(newPair, () => []).add(socket);

        final latest = MarketAnalysisService.instance.latestFor(newPair);
        if (latest != null) {
          socket.sink.add(jsonEncode(_buildPayload(newPair, latest)));
        }

        return newPair;
      }
    }
  } catch (_) {}

  if (msg == 'ping') socket.sink.add('pong');

  return currentPair;
}

/// ================= BUILD PAYLOAD =================
Map<String, dynamic> _buildPayload(
    String pair, MarketAnalysisResult analysis) {
  final candles = analysis.candles;
  final entryPrice = candles.isNotEmpty ? candles.last.close : 0.0;

  return {
    "pair": pair,
    "status": "ready",
    "canBuy": analysis.canBuy ?? false,
    "canSell": analysis.canSell ?? false,
    "bias": (analysis.biasIsBuy ?? true) ? "BUY" : "SELL",
    "entryPrice": entryPrice,
    "stopLoss": analysis.stopLoss ?? 0.0,
    "takeProfit": analysis.takeProfit ?? 0.0,
    "conditionsMet": analysis.conditionsMet ?? [],
    "failedConditions": analysis.reasonsFailed ?? [],
    "candleCount": candles.length,
    "timestamp": DateTime.now().toUtc().toIso8601String(),
  };
}

/// ================= REMOVE CLIENT =================
void _removeClient(WebSocketChannel socket, String pair) {
  _clients[pair]?.remove(socket);
  if (_clients[pair]?.isEmpty ?? false) _clients.remove(pair);

  _subscriptions[socket]?.cancel();
  _subscriptions.remove(socket);

  _heartbeats[socket]?.cancel();
  _heartbeats.remove(socket);
}

/// ================= CLEANUP =================
void _cleanup(WebSocketChannel socket, String pair) {
  print('❌ Client disconnected from /signals');
  _removeClient(socket, pair);

  try {
    socket.sink.close();
  } catch (_) {}
}