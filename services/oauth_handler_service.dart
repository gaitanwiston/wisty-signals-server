import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:uni_links/uni_links.dart';

class OAuthHandlerService {
  OAuthHandlerService._privateConstructor();
  static final OAuthHandlerService instance = OAuthHandlerService._privateConstructor();

  final FlutterSecureStorage _storage = const FlutterSecureStorage();

  StreamSubscription? _sub;

  /// Start listening to OAuth redirects
  void init() {
    // Handle app already opened via OAuth
    _handleInitialUri();

    // Handle app running and receives OAuth redirect
    _sub = uriLinkStream.listen((Uri? uri) {
      if (uri != null) {
        _processUri(uri);
      }
    }, onError: (err) {
      debugPrint('Error listening to OAuth redirects: $err');
    });
  }

  /// Handle initial app open via redirect
  Future<void> _handleInitialUri() async {
    try {
      final initialUri = await getInitialUri();
      if (initialUri != null) {
        _processUri(initialUri);
      }
    } catch (e) {
      debugPrint('Failed to get initial URI: $e');
    }
  }

  /// Process the OAuth redirect URI
  void _processUri(Uri uri) {
    if (uri.scheme == 'wistyfx' && uri.host == 'callback') {
      final token = uri.queryParameters['token'];
      if (token != null) {
        _storeToken(token);
      }
    }
  }

  /// Store token securely
  Future<void> _storeToken(String token) async {
    await _storage.write(key: 'deriv_oauth_token', value: token);
    debugPrint('OAuth token saved: $token');
  }

  /// Retrieve token
  Future<String?> getToken() async {
    return _storage.read(key: 'deriv_oauth_token');
  }

  /// Dispose listener
  void dispose() {
    _sub?.cancel();
  }
}
