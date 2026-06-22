import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:web_socket_channel/io.dart';

import '../services/market_analysis_service.dart';
import '../models/market_analysis_result.dart';

/// ================= GLOBAL STATE =================
final Map<String, List<WebSocketChannel>> _clients = {};
final Map<WebSocketChannel, StreamSubscription> _subscriptions = {};
final Map<WebSocketChannel, Timer> _heartbeats = {};
final Map<String, DateTime> _lastSent = {};

const int cooldownSeconds = 3;

/// ================= PAIRS =================
final List<String> allPairs28 = [
  'frxEURUSD','frxAUDCAD','frxGBPUSD','frxUSDJPY',
  'frxUSDCAD','frxUSDCHF','frxEURGBP','frxEURJPY',
  'frxAUDJPY','frxGBPJPY','frxAUDUSD','frxNZDUSD',
  'frxEURAUD','frxEURCAD','frxGBPAUD','frxGBPCHF',
  'frxNZDJPY','frxCHFJPY','frxCADJPY','frxAUDNZD',
  'frxGBPNZD','frxEURCHF','frxUSDNOK','frxUSDSEK',
  'frxUSDZAR','frxUSDMXN'
];

/// ================= MAIN =================
Future<void> main() async {
  final server = await HttpServer.bind(InternetAddress.anyIPv4, 8080);
  print('📡 WISTY SIGNAL SERVER ws://0.0.0.0:8080/signals');

  final service = MarketAnalysisService.instance;

  await service.startPairs(allPairs28);
  service.startPeriodicAnalysis(allPairs28);

  /// SINGLE STREAM (NO DUPLICATION)
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
  final last = _lastSent[result.symbol];

  if (last != null &&
      DateTime.now().difference(last).inSeconds < cooldownSeconds) {
    return;
  }

  _lastSent[result.symbol] = DateTime.now();

  print("🔥 SIGNAL ${result.symbol} "
      "${result.canBuy ? "BUY" : result.canSell ? "SELL" : "WAIT"}");

  _broadcastSignal(result);
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
      final pair = subscribe.toString();
      if (!allPairs28.contains(pair)) return;

      _clients.putIfAbsent(pair, () => []);
      if (!_clients[pair]!.contains(socket)) {
        _clients[pair]!.add(socket);
      }
    }

    if (unsubscribe != null) {
      final pair = unsubscribe.toString();
      _clients[pair]?.remove(socket);
    }
  } catch (_) {}
}

/// ================= UPDATE =================
void _sendUpdate(WebSocketChannel socket, MarketAnalysisResult result) {
  final sockets = _clients[result.symbol];
  if (sockets == null || !sockets.contains(socket)) return;

  _safeSend(socket, {
    "type": "update",
    "symbol": result.symbol,
    "direction": result.canBuy
        ? "BUY"
        : result.canSell
            ? "SELL"
            : "WAIT",
    "confidence": result.indicators["confidence"] ?? 0,
    "buyScore": result.indicators["buy"] ?? 0,
    "sellScore": result.indicators["sell"] ?? 0,
    "timestamp": DateTime.now().toUtc().toIso8601String(),
  });
}

/// ================= BROADCAST =================
void _broadcastSignal(MarketAnalysisResult result) {
  final sockets = _clients[result.symbol];
  if (sockets == null || sockets.isEmpty) return;

  final confidence = (result.indicators["confidence"] ?? 0).toDouble();

  final payload = {
    "type": "signal",
    "symbol": result.symbol,
    "direction": result.canBuy
        ? "BUY"
        : result.canSell
            ? "SELL"
            : "WAIT",
    "confidence": confidence,
    "entry": result.risk.entry,
    "stopLoss": result.risk.stopLoss,
    "takeProfit": result.risk.takeProfit,
    "ui": {
      "tradeEnabled": confidence >= 75,
      "autoExecute": confidence >= 80,
      "buttonState": confidence >= 75 ? "ACTIVE" : "FROZEN",
    },
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
    final r = service.latestFor(pair);
    if (r == null) continue;

    snapshot[pair] = {
      "symbol": r.symbol,
      "direction": r.canBuy
          ? "BUY"
          : r.canSell
              ? "SELL"
              : "WAIT",
      "confidence": r.indicators["confidence"] ?? 0,
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

  for (final e in _clients.entries) {
    e.value.remove(socket);
  }

  try {
    socket.sink.close();
  } catch (_) {}

  print("❌ Client disconnected");
}