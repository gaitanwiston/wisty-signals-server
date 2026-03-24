import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:web_socket_channel/io.dart';

import '../services/market_analysis_service.dart';
import '../services/deriv_service.dart';
import '../models/models.dart';

/// ================= GLOBALS =================
final Map<String, List<WebSocketChannel>> _clients = {};
final Map<WebSocketChannel, StreamSubscription> _subscriptions = {};
final Map<WebSocketChannel, Timer> _heartbeats = {};

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

  // Start Market Analysis and Deriv tick subscription
  final service = MarketAnalysisService.instance;
  print("🚀 Starting Market Analysis for all pairs...");
  await service.startPairs(allPairs28);

  // Listen for analysis updates
  service.analysisStream.listen((result) {
    print("📊 Analysis Update: ${result.symbol} BUY=${result.canBuy} SELL=${result.canSell} candles=${result.candles.length}");
    _broadcastUpdate(result.symbol);
  });

  // Subscribe to Deriv tick streams and print real-time candle updates
  final deriv = DerivService.instance;
  await deriv.connect();
  for (var pair in allPairs28) {
    await deriv.subscribeCandles(pair);
    print("📩 Subscribed to candles for $pair");

    deriv.subscribeContract(pair, (data) {
      final price = (data['price'] ?? 0).toDouble();
      final epoch = (data['epoch'] ?? 0) as int;
      print("💹 Tick: $pair price=$price epoch=$epoch");

      final candles = deriv.getCachedCandles(pair);
      if (candles.isNotEmpty) {
        final last = candles.last;
        print("🕒 Last candle for $pair: open=${last.open}, close=${last.close}, high=${last.high}, low=${last.low}, volume=${last.volume}");
      }
    });
  }

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

  // Send current data immediately
  _sendAllPairsLatest(socket);

  // Subscribe to live analysis updates
  final sub = MarketAnalysisService.instance.analysisStream.listen(
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
    payload[pair] = result != null ? _buildPayload(result) : _emptyPayload(pair);
  }

  print("📨 Sending payload to client: ${jsonEncode(payload)}");
  _sendSafe(socket, payload);
}

/// ================= BROADCAST SINGLE PAIR =================
void _broadcastUpdate(String pair) {
  final sockets = _clients[pair];
  if (sockets == null) return;
  final service = MarketAnalysisService.instance;
  final result = service.latestFor(pair);
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

/// ================= SEND SAFE =================
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