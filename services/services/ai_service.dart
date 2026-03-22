import 'dart:async';
import 'package:tflite_flutter/tflite_flutter.dart';
import '../models/candle.dart';
import 'deriv_service.dart';

/// Signal structure
class AISignal {
  final double probability; // 0 - 100
  final String direction; // "long", "short", or ""
  final double sl;
  final double tp;

  AISignal({
    required this.probability,
    required this.direction,
    required this.sl,
    required this.tp,
  });
}

class AIService {
  final StreamController<AISignal> _controller = StreamController<AISignal>.broadcast();
  Interpreter? _interpreter;

  AIService() {
    _loadModel();
  }

  /// Load TFLite model from assets/models/ai_model.tflite
  Future<void> _loadModel() async {
    try {
      _interpreter = await Interpreter.fromAsset('models/ai_model.tflite');
      print("✅ AI model loaded successfully!");
    } catch (e) {
      print("❌ Failed to load AI model: $e");
    }
  }

  /// Calculate SMA
  List<double> _calculateSMA(List<Candle> candles, int period) {
    if (candles.length < period) return [];
    List<double> sma = [];
    for (int i = period - 1; i < candles.length; i++) {
      double sum = 0;
      for (int j = i - period + 1; j <= i; j++) sum += candles[j].close;
      sma.add(sum / period);
    }
    return sma;
  }

  /// Calculate EMA
  List<double> _calculateEMA(List<Candle> candles, int period) {
    if (candles.length < period) return [];
    List<double> ema = [];
    double k = 2 / (period + 1);
    double prev = candles[0].close;
    for (int i = 0; i < candles.length; i++) {
      double val = candles[i].close * k + prev * (1 - k);
      ema.add(val);
      prev = val;
    }
    return ema;
  }

  /// Calculate RSI
  double _calculateRSI(List<Candle> candles, int period) {
    if (candles.length < period + 1) return 50; // neutral
    double gain = 0;
    double loss = 0;
    for (int i = candles.length - period; i < candles.length; i++) {
      double diff = candles[i].close - candles[i - 1].close;
      if (diff >= 0) gain += diff;
      else loss -= diff;
    }
    double rs = loss == 0 ? 100 : gain / loss;
    double rsi = 100 - (100 / (1 + rs));
    return rsi;
  }

  /// Process candles to produce AI signal
  void processCandles(List<Candle> candles) {
    if (candles.isEmpty) return;

    // Prepare input for ML model
    final lastClose = candles.last.close;
    final sma14 = _calculateSMA(candles, 14).lastOrNull ?? lastClose;
    final ema14 = _calculateEMA(candles, 14).lastOrNull ?? lastClose;
    final rsi14 = _calculateRSI(candles, 14);

    // Fallback: simple rule-based probability if TFLite fails
    double probability = 50;
    String direction = "";
    if (_interpreter != null) {
      try {
        var input = [[lastClose, sma14, ema14, rsi14]];
        var output = List.generate(1, (_) => List.filled(2, 0.0));
        _interpreter!.run(input, output);
        double probShort = output[0][0];
        double probLong = output[0][1];
        probability = (probLong > probShort ? probLong : probShort) * 100;
        direction = probLong > probShort ? "long" : "short";
      } catch (e) {
        print("❌ TFLite inference failed: $e");
      }
    }

    // Fallback simple rule: RSI oversold/overbought
    if (direction.isEmpty) {
      if (rsi14 < 30) {
        direction = "long";
        probability = 60;
      } else if (rsi14 > 70) {
        direction = "short";
        probability = 60;
      }
    }

    // Calculate SL/TP (2% stop loss / 2% take profit)
    double sl = lastClose * (direction == "long" ? 0.98 : 1.02);
    double tp = lastClose * (direction == "long" ? 1.02 : 0.98);

    // Broadcast signal
    _controller.add(AISignal(
      probability: probability,
      direction: probability >= 50 ? direction : "",
      sl: sl,
      tp: tp,
    ));
  }

  Stream<AISignal> aiStream() => _controller.stream;

  /// Notification placeholder
  void sendNotification(String message) {
    print("🔔 AI Notification: $message");
    // Integrate flutter_local_notifications or Firebase Messaging
  }

  void dispose() {
    _controller.close();
    _interpreter?.close();
  }
}

/// Extension for safe last element
extension LastOrNullExtension<T> on List<T> {
  T? get lastOrNull => isEmpty ? null : last;
}
