import 'dart:convert';
import 'package:flutter/services.dart' show rootBundle;

import '../models/asset.dart';
import '../services/asset_parser.dart';
import '../services/deriv_service.dart';

Future<void> initAssets() async {
  try {
    // 📦 Load root.json
    final jsonStr = await rootBundle.loadString('assets/root.json');
    final Map<String, dynamic> rootJson = jsonDecode(jsonStr);

    // 🔍 Parse assets
    final List<Asset> assets = parseRootJson(rootJson);

    if (assets.isEmpty) {
      print('⚠️ No assets parsed from root.json');
      return;
    }

    // 🔌 Init Deriv
    final deriv = DerivService.instance;

    if (!deriv.isConnected) { // ⚡ use isConnected instead of isLoggedIn
      await deriv.login(); // token kutoka FlutterSecureStorage / config
      print('🔐 Deriv login successful');
    }

    // 📡 Subscribe all Forex assets
    deriv.subscribeAllAssets(
  assets.map((a) => a.symbol).toList(),
);

    print('✅ Asset initialization complete → ${assets.length} assets');
  } catch (e, st) {
    print('❌ initAssets failed: $e');
    print(st);
  }
}
