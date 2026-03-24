import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:web_socket_channel/web_socket_channel.dart';
import '../models/candle.dart' as model;

/// ================= CONFIG =================
const String derivToken = "5Q0tS24UGTwKvDX";
const int derivAppId = 90453;
const double defaultStake = 10.0;

/// ================= MODELS =================
class Pair {
  final String symbol;
  final String displayName;
  final String type;

  Pair({
    required this.symbol,
    required this.displayName,
    required this.type,
  });
}

/// ================= DERIV SERVICE =================
class DerivService {
  static final DerivService instance = DerivService._internal();
  factory DerivService() => instance;
  DerivService._internal();

  WebSocketChannel? _channel;
  late Stream<dynamic> _wsStream;
  StreamSubscription? _wsSub;
  bool _authorized = false;
  bool _connected = false;

  final Map<String, String> _symbolMap = {};
  final Map<String, List<model.Candle>> _candles = {};
  final Set<String> _subscribedTicks = {};
  final Map<String, Map<String, dynamic>> openTrades = {};
  final Map<String, StreamController<Map<String, dynamic>>> _contractStreams = {};

  bool get isConnected => _authorized && _channel != null && _connected;

  /// ================= CONNECT =================
  Future<void> connect([String? token]) async {
    if (_connected) return;
    final t = token ?? derivToken;
    final uri = Uri.parse("wss://ws.derivws.com/websockets/v3?app_id=$derivAppId");
    print("🔌 Connecting to Deriv at $uri...");
    _channel = WebSocketChannel.connect(uri);
    _connected = true;

    _wsStream = _channel!.stream.asBroadcastStream();

    _wsSub = _wsStream.listen(
      (msg) {
        try {
          final data = jsonDecode(msg);
          if (data is Map<String, dynamic>) _handleMessage(data);
        } catch (e) {
          print("⚠ WS msg parse error: $e");
        }
      },
      onError: (err) {
        print("⚠ WS error: $err");
        _scheduleReconnect();
      },
      onDone: () {
        print("⚠ WS done");
        _scheduleReconnect();
      },
    );

    _send({"authorize": t});
    print("📨 Authorization sent");
  }
void _handleMessage(Map<String, dynamic> data) {
  final type = data['msg_type'];
  print("📩 WS message received: $type");

  switch (type) {
    case 'authorize':
      _authorized = true;
      print("✅ Authorized with Deriv");
      _send({"balance": 1, "subscribe": 1});
      _send({"active_symbols": "brief", "product_type": "basic"});
      break;

    case 'active_symbols':
      final raw = data['active_symbols'];
      if (raw is List) {
        _symbolMap.clear();
        for (final e in raw) {
          if (e['market'] == 'forex' && e['symbol'] != null) {
            final actual = e['symbol'].toString();
            _symbolMap[actual] = actual;
          }
        }
        print("ℹ Loaded symbols: ${_symbolMap.keys.length}");
      }
      break;

    case 'tick':
      final tick = data['tick'];
      if (tick != null) {
        final symbol = tick['symbol'].toString();
        final price = double.tryParse(tick['quote'].toString()) ?? 0.0;
        final epoch = int.tryParse(tick['epoch'].toString()) ?? 0;
        _addTickToCandles(symbol, price, epoch);

        _contractStreams.forEach((id, ctrl) {
          ctrl.add({"contract_id": id, "price": price, "epoch": epoch});
        });
      }
      break;

    case 'balance':
      print("💰 Balance update received: ${data['balance']}");
      break;

    case 'history': // <--- HANDLE HISTORY
      final echo = data['echo_req'] ?? {};
      final symbol = echo['ticks_history'] ?? "unknown";
      final prices = data['history']['prices'] as List<dynamic>? ?? [];
      final times = data['history']['times'] as List<dynamic>? ?? [];

      final histCandles = <model.Candle>[];
      for (int i = 0; i < min(prices.length, times.length); i++) {
        histCandles.add(model.Candle(
          epoch: times[i] is int ? times[i] : int.tryParse(times[i].toString()) ?? 0,
          open: prices[i] is double ? prices[i] : double.tryParse(prices[i].toString()) ?? 0.0,
          close: prices[i] is double ? prices[i] : double.tryParse(prices[i].toString()) ?? 0.0,
          high: prices[i] is double ? prices[i] : double.tryParse(prices[i].toString()) ?? 0.0,
          low: prices[i] is double ? prices[i] : double.tryParse(prices[i].toString()) ?? 0.0,
          volume: 1,
        ));
      }

      _candles[symbol] = histCandles;
      print("✅ Historical candles loaded: ${histCandles.length} for $symbol");
      break;

    default:
      print("⚠ Unknown WS message: $data");
  }
}
  /// ================= CANDLES =================
  Future<void> subscribeCandles(String pair, {int timeframeMinutes = 1}) async {
    if (!_connected) await connect();
    if (!_subscribedTicks.contains(pair)) {
      _subscribedTicks.add(pair);
      _send({"ticks": pair, "subscribe": 1});
      _candles[pair] = await _fetchHistoricalCandles(pair, timeframeMinutes);
      print("ℹ Historical candles for $pair loaded: ${_candles[pair]?.length}");
    }
  }

