import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'dart:io';

/// ================= CONFIG =================
const String derivToken = "5Q0tS24UGTwKvDX";
const int derivAppId = 90453;
const double defaultStake = 10.0;

/// ================= MODELS =================
class Candle {
  final int epoch;
  final double open;
  final double close;
  final double high;
  final double low;
  final double volume;

  Candle({
    required this.epoch,
    required this.open,
    required this.close,
    required this.high,
    required this.low,
    required this.volume,
  });
}

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

  final Map<String, String> _symbolMap = {}; // normalized -> actual
  final Map<String, List<Candle>> _candles = {};
  final Set<String> _subscribedTicks = {};
  final Map<String, Map<String, dynamic>> openTrades = {};
  final Map<String, StreamController<Map<String, dynamic>>> _contractStreams = {};

  bool get isConnected => _authorized && _channel != null && _connected;

  /// ================= CONNECT =================
  Future<void> connect([String? token]) async {
    if (_connected) return;
    final t = token ?? derivToken;
    final uri = Uri.parse("wss://ws.derivws.com/websockets/v3?app_id=$derivAppId");
    _channel = WebSocketChannel.connect(uri);
    _connected = true;

    _wsStream = _channel!.stream.asBroadcastStream();

    _wsSub = _wsStream.listen(
      (msg) {
        try {
          final data = jsonDecode(msg);
          if (data is Map<String, dynamic>) _handleMessage(data);
        } catch (_) {}
      },
      onError: (_) => _scheduleReconnect(),
      onDone: _scheduleReconnect,
    );

    _send({"authorize": t});
  }

  void _handleMessage(Map<String, dynamic> data) {
    final type = data['msg_type'];
    switch (type) {
      case 'authorize':
        _authorized = true;
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
              final norm = _normalize(actual);
              _symbolMap[norm] = actual;
            }
          }
        }
        break;
      case 'tick':
        final tick = data['tick'];
        if (tick != null) {
          final symbol = _normalize(tick['symbol']);
          final price = (tick['quote'] ?? 0).toDouble();
          final epoch = tick['epoch'] ?? 0;
          _addTickToCandles(symbol, price, epoch);

          // notify contract streams
          _contractStreams.forEach((id, ctrl) {
            ctrl.add({"contract_id": id, "price": price, "epoch": epoch});
          });
        }
        break;
      case 'balance':
        // handled in getBalance
        break;
    }
  }

  /// ================= CANDLES =================
  Future<void> subscribeCandles(String pair, {int timeframeMinutes = 1}) async {
    if (!_connected) await connect();
    final norm = _normalize(pair);
    if (!_subscribedTicks.contains(norm)) {
      _subscribedTicks.add(norm);
      final actual = _symbolMap[norm] ?? norm;
      _send({"ticks": actual, "subscribe": 1});
    }
  }

  /// PUBLIC: safe access to cached candles
  List<Candle> getCachedCandles(String pair) {
    return _candles[_normalize(pair)] ?? [];
  }

  Future<List<Candle>> getCandles(String pair, {int timeframe = 1}) async {
    await subscribeCandles(pair, timeframeMinutes: timeframe);
    return getCachedCandles(pair);
  }

  /// ================= WRAPPERS =================
  Future<List<Pair>> getMarketPairs() async {
    if (!_connected) await connect();
    return _symbolMap.entries
        .map((e) => Pair(symbol: e.key, displayName: e.value, type: "forex"))
        .toList();
  }

  Future<double> getLastPrice(String pair) async {
    final list = getCachedCandles(pair);
    if (list.isNotEmpty) return list.last.close;
    return 0.0;
  }

  Future<String?> placeTrade(String pair, bool isBuy, {double stake = defaultStake}) async {
    if (!_connected) await connect();
    final symbol = _normalize(pair);
    final actual = _symbolMap[symbol] ?? symbol;

    _send({
      "proposal": 1,
      "amount": stake,
      "basis": "stake",
      "contract_type": isBuy ? "MULTUP" : "MULTDOWN",
      "currency": "USD",
      "symbol": actual,
      "multiplier": 50
    });

    final res = await _sendAndWait("proposal", {}, timeoutSeconds: 5);
    final proposalId = res['proposal']?['id'];
    if (proposalId == null) return null;

    _send({"buy": proposalId, "price": stake});
    final buyRes = await _sendAndWait("buy", {}, timeoutSeconds: 5);
    final contractId = buyRes['buy']?['contract_id']?.toString();
    if (contractId != null) openTrades[contractId] = {"pair": symbol, "stake": stake, "direction": isBuy ? "BUY" : "SELL"};
    return contractId;
  }

  Future<void> closeTradeById(String contractId) async {
    _contractStreams[contractId]?.close();
    _contractStreams.remove(contractId);
    openTrades.remove(contractId);
  }

  void subscribeContract(String contractId, void Function(Map<String, dynamic>) callback) {
    final ctrl = _contractStreams.putIfAbsent(contractId, () => StreamController<Map<String, dynamic>>.broadcast());
    ctrl.stream.listen(callback);
  }

  /// ================= SAFE BALANCE =================
  Future<double> getBalance() async {
    await connect();
    final completer = Completer<double>();
    late StreamSubscription sub;

    sub = _wsStream.listen((msg) {
      try {
        final data = jsonDecode(msg);
        if (data['msg_type'] == 'balance') {
          final bal = (data['balance']?['balance'] ?? 0).toDouble();
          if (!completer.isCompleted) completer.complete(bal);
          sub.cancel();
        }
      } catch (_) {}
    });

    _send({"balance": 1, "subscribe": 1});

    Future.delayed(const Duration(seconds: 10), () {
      if (!completer.isCompleted) {
        completer.complete(0.0);
        sub.cancel();
      }
    });

    return completer.future;
  }

  /// ================= UTILS =================
  String _normalize(String s) {
    s = s.replaceAll(RegExp(r'[^A-Za-z]'), '').toUpperCase();
    if (!s.startsWith("FRX")) s = "FRX$s";
    return s;
  }

  void _addTickToCandles(String symbol, double price, int epoch) {
    final list = _candles.putIfAbsent(symbol, () => []);
    final bucket = (epoch ~/ 60) * 60;
    if (list.isEmpty || list.last.epoch != bucket) {
      final open = list.isNotEmpty ? list.last.close : price;
      list.add(Candle(epoch: bucket, open: open, close: price, high: max(open, price), low: min(open, price), volume: 1));
    } else {
      final last = list.last;
      list[list.length - 1] = Candle(
        epoch: last.epoch,
        open: last.open,
        close: price,
        high: max(last.high, price),
        low: min(last.low, price),
        volume: last.volume + 1,
      );
    }
  }

  void _send(Map<String, dynamic> data) {
    _channel?.sink.add(jsonEncode(data));
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

  void _scheduleReconnect() async {
    _connected = false;
    _authorized = false;
    await _channel?.sink.close();
    await Future.delayed(const Duration(seconds: 2));
    await connect();
  }
}