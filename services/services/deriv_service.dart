import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/widgets.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../models/candle.dart';
import '../models/asset.dart';
import '../config.dart';
import 'market_analysis_service.dart';

class DerivService {
  // ================= Singleton =================
  static final DerivService _instance = DerivService._internal();
  factory DerivService() => _instance;
  DerivService._internal();

  // ================= Internal State =================
  WebSocketChannel? _channel;
  StreamSubscription? _streamSubscription;
  final _storage = const FlutterSecureStorage();
  String? _token;
  bool _authorized = false;
  bool _connecting = false;
  bool _reconnecting = false;
  Timer? _pingTimer;

  final _balanceController = StreamController<double>.broadcast();
  final _candleControllers = <String, StreamController<myCandle.Candle>>{};
  final _availablePairsController = StreamController<List<String>>.broadcast();

  final _subscribedPairs = <String>{};
  final _historicalCandles = <String, List<myCandle.Candle>>{};
  final _availablePairs = <String>[];
  final Map<int, Completer<String?>> _pendingContracts = {};
  final Map<int, Timer> _pendingContractTimers = {};
  double _lastKnownBalance = 0.0;

  final MarketAnalysisService _analysis = MarketAnalysisService.instance;

  static const Duration _pendingContractTimeout = Duration(seconds: 10);
  static const Duration _balanceRequestTimeout = Duration(seconds: 6);
  static const int maxCandlesPerPair = 200;

  // ================= Getters =================
  bool get isAuthorized => _authorized;
  bool get isLoggedIn => _authorized && _token != null && _token!.isNotEmpty;
  bool get isConnected => _channel != null;
  List<String> get availablePairs => List.unmodifiable(_availablePairs);

  Stream<double> balanceStream() => _balanceController.stream;
  Stream<List<String>> availablePairsStream() => _availablePairsController.stream;

  // ================= Public API =================
  Future<void> login([String? token]) async {
    WidgetsFlutterBinding.ensureInitialized();
    await connect(token);
  }

  Future<void> connect([String? token]) async {
    if (_connecting) return;
    _connecting = true;
    try {
      _token = token ?? await _storage.read(key: 'deriv_token') ?? derivToken;
      if (_token == null || _token!.isEmpty) return;

      final uri = Uri.parse("wss://ws.derivws.com/websockets/v3?app_id=$derivAppId");
      _channel = WebSocketChannel.connect(uri);

      await _streamSubscription?.cancel();
      _streamSubscription = _channel?.stream.listen(
        _handleMessage,
        onError: (_) => _scheduleReconnect(),
        onDone: () {
          _authorized = false;
          _scheduleReconnect();
        },
        cancelOnError: true,
      );

      _startPing();
      _send({"authorize": _token});
    } finally {
      _connecting = false;
    }
  }

  Future<List<String>> getAvailablePairs() async {
    if (_availablePairs.isNotEmpty) return List<String>.from(_availablePairs);
    final completer = Completer<List<String>>();
    final sub = availablePairsStream().listen((pairs) {
      if (pairs.isNotEmpty && !completer.isCompleted) {
        completer.complete(List<String>.from(pairs));
      }
    });
    await fetchAvailablePairs();
    final result = await completer.future;
    await sub.cancel();
    return result;
  }

  Future<void> fetchAvailablePairs() async => _fetchActiveSymbols();

  Stream<myCandle.Candle> subscribeCandles(String pair, {int granularity = 60}) {
    pair = _normalizePair(pair);
    final controller = _candleControllers.putIfAbsent(pair, () => StreamController<myCandle.Candle>.broadcast());
    _historicalCandles.putIfAbsent(pair, () => []);
    if (_subscribedPairs.contains(pair)) return controller.stream;
    _subscribedPairs.add(pair);

    _send({
      "ticks_history": pair,
      "end": "latest",
      "count": 200,
      "style": "candles",
      "granularity": granularity,
      "subscribe": 1,
    });

    return controller.stream;
  }

  // ================= Trading Methods =================
  Future<String?> buyContract({
    required String pair,
    required String direction,
    required double stake,
    double? stopLoss,
    double? takeProfit,
    int duration = 1,
  }) async {
    if (!isLoggedIn) throw Exception("Not logged in");

    final type = direction.toUpperCase() == "CALL" ? "CALL" : "PUT";
    final reqId = DateTime.now().millisecondsSinceEpoch;
    final completer = Completer<String?>();
    _pendingContracts[reqId] = completer;

    _pendingContractTimers[reqId] = Timer(_pendingContractTimeout, () {
      if (!completer.isCompleted) completer.complete(null);
      _pendingContracts.remove(reqId);
      _pendingContractTimers.remove(reqId)?.cancel();
    });

    final params = {
      "amount": stake,
      "basis": "stake",
      "contract_type": type,
      "currency": "USD",
      "duration": duration,
      "duration_unit": "t",
      "symbol": _normalizePair(pair),
    };

    if (stopLoss != null) params["stop_loss"] = stopLoss;
    if (takeProfit != null) params["take_profit"] = takeProfit;

    _send({
      "buy": 1,
      "parameters": params,
      "passthrough": {"request_id": reqId},
    });

    return completer.future;
  }

