import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

/// Twitch OAuth token lifecycle.
///
/// Handles:
/// - Generating the authorization URL
/// - Exchanging the code for tokens
/// - Refreshing expired tokens
/// - Storing tokens in SharedPreferences
class TwitchAuth extends ChangeNotifier {
  // Twitch app credentials — set via configure()
  String _clientId = '';
  String _clientSecret = '';
  String _redirectUri = 'http://localhost:8511/auth/callback';

  // Token state
  String? _accessToken;
  String? _refreshToken;
  String? _botId;
  String? _broadcasterId;
  DateTime? _tokenExpiry;

  bool get isAuthenticated => _accessToken != null;
  String? get accessToken => _accessToken;
  String? get clientId => _clientId;

  static const _scopes = [
    'chat:read',
    'chat:edit',
    'channel:moderate',
    'channel:read:stream_key',
    'channel:manage:broadcast',
    'moderator:manage:banned_users',
    'moderator:manage:chat_settings',
    'user:read:email',
  ];

  void configure({
    required String clientId,
    required String clientSecret,
    String redirectUri = 'http://localhost:8511/auth/callback',
  }) {
    _clientId = clientId;
    _clientSecret = clientSecret;
    _redirectUri = redirectUri;
  }

  /// Generate the URL the user visits to authorize the app.
  String get authorizationUrl {
    final params = {
      'client_id': _clientId,
      'redirect_uri': _redirectUri,
      'response_type': 'code',
      'scope': _scopes.join(' '),
      'force_verify': 'true',
    };
    final query = params.entries.map((e) => '${Uri.encodeComponent(e.key)}=${Uri.encodeComponent(e.value)}').join('&');
    return 'https://id.twitch.tv/oauth2/authorize?$query';
  }

  /// Exchange an authorization code for tokens.
  Future<bool> exchangeCode(String code) async {
    try {
      final res = await http.post(
        Uri.parse('https://id.twitch.tv/oauth2/token'),
        headers: {'Content-Type': 'application/x-www-form-urlencoded'},
        body: {
          'client_id': _clientId,
          'client_secret': _clientSecret,
          'code': code,
          'grant_type': 'authorization_code',
          'redirect_uri': _redirectUri,
        },
      );

      if (res.statusCode != 200) {
        debugPrint('[TwitchAuth] Token exchange failed: ${res.statusCode} ${res.body}');
        return false;
      }

      final data = jsonDecode(res.body) as Map<String, dynamic>;
      _accessToken = data['access_token'] as String;
      _refreshToken = data['refresh_token'] as String;
      _tokenExpiry = DateTime.now().add(Duration(seconds: data['expires_in'] as int));

      // Resolve user info to get bot ID
      await _resolveUserInfo();
      await _saveTokens();
      notifyListeners();
      return true;
    } catch (e) {
      debugPrint('[TwitchAuth] Token exchange error: $e');
      return false;
    }
  }

  /// Refresh the access token when it expires.
  Future<bool> refreshToken() async {
    if (_refreshToken == null) return false;

    try {
      final res = await http.post(
        Uri.parse('https://id.twitch.tv/oauth2/token'),
        headers: {'Content-Type': 'application/x-www-form-urlencoded'},
        body: {
          'client_id': _clientId,
          'client_secret': _clientSecret,
          'refresh_token': _refreshToken!,
          'grant_type': 'refresh_token',
        },
      );

      if (res.statusCode != 200) {
        debugPrint('[TwitchAuth] Token refresh failed: ${res.statusCode}');
        _accessToken = null;
        _refreshToken = null;
        notifyListeners();
        return false;
      }

      final data = jsonDecode(res.body) as Map<String, dynamic>;
      _accessToken = data['access_token'] as String;
      _refreshToken = data['refresh_token'] as String? ?? _refreshToken;
      _tokenExpiry = DateTime.now().add(Duration(seconds: data['expires_in'] as int));
      await _saveTokens();
      notifyListeners();
      return true;
    } catch (e) {
      debugPrint('[TwitchAuth] Token refresh error: $e');
      return false;
    }
  }

  /// Check if token is expired and refresh if needed.
  Future<bool> ensureValidToken() async {
    if (_accessToken == null) return false;
    if (_tokenExpiry != null && DateTime.now().isAfter(_tokenExpiry!)) {
      return refreshToken();
    }
    return true;
  }

