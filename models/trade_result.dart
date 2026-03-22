enum TradeDirection { call, put }

class TradeResult {
  final bool success;
  final String pair;
  final double stake;
  final TradeDirection direction;
  final String message;

  TradeResult({
    required this.success,
    required this.pair,
    required this.stake,
    required this.direction,
    this.message = '',
  });

  /// Parse string or enum to TradeDirection
  static TradeDirection parseDirection(dynamic value) {
    if (value is TradeDirection) return value;
    if (value is String) {
      final v = value.toUpperCase();
      if (v == 'PUT' || v == 'SELL') return TradeDirection.put;
      if (v == 'CALL' || v == 'BUY') return TradeDirection.call;
    }
    return TradeDirection.call;
  }

  factory TradeResult.fromJson(Map<String, dynamic> json) => TradeResult(
        success: json['success'] ?? false,
        pair: json['pair'] ?? '',
        stake: (json['stake'] ?? 0).toDouble(),
        direction: parseDirection(json['direction']),
        message: json['message'] ?? '',
      );

  Map<String, dynamic> toJson() => {
        'success': success,
        'pair': pair,
        'stake': stake,
        'direction': direction.name.toUpperCase(),
        'message': message,
      };
}
