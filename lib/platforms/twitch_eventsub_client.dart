import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import '../models/channel_event.dart';
import 'twitch_auth.dart';

/// Twitch EventSub websocket client.
///
/// Connects to Twitch's EventSub WebSocket transport (no public webhook
/// endpoint needed) and subscribes to channel events using the user's
/// existing OAuth token. Emits [ChannelEvent]s for follows, cheers, and
/// raids — complementing the IRC USERNOTICE parsing in [TwitchPlatform]
/// (which already covers subs/resubs/gifts).
///
/// Reconnect logic: Twitch sends `session_welcome` with a keepalive
/// timeout; on close or timeout we reconnect with exponential backoff.
class TwitchEventSubClient {
  TwitchEventSubClient({required this.auth, this.userIdProvider});

  final TwitchAuth auth;
  final String? Function()? userIdProvider;

  WebSocketChannel? _ws;
  StreamSubscription? _sub;
  Timer? _keepaliveTimer;
  Timer? _reconnectTimer;
  int _backoffSeconds = 1;
  bool _disposed = false;
  String? _sessionId;

  static const _url = 'wss://eventsub.wss.twitch.tv/ws';

  final _eventsController = StreamController<ChannelEvent>.broadcast();
  /// Follows / cheers / raids as parsed ChannelEvents.
  Stream<ChannelEvent> get events => _eventsController.stream;
  bool get connected => _ws != null && _sessionId != null;

  Future<void> connect() async {
    if (_disposed || auth.accessToken == null) return;
    try {
      _ws = WebSocketChannel.connect(Uri.parse(_url));
      _sub = _ws!.stream.listen(_onMessage,
          onError: (_) => _scheduleReconnect(),
          onDone: () => _scheduleReconnect());
    } catch (e) {
      debugPrint('[EventSub] connect failed: $e');
      _scheduleReconnect();
    }
  }

  void _onMessage(dynamic raw) {
    try {
      final frame = jsonDecode(raw as String) as Map<String, dynamic>;
      final metadata = frame['metadata'] as Map<String, dynamic>? ?? {};
      final type = metadata['message_type'] as String?;
      final payload =
          frame['payload'] as Map<String, dynamic>? ?? const {};

      switch (type) {
        case 'session_welcome':
          _sessionId = payload['session']?['id'] as String?;
          _resetBackoff();
          _subscribeToEvents();
          break;
        case 'session_keepalive':
          _restartKeepaliveTimer();
          break;
        case 'notification':
          _handleNotification(payload['event'] as Map<String, dynamic>? ?? {},
              payload['subscription']
                      ?['type'] as String? ??
                  '');
          break;
        case 'session_reconnect':
          // Twitch asks us to reconnect to a new URL.
          _scheduleReconnect();
          break;
        case 'revocation':
          debugPrint('[EventSub] subscription revoked: ${payload['subscription']}');
          break;
      }
    } catch (e) {
      debugPrint('[EventSub] bad frame: $e');
    }
  }

  Future<void> _subscribeToEvents() async {
    final token = auth.accessToken;
    final clientId = auth.clientId;
    final userId = userIdProvider?.call() ?? auth.broadcasterId ?? '';
    if (token == null || clientId == null || clientId.isEmpty || userId.isEmpty) {
      return;
    }

    const types = [
      'channel.follow',
      'channel.cheer',
      'channel.raid',
    ];
    for (final type in types) {
      try {
        final res = await _httpPost(
          'https://api.twitch.tv/helix/eventsub/subscriptions',
          {
            'type': versionedType(type),
            'version': type == 'channel.follow' ? '2' : '1',
            'transport': {'method': 'websocket', 'session_id': _sessionId},
            if (type == 'channel.follow')
              'condition': {'broadcaster_user_id': userId, 'moderator_user_id': userId}
            else
              'condition': {'broadcaster_user_id': userId},
          },
          token,
          clientId,
        );
        if (res.statusCode != 202) {
          debugPrint('[EventSub] subscribe $type -> ${res.statusCode}');
        }
      } catch (e) {
        debugPrint('[EventSub] subscribe $type failed: $e');
      }
    }
  }

  void _handleNotification(Map<String, dynamic> event, String subType) {
    _restartKeepaliveTimer();
    final user = event['user_name'] as String? ?? '?';
    switch (subType) {
      case 'channel.follow':
        _emit(ChannelEvent(
            type: 'follow', user: user, time: DateTime.now().toIso8601String()));
      case 'channel.cheer':
        _emit(ChannelEvent(
            type: 'cheer',
            user: user,
            count: event['bits'] is int ? event['bits'] as int : null,
            message: event['message'] as String?,
            time: DateTime.now().toIso8601String()));
      case 'channel.raid':
        _emit(ChannelEvent(
            type: 'raid',
            user: event['from_broadcaster_user_name'] as String? ?? user,
            count: event['viewers'] is int ? event['viewers'] as int : null,
            time: DateTime.now().toIso8601String()));
    }
  }

