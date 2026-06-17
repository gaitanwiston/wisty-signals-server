import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:web_socket_channel/web_socket_channel.dart';
import '../models/candle.dart' as model;

const String derivToken =
    "pat_0fccfffc5d1eaace805fb961cd606399a8665f15e6e40da9cdd313a67ac8ec08";
const int derivAppId = 1089;

enum TF { m1, h1, h4, d1, w1, mn }

class DerivService {
  static final DerivService instance = DerivService._internal();
  DerivService._internal();

  WebSocketChannel? _channel;
  StreamSubscription? _sub;

  bool _connected = false;
  bool _auth = false;

  final Map<String, Map<TF, List<model.Candle>>> _data = {};
  final Set<String> _subscribed = {};

  /// 🔥 READY STATE (IMPORTANT FIX)
  final Map<String, bool> _ready = {};

  final StreamController<Map<String, dynamic>> _stream =
      StreamController.broadcast();

  Stream<Map<String, dynamic>> get wsStream => _stream.stream;
  bool get isConnected => _connected && _auth;

  // ================= CONNECT =================
  Future<void> connect([String? token]) async {
    if (_connected) return;

    final uri =
        Uri.parse("wss://ws.derivws.com/websockets/v3?app_id=$derivAppId");

    print("🔌 Connecting Deriv...");
    _channel = WebSocketChannel.connect(uri);
    _connected = true;

    _sub = _channel!.stream.listen(
      (msg) {
        final data = jsonDecode(msg);
        if (data is Map<String, dynamic>) {
          _handle(data);
          _stream.add(data);
        }
      },
      onDone: _reconnect,
      onError: (_) => _reconnect(),
    );

    _send({"authorize": token ?? derivToken});
  }

  // ================= HANDLE =================
  void _handle(Map<String, dynamic> data) {
    final type = data["msg_type"];

    if (type == "authorize") {
      _auth = true;
      print("✅ Authorized");
    }

    final candles = data["candles"];
    if (candles is List) {
      final echo = data["echo_req"] ?? {};
      final symbol = echo["ticks_history"] ?? "";
      final gran = echo["granularity"] ?? 60;

      if (symbol.isEmpty) return;

      final tf = _mapTF(gran);

      final parsed = candles.map<model.Candle>((c) {
        return model.Candle(
          epoch: c["epoch"],
          open: (c["open"] ?? 0).toDouble(),
          close: (c["close"] ?? 0).toDouble(),
          high: (c["high"] ?? 0).toDouble(),
          low: (c["low"] ?? 0).toDouble(),
          volume: (c["volume"] ?? 0).toDouble(),
        );
      }).toList();

      _set(symbol, tf, parsed);

      print("📊 Loaded [$tf] ${parsed.length} candles for $symbol");
    }
  }

  // ================= INIT =================
  void _init(String symbol) {
    _data.putIfAbsent(symbol, () => {
          TF.m1: [],
          TF.h1: [],
          TF.h4: [],
          TF.d1: [],
          TF.w1: [],
          TF.mn: [],
        });
  }

  void _set(String symbol, TF tf, List<model.Candle> c) {
    _init(symbol);
    _data[symbol]![tf] = List.from(c);

    _buildAll(symbol);
  }

  // ================= BUILD (FIXED LOGIC) =================
  void _buildAll(String symbol) {
    final m1 = _data[symbol]![TF.m1] ?? [];

    /// 🔥 REQUIRE MINIMUM DATA BEFORE BUILDING
    if (m1.length < 200) {
      _ready[symbol] = false;
      return;
    }

    _data[symbol]![TF.h1] = _aggregate(m1, 60);
    _data[symbol]![TF.h4] = _aggregate(m1, 240);
    _data[symbol]![TF.d1] = _aggregate(m1, 1440);
    _data[symbol]![TF.w1] = _aggregate(m1, 10080);

    _ready[symbol] = true;
  }

  // ================= SMART AGGREGATION =================
  List<model.Candle> _aggregate(List<model.Candle> base, int sec) {
    final out = <model.Candle>[];

    for (final c in base) {
      final bucket = (c.epoch ~/ sec) * sec;

      if (out.isEmpty || out.last.epoch != bucket) {
        out.add(c);
      } else {
        final last = out.last;

        out[out.length - 1] = model.Candle(
          epoch: last.epoch,
          open: last.open,
          close: c.close,
          high: max(last.high, c.high),
          low: min(last.low, c.low),
          volume: last.volume + c.volume,
        );
      }
    }

    return out;
  }

  // ================= SUBSCRIBE =================
  Future<void> subscribeCandles(String symbol) async {
    if (!_connected) await connect();
    if (_subscribed.contains(symbol)) return;

    _subscribed.add(symbol);
    _init(symbol);

    _send({
      "ticks_history": symbol,
      "style": "candles",
      "granularity": 60,
      "end": "latest",
      "count": 5000000
    });

    _send({
      "ticks": symbol,
      "subscribe": 1,
    });

    print("📡 Subscribed (stream + history): $symbol");
  }

  // ================= GET =================
  List<model.Candle> getCandles(String symbol, TF tf) {
    return _data[symbol]?[tf] ?? [];
  }

  bool isReady(String symbol) => _ready[symbol] ?? false;

  // ================= SEND =================
  void _send(Map<String, dynamic> d) {
    _channel?.sink.add(jsonEncode(d));
  }

  // ================= RECONNECT =================
  Future<void> _reconnect() async {
    _connected = false;
    _auth = false;

    await Future.delayed(const Duration(seconds: 2));
    await connect();
  }

  // ================= MAP TF =================
  TF _mapTF(int g) {
    switch (g) {
      case 60:
        return TF.m1;
      case 3600:
        return TF.h1;
      case 14400:
        return TF.h4;
      case 86400:
        return TF.d1;
      case 604800:
        return TF.w1;
      case 2592000:
        return TF.mn;
      default:
        return TF.m1;
    }
  }
}