  /// Validate a directly-supplied access token against Helix /validate and
  /// adopt it if valid (resolving user info). Returns false if Twitch rejects it.
  Future<bool> validateAndAdoptToken(String token) async {
    try {
      final res = await http.get(
        Uri.parse('https://id.twitch.tv/oauth2/validate'),
        headers: {'Authorization': 'OAuth $token'},
      );
      if (res.statusCode != 200) return false;
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      _accessToken = token;
      final expiresIn = data['expires_in'] as int? ?? 3600;
      _tokenExpiry = DateTime.now().add(Duration(seconds: expiresIn));
      await _resolveUserInfo();
      notifyListeners();
      return true;
    } catch (e) {
      debugPrint('[TwitchAuth] validateAndAdoptToken error: $e');
      return false;
    }
  }

  /// Resolve the authenticated user's info.
  Future<void> _resolveUserInfo() async {
    if (_accessToken == null) return;
    try {
      final res = await http.get(
        Uri.parse('https://api.twitch.tv/helix/users'),
        headers: {
          'Authorization': 'Bearer $_accessToken',
          'Client-Id': _clientId,
        },
      );
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        final users = data['data'] as List<dynamic>;
        if (users.isNotEmpty) {
          final user = users[0] as Map<String, dynamic>;
          _botId = user['id'] as String?;
        }
      }
    } catch (e) {
      debugPrint('[TwitchAuth] Resolve user info error: $e');
    }
  }

  /// Set the broadcaster (channel) ID.
  void setBroadcasterId(String id) {
    _broadcasterId = id;
  }

  String? get broadcasterId => _broadcasterId;
  String? get botId => _botId;

  // ── Persistence ──

  Future<void> _saveTokens() async {
    final prefs = await SharedPreferences.getInstance();
    if (_accessToken != null) prefs.setString('twitch_access_token', _accessToken!);
    if (_refreshToken != null) prefs.setString('twitch_refresh_token', _refreshToken!);
    if (_botId != null) prefs.setString('twitch_bot_id', _botId!);
    if (_broadcasterId != null) prefs.setString('twitch_broadcaster_id', _broadcasterId!);
    if (_tokenExpiry != null) prefs.setString('twitch_token_expiry', _tokenExpiry!.toIso8601String());
    if (_clientId.isNotEmpty) prefs.setString('twitch_client_id', _clientId);
    if (_clientSecret.isNotEmpty) prefs.setString('twitch_client_secret', _clientSecret);
  }

  Future<bool> loadTokens() async {
    final prefs = await SharedPreferences.getInstance();
    _accessToken = prefs.getString('twitch_access_token');
    _refreshToken = prefs.getString('twitch_refresh_token');
    _botId = prefs.getString('twitch_bot_id');
    _broadcasterId = prefs.getString('twitch_broadcaster_id');
    final expiryStr = prefs.getString('twitch_token_expiry');
    if (expiryStr != null) {
      _tokenExpiry = DateTime.tryParse(expiryStr);
    }

    // Load saved credentials
    final savedClientId = prefs.getString('twitch_client_id');
    final savedClientSecret = prefs.getString('twitch_client_secret');
    if (savedClientId != null && savedClientSecret != null) {
      _clientId = savedClientId;
      _clientSecret = savedClientSecret;
    }

    if (_accessToken != null) {
      notifyListeners();
      return true;
    }
    return false;
  }

  /// Save credentials (client ID/secret) to SharedPreferences.
  Future<void> saveCredentials() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('twitch_client_id', _clientId);
    await prefs.setString('twitch_client_secret', _clientSecret);
  }

  /// Load saved credentials (client ID/secret) without requiring tokens.
  Future<bool> loadCredentials() async {
    final prefs = await SharedPreferences.getInstance();
    final savedClientId = prefs.getString('twitch_client_id');
    final savedClientSecret = prefs.getString('twitch_client_secret');
    if (savedClientId != null && savedClientSecret != null) {
      _clientId = savedClientId;
      _clientSecret = savedClientSecret;
      return true;
    }
    return false;
  }

  /// Load the saved channel name.
  Future<String?> loadChannelName() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('twitch_channel_name');
  }

  /// Save the channel name.
  Future<void> saveChannelName(String name) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('twitch_channel_name', name);
  }

  Future<void> clearTokens() async {
    _accessToken = null;
    _refreshToken = null;
    _botId = null;
    _broadcasterId = null;
    _tokenExpiry = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('twitch_access_token');
    await prefs.remove('twitch_refresh_token');
    await prefs.remove('twitch_bot_id');
    await prefs.remove('twitch_broadcaster_id');
    await prefs.remove('twitch_token_expiry');
    await prefs.remove('twitch_client_id');
    await prefs.remove('twitch_client_secret');
    await prefs.remove('twitch_channel_name');
    notifyListeners();
  }
}
