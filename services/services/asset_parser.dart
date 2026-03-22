import 'package:flutter/foundation.dart';
import '../models/asset.dart';

List<Asset> parseRootJson(Map<String, dynamic> rootJson) {
  final assetsList = rootJson['asset_index'];
  if (assetsList == null || assetsList is! List) {
    debugPrint("⚠️ asset_index is missing or not a list.");
    return [];
  }

  final assets = <Asset>[];

  for (var i = 0; i < assetsList.length; i++) {
    final item = assetsList[i];
    if (item is! List) {
      debugPrint("⚠️ Asset item at index $i is not a List: $item");
      continue;
    }

    try {
      assets.add(Asset.fromList(item));
    } catch (e, st) {
      debugPrint("⚠️ Failed to parse asset at index $i: $e\n$st");
    }
  }

  return assets;
}
