// lib/src/models/market_pair.dart
import 'candle.dart';

class MarketPair {
  final String symbol;
  final String? displayName;
  final List<Candle> candles = [];

  MarketPair({
    required this.symbol,
    this.displayName,
    List<Candle>? initialCandles,
  }) {
    if (initialCandles != null && initialCandles.isNotEmpty) {
      candles.addAll(initialCandles);
    }

    if (symbol.isEmpty) {
      print("⚠️ Attempted to create MarketPair for unknown Deriv symbol");
    }
  }

  /// updateCandles: add new incoming candles (keeps list capped to maxLen)
  void updateCandles(List<Candle> incoming, {int maxLen = 500}) {
    if (incoming.isEmpty) {
      print("⚠️ Ignored candle update for $symbol because incoming list is empty");
      return;
    }

    // Simply append; you could insert if times are older than existing last
    candles.addAll(incoming);

    if (candles.length > maxLen) {
      final removeCount = candles.length - maxLen;
      candles.removeRange(0, removeCount);
    }
  }

  Map<String, dynamic> toJson() {
    return {
      'symbol': symbol,
      'displayName': displayName ?? symbol,
      'candles': candles.map((c) => c.toJson()).toList(),
    };
  }

  factory MarketPair.fromJson(Map<String, dynamic> json) {
    final symbol = json['symbol']?.toString() ?? '';
    final displayName = json['displayName']?.toString();
    List<Candle> initial = [];

    if (json['candles'] is List) {
      for (var c in json['candles']) {
        try {
          initial.add(Candle.fromJson(c));
        } catch (e) {
          print("⚠️ Failed to parse candle for $symbol: $e");
        }
      }
    }

    if (symbol.isEmpty) {
      print("⚠️ Attempted to create MarketPair for unknown Deriv symbol from JSON");
    }

    return MarketPair(symbol: symbol, displayName: displayName, initialCandles: initial);
  }

  @override
  String toString() =>
      'MarketPair(symbol: $symbol, displayName: ${displayName ?? symbol}, candles: ${candles.length})';
}
