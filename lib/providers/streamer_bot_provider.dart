import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../services/sse_client.dart';
import '../models/chat_message.dart';

/// Central state for the bot connection, stream status, chat, commands, alerts, and errors.
class StreamerBotProvider extends ChangeNotifier {
  String _botUrl = 'http://localhost:8511';
  String get botUrl => _botUrl;
  SharedPreferences? _prefs;
  bool _prefsReady = false;
  String? _pendingUrl;

  StreamerBotProvider({SseClient? sseClient, http.Client? httpClient}) {
    _initPrefs();
    _initBuiltInCommands();
    if (sseClient != null) _sse = sseClient;
    if (httpClient != null) _http = httpClient;
  }

  // ── Persistence ──

  Future<void> _initPrefs() async {
    _prefs = await SharedPreferences.getInstance();
    _prefsReady = true;
    final saved = _prefs!.getString('botUrl');
    if (saved != null && saved.isNotEmpty) {
      _botUrl = saved;
      notifyListeners();
    }
    if (_pendingUrl != null) {
      _prefs!.setString('botUrl', _pendingUrl!);
      _pendingUrl = null;
    }
  }

  void setBotUrl(String url) {
    _botUrl = url;
    if (_prefsReady && _prefs != null) {
      _prefs!.setString('botUrl', url);
    } else {
      _pendingUrl = url;
    }
    notifyListeners();
  }

  // ── Stream status ──

  String _streamStatus = 'unknown';
  String get streamStatus => _streamStatus;
  int _viewers = 0;
  int get viewers => _viewers;
  String _game = '';
  String get game => _game;
  String _title = '';
  String get title => _title;

  // ── Commands ──

  List<Map<String, dynamic>> _commands = [];
  List<Map<String, dynamic>> get commands => _commands;

  void _initBuiltInCommands() {
    _commands = [
      {'name': 'uptime', 'response': 'Stream has been live for {uptime}.', 'enabled': true, 'is_built_in': true},
      {'name': 'socials', 'response': 'Follow me on Twitter/X: @streamer  |  Instagram: @streamer', 'enabled': true, 'is_built_in': true},
      {'name': 'discord', 'response': 'Join the Discord: discord.gg/streamer', 'enabled': true, 'is_built_in': true},
      {'name': 'commands', 'response': 'Available commands: !uptime, !socials, !discord, !game, !commands', 'enabled': true, 'is_built_in': true},
      {'name': 'game', 'response': 'Currently playing: {game}', 'enabled': true, 'is_built_in': true},
    ];
    // Also sync to backend if connected
  }

