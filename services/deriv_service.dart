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
  final Map<String, bool> _ready = {};

  final StreamController<Map<String, dynamic>> _stream =
      StreamController.broadcast();

  Stream<Map<String, dynamic>> get wsStream => _stream.stream;
  bool get isConnected => _connected && _auth;

  Timer? _keepAlive;

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
        try {
          final data = jsonDecode(msg);

          if (data is Map<String, dynamic>) {
            _handle(data);
            _stream.add(data);
          }
        } catch (e) {
          print("❌ WS decode error: $e");
        }
      },
      onDone: _reconnect,
      onError: (e) {
        print("❌ WS error: $e");
        _reconnect();
      },
      cancelOnError: true,
    );

    _send({"authorize": token ?? derivToken});
    _send({"active_symbols": "brief"}); // 🔥 IMPORTANT FIX
    _startKeepAlive();
  }

  // ================= KEEP ALIVE =================
  void _startKeepAlive() {
    _keepAlive?.cancel();

    _keepAlive = Timer.periodic(const Duration(seconds: 20), (_) {
      if (_connected) _send({"ping": 1});
    });
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

      final symbol = normalizeSymbol(echo["ticks_history"] ?? "");
      if (symbol.isEmpty) return;

      final gran = echo["granularity"] ?? 60;
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

      _stream.add({
        "type": "candles_update",
        "symbol": symbol,
        "tf": tf.name,
        "length": parsed.length,
      });

      print("📊 [$symbol] [$tf] candles updated: ${parsed.length}");
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

  // ================= BUILD (FIXED FOR SYNTHETIC) =================
  void _buildAll(String symbol) {
    final m1 = _data[symbol]?[TF.m1] ?? [];
    final h4raw = _data[symbol]?[TF.h4] ?? [];
    final d1raw = _data[symbol]?[TF.d1] ?? [];

    if (m1.isEmpty && h4raw.isEmpty && d1raw.isEmpty) {
      _ready[symbol] = false;
      return;
    }

    // 🔥 SAFE FALLBACK BUILD
    if (m1.length >= 10) {
      _data[symbol]![TF.h1] = _aggregate(m1, 60);
      _data[symbol]![TF.h4] = _aggregate(m1, 240);
      _data[symbol]![TF.d1] = _aggregate(m1, 1440);
      _data[symbol]![TF.w1] = _aggregate(m1, 10080);
    }

    // 🔥 fallback if M1 is weak (CRITICAL FOR 1HZ / R_ / JD)
    if (m1.length < 10 && h4raw.isNotEmpty) {
      _data[symbol]![TF.h1] = h4raw;
      _data[symbol]![TF.h4] = h4raw;
      _data[symbol]![TF.d1] = d1raw;
    }

    _ready[symbol] =
        (_data[symbol]![TF.h1]?.isNotEmpty ?? false) ||
        (_data[symbol]![TF.h4]?.isNotEmpty ?? false);

    if (_ready[symbol] == true) {
      _stream.add({
        "type": "data_ready",
        "symbol": symbol,
      });
    }
  }

  // ================= AGGREGATION =================
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

  // ================= SUBSCRIBE (FIXED FOR SYNTHETIC) =================
  Future<void> subscribeCandles(String symbol) async {
    if (!_connected) await connect();

    final s = normalizeSymbol(symbol);

    if (_subscribed.contains(s)) return;
    _subscribed.add(s);

    _init(s);

    // 🔥 WARMUP CALLS (IMPORTANT FIX)
    _sendCandles(s, 60);
    await Future.delayed(const Duration(milliseconds: 200));

    _sendCandles(s, 3600);
    await Future.delayed(const Duration(milliseconds: 200));

    _sendCandles(s, 14400);
    await Future.delayed(const Duration(milliseconds: 200));

    _sendCandles(s, 86400);

    // 🔥 synthetic boost trigger
    if (isSynthetic(s)) {
      await Future.delayed(const Duration(milliseconds: 300));
      _sendCandles(s, 60);
    }

    _send({"ticks": s, "subscribe": 1});

    print("📡 Subscribed FULL TF: $s");
  }

  void _sendCandles(String symbol, int granularity) {
    _send({
      "ticks_history": symbol,
      "style": "candles",
      "granularity": granularity,
      "end": "latest",
      "count": 5000,
      "adjust_start_time": 1
    });
  }

  // ================= SYNTHETIC DETECTION =================
  bool isSynthetic(String symbol) {
    return symbol.startsWith("R_") ||
        symbol.startsWith("1HZ") ||
        symbol.startsWith("BOOM") ||
        symbol.startsWith("CRASH") ||
        symbol.startsWith("JD") ||
        symbol.startsWith("stpRNG");
  }

  // ================= GET =================
  List<model.Candle> getCandles(String symbol, TF tf) {
    final s = normalizeSymbol(symbol);
    return _data[s]?[tf] ?? [];
  }

  bool isReady(String symbol) {
    final m1 = _data[symbol]?[TF.m1]?.length ?? 0;
    final h1 = _data[symbol]?[TF.h1]?.length ?? 0;
    final h4 = _data[symbol]?[TF.h4]?.length ?? 0;

    return (m1 >= 10 || h4 >= 10) && h1 >= 5;
  }

  // ================= SEND =================
  void _send(Map<String, dynamic> d) {
    try {
      _channel?.sink.add(jsonEncode(d));
    } catch (e) {
      print("❌ send error: $e");
    }
  }

  // ================= RECONNECT =================
  Future<void> _reconnect() async {
    print("🔁 Reconnecting Deriv...");

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

  // ================= NORMALIZE =================
  String normalizeSymbol(String raw) {
    return raw.trim().toUpperCase();
  }
}