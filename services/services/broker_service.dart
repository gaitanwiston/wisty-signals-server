abstract class BrokerService {
  Future<void> placeOrder({
    required String symbol,
    required String orderType, // ← tumia orderType badala ya type
    required double amount,
    double? stopLoss,
    double? takeProfit,
  });

  Future<double> getBalance();
  Future<List<String>> getTradingPairs();
  Future<void> stopTrade();
}
