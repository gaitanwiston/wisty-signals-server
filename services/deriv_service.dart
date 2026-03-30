import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:web_socket_channel/web_socket_channel.dart';
import '../models/candle.dart' as model;

/// ================= CONFIG =================
const String derivToken = "5Q0tS24UGTwKvDX";
const int derivAppId = 90453;

class DerivService {
  // ================= SINGLETON =================
  static final DerivService instance = DerivService._internal();
  factory DerivService() => instance;
  DerivService._internal();

  WebSocketChannel? _channel;
  StreamSubscription? _wsSub;

  bool _authorized = false;
  bool _connected = false;

  final StreamController<Map<String, dynamic>> _controller =
      StreamController.broadcast();

  Stream<Map<String, dynamic>> get wsStream => _controller.stream;

  final Map<String, List<model.Candle>> _candles = {};
  final Set<String> _subscribed = {};

  bool get isConnected => _authorized && _connected;

  /// ================= CONNECT =================
  Future<void> connect([String? token]) async {
    if (_connected) return;

    final uri = Uri.parse(
        "wss://ws.derivws.com/websockets/v3?app_id=$derivAppId");

    print("🔌 Connecting to Deriv...");

    _channel = WebSocketChannel.connect(uri);
    _connected = true;

    _wsSub = _channel!.stream.listen(
      (msg) {
        try {
          final data = jsonDecode(msg);

          if (data is Map<String, dynamic>) {
            _handleMessage(data);
            _controller.add(data);
          }
        } catch (e) {
          print("⚠ WS parse error: $e");
        }
      },
      onError: (err) {
        print("⚠ WS error: $err");
        _reconnect();
      },
      onDone: () {
        print("⚠ WS closed");
        _reconnect();
      },
    );

    _send({"authorize": token ?? derivToken});
    print("📨 Authorization sent");
  }

  /// ================= HANDLE WS =================
  void _handleMessage(Map<String, dynamic> data) {
    final type = data['msg_type'];
    print("📩 WS message: $type");

    switch (type) {
      case 'authorize':
        _authorized = true;
        print("✅ Authorized");
        break;

      /// 🔥 REAL CANDLES
      case 'candles':
        final echo = data['echo_req'] ?? {};
        final symbol = echo['ticks_history'];

        final candles = data['candles'] ?? [];
        final list = <model.Candle>[];

        for (final c in candles) {
          list.add(model.Candle(
            epoch: int.tryParse(c['epoch'].toString()) ?? 0,
            open: double.tryParse(c['open'].toString()) ?? 0,
            close: double.tryParse(c['close'].toString()) ?? 0,
            high: double.tryParse(c['high'].toString()) ?? 0,
            low: double.tryParse(c['low'].toString()) ?? 0,
            volume: double.tryParse(c['volume'].toString()) ?? 0,
          ));
        }

        _candles[symbol] = list;

        print("✅ REAL candles loaded: ${list.length} for $symbol");
        break;

      /// 🔥 LIVE TICK UPDATE
      case 'tick':
        final tick = data['tick'];
        if (tick != null) {
          final symbol = tick['symbol'];
          final price =
              double.tryParse(tick['quote'].toString()) ?? 0.0;
          final epoch =
              int.tryParse(tick['epoch'].toString()) ?? 0;

          _updateCandles(symbol, price, epoch);
        }
        break;

      case 'balance':
        print("💰 Balance: ${data['balance']}");
        break;
    }
  }

  /// ================= SUBSCRIBE =================
  Future<void> subscribeTicks(String symbol) async {
    if (!_connected) await connect();

    if (_subscribed.contains(symbol)) return;
    _subscribed.add(symbol);

    /// 🔥 GET REAL HISTORY (IMPORTANT)
    await _sendAndWait("candles", {
      "ticks_history": symbol,
      "style": "candles",
      "granularity": 60,
      "count": 5000,
      "end": "latest",
    });

    /// 🔥 LIVE STREAM
    _send({
      "ticks": symbol,
      "subscribe": 1,
    });

    print("📡 Subscribed: $symbol");
  }

  /// ================= UPDATE LIVE =================
  void _updateCandles(String symbol, double price, int epoch) {
    final list = _candles.putIfAbsent(symbol, () => []);

    final bucket = (epoch ~/ 60) * 60;

    if (list.isEmpty || list.last.epoch != bucket) {
      final open = list.isNotEmpty ? list.last.close : price;

      list.add(model.Candle(
        epoch: bucket,
        open: open,
        close: price,
        high: max(open, price),
        low: min(open, price),
        volume: 1,
      ));
    } else {
      final last = list.last;

      list[list.length - 1] = model.Candle(
        epoch: last.epoch,
        open: last.open,
        close: price,
        high: max(last.high, price),
        low: min(last.low, price),
        volume: last.volume + 1,
      );
    }

    /// LIMIT SIZE
    if (list.length > 10000) {
      list.removeRange(0, list.length - 10000);
    }
  }

  /// ================= GET CANDLES =================
  Future<List<model.Candle>> getCandles(String pair,
      {int timeframe = 1}) async {
    return _candles[pair] ?? [];
  }

  /// ================= SEND =================
  void _send(Map<String, dynamic> data) {
    _channel?.sink.add(jsonEncode(data));
  }

  /// ================= SEND & WAIT =================
  Future<Map<String, dynamic>> _sendAndWait(
      String type, Map<String, dynamic> data,
      {int timeout = 10}) async {
    final completer = Completer<Map<String, dynamic>>();
    late StreamSubscription sub;

    sub = _controller.stream.listen((event) {
      if (event['msg_type'] == type && !completer.isCompleted) {
        completer.complete(event);
        sub.cancel();
      }
    });

    _send(data);

    Future.delayed(Duration(seconds: timeout), () {
      if (!completer.isCompleted) {
        completer.complete({});
        sub.cancel();
      }
    });

    return completer.future;
  }

  /// ================= COMPATIBILITY =================
  Future<void> subscribeCandles(String pair) async {
    await subscribeTicks(pair);
  }

  List<model.Candle> getCachedCandles(String pair) {
    return _candles[pair] ?? [];
  }

  /// ================= RECONNECT =================
  Future<void> _reconnect() async {
    _connected = false;
    _authorized = false;

    await _channel?.sink.close();
    await Future.delayed(const Duration(seconds: 2));

    print("🔁 Reconnecting...");
    await connect();
  }
}