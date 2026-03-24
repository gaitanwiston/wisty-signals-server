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

  /// 🔥 SINGLE SOURCE OF TRUTH STREAM
  final StreamController<Map<String, dynamic>> _controller =
      StreamController.broadcast();

  Stream<Map<String, dynamic>> get wsStream => _controller.stream;

  final Map<String, List<model.Candle>> _candles = {};
  final Set<String> _subscribedTicks = {};

  bool get isConnected => _authorized && _connected;

  /// ================= CONNECT =================
  Future<void> connect([String? token]) async {
    if (_connected) return;

    final t = token ?? derivToken;
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

            /// 🔥 BROADCAST TO EVERYONE
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

    _send({"authorize": t});
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

        _send({"balance": 1, "subscribe": 1});
        _send({"active_symbols": "brief", "product_type": "basic"});
        break;

      case 'tick':
        final tick = data['tick'];
        if (tick != null) {
          final symbol = tick['symbol'].toString();
          final price =
              double.tryParse(tick['quote'].toString()) ?? 0.0;
          final epoch =
              int.tryParse(tick['epoch'].toString()) ?? 0;

          _updateCandles(symbol, price, epoch);
        }
        break;

      case 'history':
        final echo = data['echo_req'] ?? {};
        final symbol = echo['ticks_history'] ?? "unknown";

        final prices =
            data['history']['prices'] as List<dynamic>? ?? [];
        final times =
            data['history']['times'] as List<dynamic>? ?? [];

        final hist = <model.Candle>[];

        for (int i = 0; i < min(prices.length, times.length); i++) {
          final price =
              double.tryParse(prices[i].toString()) ?? 0.0;
          final epoch =
              int.tryParse(times[i].toString()) ?? 0;

          hist.add(model.Candle(
            epoch: epoch,
            open: price,
            close: price,
            high: price,
            low: price,
            volume: 1,
          ));
        }

        _candles[symbol] = hist;
        print("✅ History loaded: ${hist.length} for $symbol");
        break;

      case 'balance':
        print("💰 Balance: ${data['balance']}");
        break;
    }
  }

  /// ================= SUBSCRIBE =================
  Future<void> subscribeTicks(String symbol) async {
    if (!_connected) await connect();

    if (_subscribedTicks.contains(symbol)) return;

    _subscribedTicks.add(symbol);

    /// request history
    await _sendAndWait("history", {
      "ticks_history": symbol,
      "granularity": 60,
      "count": 200,
      "end": "latest",
    });

    /// subscribe ticks
    _send({
      "ticks": symbol,
      "subscribe": 1,
    });

    print("📡 Subscribed: $symbol");
  }

  /// ================= UPDATE CANDLES =================
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

    /// 🔥 LIMIT SIZE
    if (list.length > 500) {
      list.removeRange(0, list.length - 500);
    }
  }

  /// ================= FETCH HISTORY =================
  Future<List<model.Candle>> fetchHistoricalCandles(
      String symbol, int count, int tfSeconds) async {
    final res = await _sendAndWait("candles", {
      "ticks_history": symbol,
      "granularity": tfSeconds,
      "count": count,
      "end": "latest",
    });

    final candles = res['candles'] ?? [];

    return candles.map<model.Candle>((c) {
      return model.Candle(
        epoch: int.tryParse(c['epoch'].toString()) ?? 0,
        open: double.tryParse(c['open'].toString()) ?? 0,
        close: double.tryParse(c['close'].toString()) ?? 0,
        high: double.tryParse(c['high'].toString()) ?? 0,
        low: double.tryParse(c['low'].toString()) ?? 0,
        volume: double.tryParse(c['volume'].toString()) ?? 0,
      );
    }).toList();
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
/// ================= COMPATIBILITY METHODS =================

Future<void> subscribeCandles(String pair) async {
  await subscribeTicks(pair);
}

void subscribeContract(String pair, Function(Map<String, dynamic>) callback) {
  // simple forward of ticks
  wsStream.listen((data) {
    if (data['msg_type'] == 'tick' &&
        data['tick'] != null &&
        data['tick']['symbol'] == pair) {
      callback({
        "symbol": pair,
        "price": data['tick']['quote'],
        "epoch": data['tick']['epoch'],
      });
    }
  });
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