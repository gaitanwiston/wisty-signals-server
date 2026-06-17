class RiskModel {
  final double entry;
  final double stopLoss;
  final double takeProfit;
  final double lotSize;
  final String direction;

  RiskModel({
    required this.entry,
    required this.stopLoss,
    required this.takeProfit,
    required this.lotSize,
    required this.direction,
  });
}