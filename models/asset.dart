// lib/src/models/asset.dart
class Asset {
  final String id; // ex: frxAUDUSD
  final String name; // ex: frxAUDUSD
  final String symbol; // ex: FRXUSDJPY
  final List<AssetContractType> contracts;

  Asset({
    required this.id,
    required this.name,
    required this.contracts,
    String? symbol, // optional kwa constructor
  }) : symbol = symbol ?? id.toUpperCase(); // default symbol = id uppercase

  factory Asset.fromList(List<dynamic> list) {
    // list format: [id, name, [[contractType, displayName, duration, history]]...]
    final id = list[0] as String;
    final name = list[1] as String;
    final contractsData = list[2] as List<dynamic>;
    final contracts = contractsData.map((c) {
      final contractList = c as List<dynamic>;
      return AssetContractType(
        type: contractList[0] as String,
        displayName: contractList[1] as String,
        duration: contractList[2] as String,
        history: contractList[3] as String,
      );
    }).toList();

    return Asset(id: id, name: name, contracts: contracts);
  }
}

class AssetContractType {
  final String type; // e.g., callput
  final String displayName; // e.g., Rise/Fall
  final String duration; // e.g., 15m, 1d
  final String history; // e.g., 365d

  AssetContractType({
    required this.type,
    required this.displayName,
    required this.duration,
    required this.history,
  });
}
