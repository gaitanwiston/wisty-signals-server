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

bool showOnlySignals = false; // 🔥 switch debug mode

/// ================= ALL PAIRS =================
final List<String> allPairs28 = [
  'frxEURUSD', 'frxAUDCAD', 'frxGBPUSD', 'frxUSDJPY',
  'frxUSDCAD', 'frxUSDCHF', 'frxEURGBP', 'frxEURJPY',
  'frxAUDJPY', 'frxGBPJPY', 'frxAUDUSD', 'frxNZDUSD',
  'frxUSDSGD', 'frxUSDHKD', 'frxEURAUD', 'frxEURCAD',
  'frxGBPAUD', 'frxGBPCHF', 'frxNZDJPY', 'frxCHFJPY',
  'frxCADJPY', 'frxAUDNZD', 'frxGBPNZD', 'frxEURCHF',
  'frxUSDNOK', 'frxUSDSEK', 'frxUSDZAR', 'frxUSDMXN'
];

/// ================= ENTRY POINT =================
void main() async {
  final server = await HttpServer.bind(InternetAddress.anyIPv4, 8080);
  print('📡 Signals WebSocket server running on ws://0.0.0.0:8080/signals');

  /// 🔥 START MARKET ANALYSIS (ONLY ONCE)
  final service = MarketAnalysisService.instance;
  print("🚀 Starting Market Analysis...");
  await service.startPairs(allPairs28);

  /// 🔥 CLEAN ANALYSIS DEBUG
  service.analysisStream.listen((result) {
    if (showOnlySignals) {
      if (!result.canBuy && !result.canSell) return;
    }

    print("📊 ${result.symbol} "
        "BUY=${result.canBuy} SELL=${result.canSell} "
        "candles=${result.candles.length} "
        "Reason=${result.reasonsFailed}");

    _broadcastUpdate(result.symbol);
  });

  /// ================= SERVER LOOP =================
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
  print('📡 Client connected');

  _sendAllPairsLatest(socket);

  final sub = MarketAnalysisService.instance.analysisStream.listen(
    (_) => _sendAllPairsLatest(socket),
    onError: (err) => print("⚠ Analysis stream error: $err"),
  );

  _subscriptions[socket] = sub;

  /// 🔥 HEARTBEAT
  _heartbeats[socket]?.cancel();
  _heartbeats[socket] = Timer.periodic(
    const Duration(seconds: 15),
    (_) {
      try {
        if (socket.closeCode == null) {
          socket.sink.add(jsonEncode({
            "type": "ping",
            "timestamp": DateTime.now().toUtc().toIso8601String()
          }));
        } else {
          _cleanup(socket);
        }
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

/// ================= HANDLE CLIENT =================
void _handleClientMessage(WebSocketChannel socket, dynamic msg) {
  if (msg == 'ping') {
    try {
      socket.sink.add(jsonEncode({"type": "pong"}));
    } catch (_) {
      _cleanup(socket);
    }
    return;
  }

  try {
    final data = jsonDecode(msg);
    if (data['subscribe'] != null) {
      final pair = data['subscribe'].toString();
      print('📩 Client subscribed: $pair');
      _clients.putIfAbsent(pair, () => []).add(socket);
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

  print("📨 Sending update (${payload.length} pairs)");
  _sendSafe(socket, payload);
}

/// ================= BROADCAST =================
void _broadcastUpdate(String pair) {
  final sockets = _clients[pair];
  if (sockets == null) return;

  final result = MarketAnalysisService.instance.latestFor(pair);
  if (result == null) return;

  final payload = _buildPayload(result);

  for (var socket in sockets) {
    _sendSafe(socket, payload);
  }
}

/// ================= BUILD PAYLOAD =================
Map<String, dynamic> _buildPayload(MarketAnalysisResult analysis) {
  final candles = analysis.candles;
  final entryPrice = candles.isNotEmpty ? candles.last.close : 0.0;

  return {
    "symbol": analysis.symbol,
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

/// ================= EMPTY =================
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

  _clients.forEach((_, list) => list.remove(socket));

  try {
    socket.sink.close();
  } catch (_) {}

  print('❌ Client disconnected');
}