import 'dart:async';
import 'dart:convert';
import 'package:web_socket_channel/web_socket_channel.dart';

typedef CandleCallback = void Function(Map<String, dynamic> tick);

class DerivWSService {
  final String token;
  final int appId;
  WebSocketChannel? _channel;
  StreamSubscription? _subscription;

  DerivWSService({required this.token, required this.appId});

  void connect(String symbol, {required CandleCallback onTick}) {
    _channel?.sink.close();
    _channel = WebSocketChannel.connect(
      Uri.parse('wss://ws.binaryws.com/websockets/v3?app_id=$appId'),
    );

    _subscription = _channel!.stream.listen((message) {
      final data = jsonDecode(message);
      if (data['tick'] != null) {
        onTick(data['tick']);
      }
    });

    final request = jsonEncode({
      'ticks': symbol,
      'subscribe': 1,
      'token': token,
    });

    _channel!.sink.add(request);
  }

  void disconnect() {
    _subscription?.cancel();
    _channel?.sink.close();
  }
}