  Future<void> fetchCommands() async {
    try {
      final res = await _http
          .get(Uri.parse('$_botUrl/command/list'))
          .timeout(const Duration(seconds: 3));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        final backend = (data['commands'] as List<dynamic>?)
                ?.cast<Map<String, dynamic>>() ??
            [];
        // Merge: built-in local commands + backend custom commands
        final builtIn =
            _commands.where((c) => c['is_built_in'] == true).toList();
        _commands = [...builtIn, ...backend];
        notifyListeners();
      }
    } catch (_) {}
  }

  Future<bool> saveCommand(String name, String response) async {
    try {
      final res = await _http
          .post(Uri.parse('$_botUrl/command/save'),
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode({
                'name': name,
                'response': response,
                'enabled': true,
                'is_built_in': false,
              }))
          .timeout(const Duration(seconds: 3));
      if (res.statusCode == 200) {
        await fetchCommands();
        return true;
      }
      return false;
    } catch (_) {
      return false;
    }
  }

  Future<bool> deleteCommand(String name) async {
    try {
      final res = await _http
          .post(Uri.parse('$_botUrl/command/delete'),
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode({'name': name}))
          .timeout(const Duration(seconds: 3));
      if (res.statusCode == 200) {
        await fetchCommands();
        return true;
      }
      return false;
    } catch (_) {
      return false;
    }
  }

  Future<bool> runCommand(String name) async {
    try {
      final res = await _http
          .post(Uri.parse('$_botUrl/command/run'),
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode({'name': name}))
          .timeout(const Duration(seconds: 3));
      return res.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  /// Send a quick-action command response to chat (bypasses the run endpoint,
  /// just sends the raw text back into chat).
  Future<bool> sendQuickCommand(String response) async {
    if (!_connected) return false;
    return sendMessage(response);
  }

  // ── Alerts state ──

  List<Map<String, dynamic>> _alerts = [];
  List<Map<String, dynamic>> get alerts => _alerts;

  Map<String, dynamic>? _currentAlert;
  Map<String, dynamic>? get currentAlert => _currentAlert;
  Timer? _alertTimer;

  void _showAlert(Map<String, dynamic> alert) {
    _currentAlert = alert;
    notifyListeners();
    _alertTimer?.cancel();
    _alertTimer = Timer(const Duration(seconds: 6), () {
      _currentAlert = null;
      notifyListeners();
    });
  }

  void dismissAlert() {
    _alertTimer?.cancel();
    _currentAlert = null;
    notifyListeners();
  }

  // ── Errors ──

  String? _lastError;
  String? get lastError => _lastError;
  Timer? _errorPoller;

  void _setError(String context, dynamic error) {
    final msg = '[$context] $error';
    debugPrint('[provider] ERROR: $msg');
    _lastError = msg;
    notifyListeners();
  }

  void clearError() {
    _lastError = null;
    notifyListeners();
  }

  Future<void> fetchBackendErrors() async {
    try {
      final res = await _http
          .get(Uri.parse('$_botUrl/errors'))
          .timeout(const Duration(seconds: 3));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        final errors = data['errors'] as List<dynamic>?;
        if (errors != null && errors.isNotEmpty) {
          for (final err in errors) {
            if (err is Map && err['context'] != null) {
              _setError('backend/${err['context']}', err['message'] ?? err['type']);
            }
          }
        }
      }
    } catch (_) {}
  }

  void _startErrorPoller() {
    _errorPoller?.cancel();
    _errorPoller = Timer.periodic(const Duration(seconds: 30), (_) {
      fetchBackendErrors();
    });
    fetchBackendErrors();
  }

  // ── Chat & connection state ──

  List<ChatMessage> _chat = [];
  List<ChatMessage> get chat => _chat;
  bool _connected = false;
  bool get connected => _connected;

  SseClient? _sse;
  StreamSubscription<String>? _sseSub;
  Timer? _reconnectTimer;
  http.Client _http = http.Client();

  // ── Exponential backoff state ──
  int _reconnectAttempt = 0;
  static const _maxReconnectDelay = Duration(seconds: 30);

  // ── API calls ──

  Future<bool> checkHealth() async {
    try {
      final res = await _http
          .get(Uri.parse('$_botUrl/health'))
          .timeout(const Duration(seconds: 3));
      _connected = res.statusCode == 200;
      notifyListeners();
      return _connected;
    } catch (e) {
      _setError('checkHealth', e);
      _connected = false;
      notifyListeners();
      return false;
    }
  }

  Future<bool> connectSse() async {
    _reconnectAttempt = 0;
    var ok = await checkHealth();
    if (!ok) return false;

    _sse?.disconnect();
    await _sseSub?.cancel();

    _sse ??= SseClient(_botUrl);
    try {
      _sseSub = _sse!.connect().listen(_handleSseEvent,
          onError: (e) {
            _setError('sseStream', e);
            _scheduleReconnect();
          },
          onDone: () => _scheduleReconnect());
    } catch (e) {
      _setError('connectSse', e);
      _scheduleReconnect();
      return false;
    }

    fetchStatus();
    fetchChat();
    fetchCommands();
    _startErrorPoller();
    _connected = true;
    notifyListeners();
    return true;
  }

  void _handleSseEvent(String raw) {
    final parts = raw.split('\x00');
    if (parts.length == 2) {
      final eventType = parts[0];
      try {
        final data = jsonDecode(parts[1]);
        _dispatchSseEvent(eventType, data);
      } catch (e) {
        _setError('handleSseEvent/$eventType', e);
      }
    } else {
      // Legacy: raw JSON chat message
      try {
        final msg = jsonDecode(raw);
        _chat.insert(0, ChatMessage.fromJson(msg));
        if (_chat.length > 200) _chat = _chat.sublist(0, 200);
        notifyListeners();
      } catch (e) {
        _setError('handleSseEvent/chat', e);
      }
    }
  }

  /// Route a decoded SSE event into state. Public test seam: tests call this
  /// directly with a map instead of going through the SSE transport.
  void handleSseEventForTest(String eventType, Map<String, dynamic> data) =>
      _dispatchSseEvent(eventType, data);

  void _dispatchSseEvent(String eventType, dynamic data) {
    switch (eventType) {
      case 'platform_status':
        _streamStatus = data['live'] == true ? 'live' : 'offline';
        _title = data['title'] ?? _title;
        _game = data['game'] ?? _game;
        _viewers = data['viewers'] ?? _viewers;
        notifyListeners();
        break;
      case 'channel_event':
        _alerts.insert(0, Map<String, dynamic>.from(data));
        if (_alerts.length > 50) _alerts = _alerts.sublist(0, 50);
        _showAlert(data);
        break;
      case 'chat_message':
        _chat.insert(0, ChatMessage.fromJson(Map<String, dynamic>.from(data)));
        if (_chat.length > 200) _chat = _chat.sublist(0, 200);
        notifyListeners();
        break;
    }
  }

  void _scheduleReconnect() {
    _connected = false;
    notifyListeners();
    _reconnectTimer?.cancel();
    _reconnectAttempt++;
    final delay = Duration(
      seconds: _reconnectAttempt > 10
          ? _maxReconnectDelay.inSeconds
          : (5 * _reconnectAttempt).clamp(5, _maxReconnectDelay.inSeconds),
    );
    debugPrint('[provider] reconnect attempt $_reconnectAttempt in ${delay.inSeconds}s');
    _reconnectTimer = Timer(delay, () {
      connectSse();
    });
  }

  void disconnect() {
    _errorPoller?.cancel();
    _errorPoller = null;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _reconnectAttempt = 0;
    _sseSub?.cancel();
    _sseSub = null;
    _sse?.disconnect();
    _sse = null;
    _connected = false;
    notifyListeners();
  }

  Future<void> fetchStatus() async {
    try {
      final res = await _http
          .get(Uri.parse('$_botUrl/stream/status'))
          .timeout(const Duration(seconds: 3));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        _streamStatus = data['status'] ?? 'unknown';
        _viewers = data['viewers'] ?? 0;
        _game = data['game'] ?? '';
        _title = data['title'] ?? '';
        notifyListeners();
      }
    } catch (e) {
      _setError('fetchStatus', e);
    }
  }

  Future<void> fetchChat() async {
    try {
      final res = await _http
          .get(Uri.parse('$_botUrl/chat/recent?count=30'))
          .timeout(const Duration(seconds: 3));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        final messages = data['messages'] as List<dynamic>? ?? [];
        _chat = messages
            .map((m) => ChatMessage.fromJson(m as Map<String, dynamic>))
            .toList();
        notifyListeners();
      }
    } catch (e) {
      _setError('fetchChat', e);
    }
  }

  Future<bool> sendMessage(String text) async {
    try {
      final res = await _http
          .post(Uri.parse('$_botUrl/chat/send'),
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode({'message': text}))
          .timeout(const Duration(seconds: 3));
      return res.statusCode == 200;
    } catch (e) {
      _setError('sendMessage', e);
      return false;
    }
  }

  // ── Moderation ──

  Future<bool> timeoutUser(String user, {int duration = 300}) async {
    try {
      final res = await _http
          .post(Uri.parse('$_botUrl/mod/timeout'),
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode({'user': user, 'duration': duration}))
          .timeout(const Duration(seconds: 3));
      return res.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  Future<bool> banUser(String user) async {
    try {
      final res = await _http
          .post(Uri.parse('$_botUrl/mod/ban'),
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode({'user': user}))
          .timeout(const Duration(seconds: 3));
      return res.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  Future<bool> unbanUser(String user) async {
    try {
      final res = await _http
          .post(Uri.parse('$_botUrl/mod/unban'),
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode({'user': user}))
          .timeout(const Duration(seconds: 3));
      return res.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  Future<bool> clearChat() async {
    try {
      final res = await _http
          .post(Uri.parse('$_botUrl/mod/clear'))
          .timeout(const Duration(seconds: 3));
      return res.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  Future<bool> setChatMode(String mode, bool enabled) async {
    try {
      final res = await _http
          .post(Uri.parse('$_botUrl/mod/chatmode'),
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode({'mode': mode, 'enabled': enabled}))
          .timeout(const Duration(seconds: 3));
      return res.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  @override
  void dispose() {
    _alertTimer?.cancel();
    disconnect();
    super.dispose();
  }
}