  Future<List<model.Candle>> _fetchHistoricalCandles(String symbol, int tfMinutes) async {
    final res = await _sendAndWait(
      "candles",
      {
        "ticks_history": symbol,
        "granularity": tfMinutes * 60,
        "count": 200,
        "end": "latest",
      },
      timeoutSeconds: 15,
    );

    final ticks = res['candles'] ?? [];
    return ticks.map<model.Candle>((c) => model.Candle(
      epoch: int.tryParse(c['epoch'].toString()) ?? 0,
      open: double.tryParse(c['open'].toString()) ?? 0.0,
      close: double.tryParse(c['close'].toString()) ?? 0.0,
      high: double.tryParse(c['high'].toString()) ?? 0.0,
      low: double.tryParse(c['low'].toString()) ?? 0.0,
      volume: double.tryParse(c['volume'].toString()) ?? 0.0,
    )).toList();
  }

  List<model.Candle> getCachedCandles(String pair) => _candles[pair] ?? [];

  /// ================= PUBLIC WRAPPERS =================
  Future<List<model.Candle>> fetchHistoricalCandles(String symbol, int count, int tfSeconds) async {
    return _fetchHistoricalCandles(symbol, tfSeconds ~/ 60);
  }

  Future<void> subscribeTicks(String symbol) async {
    await subscribeCandles(symbol, timeframeMinutes: 1);
  }

  /// ================= TICKS =================
  void _addTickToCandles(String symbol, double price, int epoch) {
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
  }

  /// ================= SUBSCRIBE CONTRACT =================
  void subscribeContract(String pair, void Function(Map<String, dynamic>) callback) {
    final ctrl = _contractStreams.putIfAbsent(pair, () => StreamController<Map<String, dynamic>>.broadcast());
    ctrl.stream.listen(callback);
  }

  /// ================= UTILS =================
  void _send(Map<String, dynamic> data) {
    final jsonData = jsonEncode(data);
    _channel?.sink.add(jsonData);
  }

  Future<Map<String, dynamic>> _sendAndWait(String type, Map<String, dynamic> data, {int timeoutSeconds = 10}) async {
    final completer = Completer<Map<String, dynamic>>();
    late StreamSubscription sub;

    sub = _wsStream.listen((msg) {
      try {
        final decoded = jsonDecode(msg);
        if (decoded is Map<String, dynamic> && decoded['msg_type'] == type && !completer.isCompleted) {
          completer.complete(decoded);
          sub.cancel();
        }
      } catch (_) {}
    });

    _send(data);

    Future.delayed(Duration(seconds: timeoutSeconds), () {
      if (!completer.isCompleted) {
        completer.complete({});
        sub.cancel();
      }
    });

    return completer.future;
  }

  /// ================= WS STREAM GETTER =================
  Stream<dynamic> get wsStream => _wsStream;

  /// ================= RECONNECT =================
  void _scheduleReconnect() async {
    _connected = false;
    _authorized = false;
    await _channel?.sink.close();
    await Future.delayed(const Duration(seconds: 2));
    await connect();
  }
}