  Future<String> buy({
    required String pair,
    required double stake,
    double? stopLoss,
    double? takeProfit,
    int duration = 1,
  }) async {
    return (await buyContract(
          pair: pair,
          direction: "CALL",
          stake: stake,
          stopLoss: stopLoss,
          takeProfit: takeProfit,
          duration: duration,
        )) ??
        "";
  }

  Future<String> sell({
    required String pair,
    required double stake,
    double? stopLoss,
    double? takeProfit,
    int duration = 1,
  }) async {
    return (await buyContract(
          pair: pair,
          direction: "PUT",
          stake: stake,
          stopLoss: stopLoss,
          takeProfit: takeProfit,
          duration: duration,
        )) ??
        "";
  }

  Future<void> updateSL(String pair, double stopLoss) async {
    // This depends on API support, placeholder
    _send({
      "update_contract": 1,
      "parameters": {"symbol": _normalizePair(pair), "stop_loss": stopLoss}
    });
  }

  Future<void> closePartial(String pair, double fraction) async {
    _send({
      "close_partial": 1,
      "parameters": {"symbol": _normalizePair(pair), "fraction": fraction}
    });
  }

  Future<void> closeAll(String pair) async {
    _send({
      "close_all": 1,
      "parameters": {"symbol": _normalizePair(pair)}
    });
  }

  Future<double> getBalance() async {
    if (_lastKnownBalance > 0) return _lastKnownBalance;
    final completer = Completer<double>();
    late StreamSubscription sub;
    sub = balanceStream().listen((b) {
      if (!completer.isCompleted) completer.complete(b);
    });
    _send({"balance": 1});
    final timer = Timer(_balanceRequestTimeout, () {
      if (!completer.isCompleted) completer.complete(_lastKnownBalance);
    });
    final result = await completer.future;
    timer.cancel();
    await sub.cancel();
    return result;
  }

  // ================= Internal Helpers =================
  void _startPing() {
    _pingTimer?.cancel();
    _pingTimer = Timer.periodic(const Duration(seconds: 25), (_) {
      if (_channel != null) _send({"ping": 1});
    });
  }

  void _send(Map<String, dynamic> data) {
    try {
      _channel?.sink.add(jsonEncode(data));
    } catch (_) {}
  }

  void _scheduleReconnect() async {
    if (_reconnecting || _connecting) return;
    _reconnecting = true;
    await Future.delayed(const Duration(seconds: 5));
    _cleanupConnection();
    await connect(_token);
    if (isLoggedIn) {
      await _resubscribePairs();
      _fetchActiveSymbols();
    }
    _reconnecting = false;
  }

  void _cleanupConnection() {
    _pingTimer?.cancel();
    _streamSubscription?.cancel();
    try {
      _channel?.sink.close();
    } catch (_) {}
    _streamSubscription = null;
    _channel = null;
    _authorized = false;
  }

  Future<void> _resubscribePairs() async {
    if (!_authorized) return;
    for (final pair in _subscribedPairs) {
      _send({
        "ticks_history": pair,
        "end": "latest",
        "count": 500,
        "style": "candles",
        "granularity": 60,
        "subscribe": 1,
      });
      await Future.delayed(const Duration(milliseconds: 120));
    }
  }

  String _normalizePair(String symbol) {
    if (symbol.isEmpty) return '';
    var cleaned = symbol.replaceAll(RegExp(r'[/\-\s]'), '');
    if (cleaned.toLowerCase().startsWith('frx')) return 'frx${cleaned.substring(3).toUpperCase()}';
    return 'frx${cleaned.toUpperCase()}';
  }

