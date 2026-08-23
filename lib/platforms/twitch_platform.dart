import 'dart:async';
import 'package:flutter/foundation.dart';
import 'stream_platform.dart';
import '../models/chat_message.dart';
import '../models/channel_event.dart';
import 'twitch_auth.dart';
import 'twitch_irc_client.dart';
import 'twitch_helix_client.dart';
import 'twitch_eventsub_client.dart';

/// Twitch platform implementation.
///
/// Wires together OAuth, IRC chat, and Helix API into the StreamPlatform interface.
class TwitchPlatform extends StreamPlatform with ChangeNotifier {
  @override
  String get platformName => 'Twitch';

  TwitchAuth get auth => _auth;
  final TwitchAuth _auth = TwitchAuth();
  late final TwitchHelixClient _helix;

  TwitchIrcClient? _irc;
  TwitchEventSubClient? _eventSub;
  StreamSubscription? _eventSubSub;
  Timer? _statusPoller;
  StreamController<ChatMessage>? _chatController;
  StreamController<StreamStatus>? _statusController;
  StreamController<ChannelEvent>? _eventController;
  bool _connected = false;

  @override
  bool get connected => _connected;

  String? _channelName;
  String? _broadcasterId;
  String? _moderatorId;

  TwitchPlatform({TwitchHelixClient? helixClient, TwitchIrcClient? ircClient, TwitchEventSubClient? eventSubClient}) {
    _helix = helixClient ?? TwitchHelixClient(auth);
    _irc = ircClient;
    _eventSub = eventSubClient;
    _chatController = StreamController<ChatMessage>.broadcast();
    _statusController = StreamController<StreamStatus>.broadcast();
    _eventController = StreamController<ChannelEvent>.broadcast();
  }

  @override
  Stream<ChatMessage> get chatStream => _chatController!.stream;

  @override
  Stream<StreamStatus> get statusStream => _statusController!.stream;

  /// Channel events (subs, raids) surfaced for alerts.
  Stream<ChannelEvent> get eventStream => _eventController!.stream;

  /// Configure Twitch app credentials.
  void configure({
    required String clientId,
    required String clientSecret,
  }) {
    auth.configure(clientId: clientId, clientSecret: clientSecret);
  }

  @override
  Future<bool> connect(PlatformCredentials creds) async {
    _channelName = creds.channelName;

    // Load saved tokens or use provided ones
    if (creds.accessToken != null) {
      // Tokens provided directly (e.g., from settings form)
      // For now, we use the OAuth flow via browser
    }

    // Try loading saved tokens first
    final hasTokens = await auth.loadTokens();
    if (!hasTokens) {
      debugPrint('[TwitchPlatform] No saved tokens — user needs to authorize');
      return false;
    }

    // Load channel name from prefs if not provided
    if (_channelName == null || _channelName!.isEmpty) {
      _channelName = await auth.loadChannelName();
    }

    // Ensure token is valid
    final tokenValid = await auth.ensureValidToken();
    if (!tokenValid) {
      debugPrint('[TwitchPlatform] Token invalid');
      return false;
    }

    // Resolve broadcaster ID if we have a channel name
    if (_channelName != null && auth.broadcasterId == null) {
      final id = await _helix.resolveUserId(_channelName!);
      if (id != null) {
        auth.setBroadcasterId(id);
        _broadcasterId = id;
        _moderatorId = auth.botId;
      }
    }

    // Connect IRC
    final botName = _channelName ?? 'justinfan12345';
    final token = auth.accessToken ?? '';

    _irc ??= TwitchIrcClient(
      username: botName,
      oauthToken: token,
      channel: _channelName ?? botName,
    );

    final ircOk = await _irc!.connect();
    if (!ircOk) {
      debugPrint('[TwitchPlatform] IRC connection failed');
      return false;
    }

    // Wire IRC messages to our chat stream
    _irc!.messages.listen((msg) {
      _chatController?.add(msg);
    });

    // Wire IRC USERNOTICE to our event stream
    _irc!.events.listen((event) {
      _eventController?.add(event);
    });

    // Connect EventSub for follows/cheers/raids (websocket transport).
    try {
      _eventSub ??= TwitchEventSubClient(
        auth: auth,
        userIdProvider: () => _broadcasterId,
      );
      await _eventSub!.connect();
      _eventSubSub?.cancel();
      _eventSubSub = _eventSub!.events.listen((event) {
        _eventController?.add(event);
      });
    } catch (e) {
      debugPrint('[TwitchPlatform] EventSub connect failed (non-fatal): $e');
    }

    // Start polling stream status
    _startStatusPolling();

    _connected = true;
    notifyListeners();
    return true;
  }

