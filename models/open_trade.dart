class OpenTrade {
  final String contractId;
  final String pair;
  final double amount;
  final String direction; // "BUY" or "SELL"
  final double entryPrice;
  String status; // Mutable: "OPEN", "CLOSED", "LOSS", etc.
  final String session;

  double? stopLoss;
  double? takeProfit;

  OpenTrade({
    required this.contractId,
    required this.pair,
    required this.amount,
    required String direction,
    required this.entryPrice,
    this.status = "OPEN",
    required this.session,
    this.stopLoss,
    this.takeProfit,
  }) : direction = direction.toUpperCase() {
    assert(this.direction == 'BUY' || this.direction == 'SELL',
        'Direction must be BUY or SELL');
  }

  /// Factory constructor from Deriv API
  factory OpenTrade.fromDeriv(Map<String, dynamic> data) {
    double? parseNullableDouble(dynamic val) {
      if (val == null) return null;
      if (val is num) return val.toDouble();
      if (val is String && val.isNotEmpty) return double.tryParse(val);
      return null;
    }

    String dir = (data['direction'] ?? 'BUY').toString().toUpperCase();
    if (dir != 'BUY' && dir != 'SELL') dir = 'BUY';

    return OpenTrade(
      contractId: data['contract_id'].toString(),
      pair: data['symbol'] ?? '',
      amount: parseNullableDouble(data['amount']) ?? 0,
      direction: dir,
      entryPrice: parseNullableDouble(data['entry_price']) ?? 0,
      status: data['status'] ?? 'OPEN',
      session: data['session'] ?? '',
      stopLoss: parseNullableDouble(data['stop_loss']),
      takeProfit: parseNullableDouble(data['take_profit']),
    );
  }

  /// Backward compatibility
  double? get sl => stopLoss;
  double? get tp => takeProfit;

  /// CopyWith for updates
  OpenTrade copyWith({
    String? status,
    double? stopLoss,
    double? takeProfit,
    double? entryPrice,
  }) {
    return OpenTrade(
      contractId: contractId,
      pair: pair,
      amount: amount,
      direction: direction,
      entryPrice: entryPrice ?? this.entryPrice,
      status: status ?? this.status,
      session: session,
      stopLoss: stopLoss ?? this.stopLoss,
      takeProfit: takeProfit ?? this.takeProfit,
    );
  }

  /// Convert to JSON for API response
  Map<String, dynamic> toJson() => {
        'contractId': contractId,
        'pair': pair,
        'amount': amount,
        'direction': direction,
        'entryPrice': entryPrice,
        'status': status,
        'session': session,
        'stopLoss': stopLoss,
        'takeProfit': takeProfit,
      };

  @override
  String toString() {
    return 'OpenTrade($pair, $direction, entry=$entryPrice, SL=$stopLoss, TP=$takeProfit, amount=$amount, status=$status)';
  }
}