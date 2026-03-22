// lib/src/services/asset_initializer.dart
import 'package:flutter/services.dart' show rootBundle;
import 'dart:convert';
import '../services/deriv_service.dart';
import '../services/asset_parser.dart';
import '../models/asset.dart';

Future<void> initAssets() async {
  final jsonStr = await rootBundle.loadString('assets/root.json');
  final Map<String, dynamic> rootJson = jsonDecode(jsonStr);

  final List<Asset> assets = parseRootJson(rootJson);

  final deriv = DerivService();
  await deriv.login(); // Uses token from FlutterSecureStorage
  deriv.subscribeAllAssetsFromObjects(assets, granularity: 60);
}