  void _emit(ChannelEvent e) {
    if (!_eventsController.isClosed) _eventsController.add(e);
  }

  /// Parse one raw websocket frame; returns the emitted [ChannelEvent]
  /// or null for non-notification frames. Also used by tests.
  ChannelEvent? parseFrame(String raw) {
    ChannelEvent? out;
    try {
      final frame = jsonDecode(raw) as Map<String, dynamic>;
      final metadata = frame['metadata'] as Map<String, dynamic>? ?? {};
      if (metadata['message_type'] != 'notification') return null;
      final payload = frame['payload'] as Map<String, dynamic>? ?? {};
      final event = payload['event'] as Map<String, dynamic>? ?? {};
      final subType =
          payload['subscription']?['type'] as String? ?? '';
      final user = event['user_name'] as String? ?? '?';
      switch (subType) {
        case 'channel.follow':
          out = ChannelEvent(
              type: 'follow', user: user, time: DateTime.now().toIso8601String());
        case 'channel.cheer':
          out = ChannelEvent(
              type: 'cheer',
              user: user,
              count: event['bits'] is int ? event['bits'] as int : null,
              message: event['message'] as String?,
              time: DateTime.now().toIso8601String());
        case 'channel.raid':
          out = ChannelEvent(
              type: 'raid',
              user: event['from_broadcaster_user_name'] as String? ?? user,
              count: event['viewers'] is int ? event['viewers'] as int : null,
              time: DateTime.now().toIso8601String());
      }
      // ignore: avoid_catches_without_on_exceptions
    } catch (e) {
      debugPrint('[EventSub] parseFrame error: $e');
    }
    return out;
  }

  Future<HttpPostResponse> _httpPost(String url, Map<String, dynamic> body,
      String token, String clientId) {
    return eventSubHttpPoster(url, body, token, clientId);
  }

  String versionedType(String type) => type;

  // Keepalive: Twitch sends keepalives ~every 10s; timeout → reconnect.
  void _restartKeepaliveTimer() {
    _keepaliveTimer?.cancel();
    _keepaliveTimer = Timer(const Duration(seconds: 30), () {
      debugPrint('[EventSub] keepalive timeout — reconnecting');
      _closeSocket();
      _scheduleReconnect();
    });
  }

  void _scheduleReconnect() {
    if (_disposed) return;
    _sessionId = null;
    _keepaliveTimer?.cancel();
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(Duration(seconds: _backoffSeconds), () {
      _backoffSeconds = (_backoffSeconds * 2).clamp(1, 60);
      connect();
    });
  }

  void _resetBackoff() => _backoffSeconds = 1;

  void _closeSocket() {
    _sub?.cancel();
    _ws?.sink.close().catchError((_) {});
    _ws = null;
  }

  void dispose() {
    _disposed = true;
    _reconnectTimer?.cancel();
    _keepaliveTimer?.cancel();
    _closeSocket();
    _eventsController.close();
  }
}

// ── HTTP + test seams ──

/// Overridable POST used by [TwitchEventSubClient._httpPost].
Future<HttpPostResponse> Function(String url, Map<String, dynamic> body,
        String token, String clientId)
    eventSubHttpPoster = defaultEventSubHttpPost;

class HttpPostResponse {
  final int statusCode;
  HttpPostResponse(this.statusCode);
}

Future<HttpPostResponse> defaultEventSubHttpPost(String url,
    Map<String, dynamic> body, String token, String clientId) async {
  final client = HttpClient();
  try {
    final req = await client.postUrl(Uri.parse(url));
    req.headers.set('Authorization', 'Bearer $token');
    req.headers.set('Client-Id', clientId);
    req.headers.set('Content-Type', 'application/json');
    req.add(utf8.encode(jsonEncode(body)));
    final res = await req.close();
    await res.drain<void>();
    return HttpPostResponse(res.statusCode);
  } finally {
    client.close();
  }
}

/// Parse one raw frame exactly like the live handler; returns the emitted
/// ChannelEvent or null. Test seam.
ChannelEvent? parseFrameForTest(TwitchEventSubClient owner, String raw) =>
    owner.parseFrame(raw);
