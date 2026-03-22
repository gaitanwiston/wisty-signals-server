import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class StorageService {
  StorageService._privateConstructor();
  static final StorageService instance = StorageService._privateConstructor();

  final _storage = const FlutterSecureStorage();

  Future<void> saveDerivToken(String token) async {
    await _storage.write(key: 'deriv_token', value: token);
  }

  Future<String?> readDerivToken() async {
    return await _storage.read(key: 'deriv_token');
  }

  Future<void> saveAppId(String appId) async {
    await _storage.write(key: 'deriv_app_id', value: appId);
  }

  Future<String?> readAppId() async {
    return await _storage.read(key: 'deriv_app_id');
  }
}