  void _handleMessage(dynamic message) {
    try {
      final data = jsonDecode(message);
      final msgType = data['msg_type'] ?? data['type'] ?? '';

      switch (msgType) {
        case 'authorize':
          _authorized = true;
          _subscribeBalance();
          Future.delayed(const Duration(milliseconds: 200), () {
            _resubscribePairs();
            _fetchActiveSymbols();
          });
          break;
        case 'balance':
          _lastKnownBalance = (data['balance']?['balance'] as num?)?.toDouble() ?? 0.0;
          _balanceController.add(_lastKnownBalance);
          break;
        case 'candles':
        case 'ohlc':
          _processCandles(data);
          break;
        case 'active_symbols':
          final List<dynamic> symbolsData = data['active_symbols'] ?? [];
          final symbols = symbolsData
              .where((s) => (s['market'] as String?)?.toLowerCase() == 'forex')
              .map<String>((s) => _normalizePair(s['symbol'] ?? ''))
              .where((s) => s.isNotEmpty)
              .toList();
          if (symbols.isNotEmpty) {
            _availablePairs
              ..clear()
              ..addAll(symbols);
            _availablePairsController.add(_availablePairs);
          }
          break;
        case 'buy':
        case 'proposal_open_contract':
        case 'sell':
        case 'contract':
          final pt = data['passthrough'];
          if (pt != null && pt['request_id'] != null) {
            final reqId = (pt['request_id'] is int) ? pt['request_id'] : int.tryParse(pt['request_id'].toString()) ?? 0;
            final completer = _pendingContracts.remove(reqId);
            _pendingContractTimers.remove(reqId)?.cancel();
            if (completer != null && !completer.isCompleted) {
              final contractId = data['buy']?['contract_id'] ??
                  data['proposal']?['id'] ??
                  data['contract']?['id'] ??
                  data['proposal_open_contract']?['contract_id'] ??
                  data['transaction_id'];
              completer.complete(contractId?.toString() ?? jsonEncode(data));
            }
          }
          break;
        default:
          if (data['candles'] != null || data['ohlc'] != null) _processCandles(data);
      }
    } catch (e, st) {
      debugPrint("⚠️ _handleMessage JSON/processing error: $e\n$st");
    }
  }

  void _subscribeBalance() => _send({"balance": 1, "subscribe": 1});

  void _fetchActiveSymbols({int retries = 3}) {
    if (!isLoggedIn) return;
    _send({"active_symbols": "brief", "product_type": "basic"});
    if (_availablePairs.isEmpty && retries > 0) {
      Future.delayed(const Duration(seconds: 2), () => _fetchActiveSymbols(retries: retries - 1));
    }
  }

  void _addCandleToStore(String symbol, myCandle.Candle candle) {
    final store = _historicalCandles.putIfAbsent(symbol, () => []);
    final controller = _candleControllers.putIfAbsent(symbol, () => StreamController<myCandle.Candle>.broadcast());

    final epoch = candle.epoch;

    if (store.isNotEmpty && store.last.epoch == epoch) {
      final last = store.last;
      last.close = candle.close;
      last.high = max(last.high, candle.high);
      last.low = min(last.low, candle.low);
      last.volume += candle.volume;
    } else {
      store.add(myCandle.Candle(
        epoch: candle.epoch,
        open: candle.open,
        close: candle.close,
        high: candle.high,
        low: candle.low,
        volume: candle.volume,
      ));
    }

    if (store.length > maxCandlesPerPair) store.removeRange(0, store.length - maxCandlesPerPair);

    try {
      controller.add(store.last);
    } catch (_) {}

    try {
      _analysis.updatePairSingleCandle(symbol, store.last);
    } catch (e, st) {
      debugPrint("⚠️ _analysis.updatePairSingleCandle failed: $e\n$st");
    }
  }

  void _processCandles(Map<String, dynamic> data) {
    try {
      String? symbol = data['echo_req']?['symbol'] ?? data['echo_req']?['ticks_history'] ?? data['symbol'];
      if (symbol == null || symbol.isEmpty) return;
      symbol = _normalizePair(symbol);

      List<Map<String, dynamic>> rawCandles = [];
      if (data['candles'] != null) rawCandles = List<Map<String, dynamic>>.from(data['candles']);
      else if (data['ohlc'] != null) rawCandles.add(Map<String, dynamic>.from(data['ohlc']));

      for (var c in rawCandles) {
        try {
          final candle = myCandle.Candle.fromJson(c);
          if (_isValidCandle(candle)) _addCandleToStore(symbol, candle);
        } catch (e, st) {
          debugPrint("⚠️ Candle parsing failed for $symbol: $e\n$st");
        }
      }
    } catch (e, st) {
      debugPrint("⚠️ _processCandles error: $e\n$st");
    }
  }

  bool _isValidCandle(myCandle.Candle c) {
    try {
      return c.open.isFinite &&
          c.close.isFinite &&
          c.high.isFinite &&
          c.low.isFinite &&
          c.volume.isFinite &&
          !c.open.isNaN &&
          !c.close.isNaN &&
          !c.high.isNaN &&
          !c.low.isNaN &&
          !c.volume.isNaN &&
          c.epoch > 0 &&
          c.high >= c.low;
    } catch (_) {
      return false;
    }
  }

  void dispose() {
    for (final c in _candleControllers.values) {
      try {
        c.close();
      } catch (_) {}
    }
    _candleControllers.clear();
    _historicalCandles.clear();
    try {
      _balanceController.close();
    } catch (_) {}
    try {
      _availablePairsController.close();
    } catch (_) {}
    _streamSubscription?.cancel();
    try {
      _channel?.sink.close();
    } catch (_) {}
  }
}
