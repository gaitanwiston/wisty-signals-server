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

bool showOnlySignals = true;

/// cooldown per pair
final Map<String, DateTime> _lastSent = {};

const int cooldownSeconds = 15;

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
void main() async {
  final server = await HttpServer.bind(InternetAddress.anyIPv4, 8080);
  print('📡 SIGNAL SERVER ws://0.0.0.0:8080/signals');

  final service = MarketAnalysisService.instance;
  await service.startPairs(allPairs28);

  /// ================= ANALYSIS STREAM =================
  service.analysisStream.listen((result) {
    // ❌ FILTER: ignore weak signals
    if (!result.canBuy && !result.canSell) return;

    final last = _lastSent[result.symbol];
    if (last != null &&
        DateTime.now().difference(last).inSeconds < cooldownSeconds) {
      return;
    }

    _lastSent[result.symbol] = DateTime.now();

    print("🔥 SIGNAL ${result.symbol} "
        "${result.canBuy ? "BUY" : "SELL"}");

    _broadcastSignal(result);
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
      request.response..statusCode = 404..close();
    }
  }
}

/// ================= SOCKET =================
void _handleSocket(WebSocketChannel socket) {
  print('✅ Client connected');

  _sendAll(socket);

  _subscriptions[socket] = MarketAnalysisService.instance.analysisStream.listen(
    (_) => _sendAll(socket),
  );

  _heartbeats[socket]?.cancel();
  _heartbeats[socket] = Timer.periodic(
    const Duration(seconds: 20),
    (_) => _safeSend(socket, {"type": "ping"}),
  );

  socket.stream.listen(
    (msg) => _handleClient(socket, msg),
    onDone: () => _cleanup(socket),
    onError: (_) => _cleanup(socket),
  );
}

/// ================= CLIENT =================
void _handleClient(WebSocketChannel socket, dynamic msg) {
  try {
    final data = jsonDecode(msg);

    if (data['subscribe'] != null) {
      final pair = data['subscribe'].toString();
      _clients.putIfAbsent(pair, () => []);
      if (!_clients[pair]!.contains(socket)) {
        _clients[pair]!.add(socket);
      }
    }

    if (data['unsubscribe'] != null) {
      final pair = data['unsubscribe'].toString();
      _clients[pair]?.remove(socket);
    }

    if (data['tradeResult'] != null) {
      final t = data['tradeResult'];

      MarketAnalysisService.instance.registerTradeResult(
        pair: t['pair'],
        direction: t['direction'],
        win: t['win'],
      );
    }
  } catch (_) {}
}

/// ================= BROADCAST ONLY STRONG SIGNALS =================
void _broadcastSignal(MarketAnalysisResult result) {
  final sockets = _clients[result.symbol];
  if (sockets == null || sockets.isEmpty) return;

  final payload = {
    "symbol": result.symbol,
    "status": result.canBuy
        ? "BUY"
        : result.canSell
            ? "SELL"
            : "WAIT",
    "confidence": 100,
    "entryPrice": result.candles.isNotEmpty
        ? result.candles.last.close
        : 0.0,
    "stopLoss": result.stopLoss,
    "takeProfit": result.takeProfit,
    "timestamp": DateTime.now().toIso8601String(),
  };

  for (final s in List<WebSocketChannel>.from(sockets)) {
    _safeSend(s, payload);
  }
}

/// ================= SEND ALL =================
void _sendAll(WebSocketChannel socket) {
  final service = MarketAnalysisService.instance;
  final map = <String, dynamic>{};

  for (final pair in allPairs28) {
    final r = service.latestFor(pair);

    // ❌ IMPORTANT: DO NOT SEND WAIT SPAM
    if (r == null || (!r.canBuy && !r.canSell)) continue;

    map[pair] = {
      "symbol": r.symbol,
      "status": r.canBuy ? "BUY" : "SELL",
      "confidence": 100,
      "entryPrice": r.candles.isNotEmpty ? r.candles.last.close : 0.0,
      "stopLoss": r.stopLoss,
      "takeProfit": r.takeProfit,
    };
  }

  _safeSend(socket, map);
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

  socket.sink.close();
  print("❌ Client disconnected");
}