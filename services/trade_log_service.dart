import 'package:flutter/foundation.dart';

class TradeLog {
  final String pair;
  final String direction;
  final double entryPrice;
  final double amount;
  final String session;
  final List<String> checklist;
  String status;
  final DateTime timestamp;

  TradeLog({
    required this.pair,
    required this.direction,
    required this.entryPrice,
    required this.amount,
    required this.session,
    required this.checklist,
    required this.status,
  }) : timestamp = DateTime.now();
}

class TradeLogService {
  TradeLogService._internal();
  static final TradeLogService instance = TradeLogService._internal();

  final List<TradeLog> _openTrades = [];
  final List<TradeLog> _history = [];

  // ================= LOGGING =================
  void logTrade({
    required String pair,
    required String direction,
    required double entryPrice,
    required double amount,
    required String session,
    required List<String> checklist,
    required String status,
  }) {
    final trade = TradeLog(
      pair: pair,
      direction: direction,
      entryPrice: entryPrice,
      amount: amount,
      session: session,
      checklist: checklist,
      status: status,
    );

    if (status == "OPEN") _openTrades.add(trade);
    _history.add(trade);

    debugPrint(
        "[LOG] Trade opened: $direction $pair @ $entryPrice | amount=$amount | session=$session");
  }

  void updateTradeStatus(String pair, String status) {
    for (var trade in _openTrades) {
      if (trade.pair == pair && trade.status == "OPEN") {
        trade.status = status;
        debugPrint(
            "[UPDATE] Trade $pair status updated → $status");
      }
    }

    _openTrades.removeWhere((t) => t.status != "OPEN");
  }

  // ================= OVERTRADING & REVENGE =================
  bool checkOvertrading() {
    // limit: 3 open trades per session
    return _openTrades.length >= 3;
  }

  bool checkRevenge(String pair) {
    // last closed trade was a loss → warning
    final last = _history.lastWhere(
        (t) => t.pair == pair && t.status.contains("CLOSED"),
        orElse: () => TradeLog(
              pair: pair,
              direction: "NONE",
              entryPrice: 0,
              amount: 0,
              session: "",
              checklist: [],
              status: "NONE",
            ));

    return last.status.contains("LOSS");
  }

  // ================= GETTERS =================
  List<TradeLog> get openTrades => List.unmodifiable(_openTrades);
  List<TradeLog> get tradeHistory => List.unmodifiable(_history);
}
