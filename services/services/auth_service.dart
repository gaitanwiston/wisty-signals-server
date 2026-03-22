// lib/src/services/auth_service.dart
import 'package:firebase_auth/firebase_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';

class AuthService {
  static final AuthService instance = AuthService._privateConstructor();
  AuthService._privateConstructor();

  final _auth = FirebaseAuth.instance;
  String? _derivToken;

  Future<bool> loginWithEmail(String email, String password, String derivToken) async {
    try {
      await _auth.signInWithEmailAndPassword(email: email, password: password);
      _derivToken = derivToken;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('deriv_token', derivToken);
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<String?> getSavedDerivToken() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('deriv_token');
  }

  User? get currentUser => _auth.currentUser;
}
