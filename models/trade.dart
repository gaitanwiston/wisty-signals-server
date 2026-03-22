// lib/src/models/trade.dart
class Trade {
  final String symbol;
  final bool isCall;
  final double stake;
  final double openPrice;
  final double stopLoss;
  final double takeProfit;
  final String contractId;
  final int epoch;

  Trade({
    required this.symbol,
    required this.isCall,
    required this.stake,
    required this.openPrice,
    required this.stopLoss,
    required this.takeProfit,
    required this.contractId,
    required this.epoch,
  });

  Trade copyWith({
    String? symbol,
    bool? isCall,
    double? stake,
    double? openPrice,
    double? stopLoss,
    double? takeProfit,
    String? contractId,
    int? epoch,
  }) {
    return Trade(
      symbol: symbol ?? this.symbol,
      isCall: isCall ?? this.isCall,
      stake: stake ?? this.stake,
      openPrice: openPrice ?? this.openPrice,
      stopLoss: stopLoss ?? this.stopLoss,
      takeProfit: takeProfit ?? this.takeProfit,
      contractId: contractId ?? this.contractId,
      epoch: epoch ?? this.epoch,
    );
  }

  factory Trade.fromJson(Map<String, dynamic> json) {
    return Trade(
      symbol: json['symbol'],
      isCall: json['isCall'],
      stake: (json['stake'] as num).toDouble(),
      openPrice: (json['openPrice'] as num).toDouble(),
      stopLoss: (json['stopLoss'] as num).toDouble(),
      takeProfit: (json['takeProfit'] as num).toDouble(),
      contractId: json['contractId'],
      epoch: json['epoch'],
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'symbol': symbol,
      'isCall': isCall,
      'stake': stake,
      'openPrice': openPrice,
      'stopLoss': stopLoss,
      'takeProfit': takeProfit,
      'contractId': contractId,
      'epoch': epoch,
    };
  }

  /// Compatibility na MarketStateService
  Map<String, dynamic> toMap() => toJson();
}