  @override
  Future<void> disconnect() async {
    _statusPoller?.cancel();
    _irc?.disconnect();
    _eventSub?.dispose();
    _eventSubSub?.cancel();
    _eventSub = null;
    _connected = false;
    notifyListeners();
  }

  void _startStatusPolling() {
    _statusPoller?.cancel();
    _statusPoller = Timer.periodic(const Duration(seconds: 30), (_) async {
      if (_broadcasterId == null) return;
      final twitchStatus = await _helix.fetchStreamStatus(_broadcasterId!);
      _statusController?.add(StreamStatus(
        live: twitchStatus.live,
        viewers: twitchStatus.viewers,
        game: twitchStatus.game,
        title: twitchStatus.title,
        uptimeSec: twitchStatus.uptimeSec,
      ));
    });
    // Fetch immediately
    if (_broadcasterId != null) {
      _helix.fetchStreamStatus(_broadcasterId!).then((s) {
        _statusController?.add(StreamStatus(
          live: s.live,
          viewers: s.viewers,
          game: s.game,
          title: s.title,
          uptimeSec: s.uptimeSec,
        ));
      });
    }
  }

  @override
  Future<bool> sendMessage(String text) async {
    return _irc?.sendMessage(text) ?? false;
  }

  @override
  Future<List<ChatMessage>> fetchRecentChat({int count = 30}) async {
    // Twitch IRC doesn't have a history API — return empty
    // The chat stream provides real-time messages
    return [];
  }

  @override
  Future<StreamStatus> fetchStatus() async {
    if (_broadcasterId == null) {
      return const StreamStatus();
    }
    final s = await _helix.fetchStreamStatus(_broadcasterId!);
    return StreamStatus(
      live: s.live,
      viewers: s.viewers,
      game: s.game,
      title: s.title,
      uptimeSec: s.uptimeSec,
    );
  }

  // ── Moderation ──

  @override
  Future<bool> timeoutUser(String user, {int duration = 300}) async {
    if (_broadcasterId == null || _moderatorId == null) return false;
    final userId = await _helix.resolveUserId(user);
    if (userId == null) return false;
    return _helix.timeoutUser(_broadcasterId!, _moderatorId!, userId, duration: duration);
  }

  @override
  Future<bool> banUser(String user) async {
    if (_broadcasterId == null || _moderatorId == null) return false;
    final userId = await _helix.resolveUserId(user);
    if (userId == null) return false;
    return _helix.banUser(_broadcasterId!, _moderatorId!, userId);
  }

  @override
  Future<bool> unbanUser(String user) async {
    if (_broadcasterId == null || _moderatorId == null) return false;
    final userId = await _helix.resolveUserId(user);
    if (userId == null) return false;
    return _helix.unbanUser(_broadcasterId!, _moderatorId!, userId);
  }

  @override
  Future<bool> clearChat() async {
    if (_broadcasterId == null || _moderatorId == null) return false;
    return _helix.clearChat(_broadcasterId!, _moderatorId!);
  }

  @override
  Future<bool> setChatMode(String mode, bool enabled) async {
    if (_broadcasterId == null || _moderatorId == null) return false;
    return _helix.setChatMode(_broadcasterId!, _moderatorId!, mode, enabled);
  }

  /// Get the authorization URL for the OAuth flow.
  String get authorizationUrl => auth.authorizationUrl;

  /// Handle the OAuth callback with the authorization code.
  Future<bool> handleAuthCallback(String code) async {
    final ok = await auth.exchangeCode(code);
    if (ok) {
      _broadcasterId = auth.broadcasterId;
      _moderatorId = auth.botId;
    }
    return ok;
  }

  @override
  void dispose() {
    disconnect();
    _chatController?.close();
    _eventController?.close();
    _statusController?.close();
    _helix.dispose();
    super.dispose();
  }
}
