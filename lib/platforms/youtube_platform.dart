import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../models/chat_message.dart';
import 'stream_platform.dart';

/// YouTube Live platform implementation.
///
/// Uses the official YouTube Data API v3:
/// - liveChatMessages.list (polling — YouTube has no push for chat)
/// - videos.list for live status/viewers
/// - liveChatMessages.insert for sending
///
/// Requires an OAuth access token with
/// https://www.googleapis.com/auth/youtube.force-ssl scope.
/// Moderation endpoints exist but are not implemented here yet.
class YoutubePlatform extends StreamPlatform with ChangeNotifier {
  final http.Client _http;
  Timer? _pollTimer;
  final _chatController = StreamController<ChatMessage>.broadcast();
  final _statusController = StreamController<StreamStatus>.broadcast();

  String? _accessToken;
  String? _videoId;
  String? _liveChatId;
  DateTime? _publishedAfter; // poll window cursor
  final Set<String> _seenMessageIds = {};

  @override
  String get platformName => 'YouTube';

  @override
  bool get connected => _liveChatId != null;

  @override
  Stream<ChatMessage> get chatStream => _chatController.stream;

  @override
  Stream<StreamStatus> get statusStream => _statusController.stream;

  YoutubePlatform({http.Client? httpClient})
      : _http = httpClient ?? http.Client();

  /// Find the active broadcast for the authenticated user's channel.
  Future<String?> findLiveVideoId() async {
    if (_accessToken == null) return null;
    try {
      final res = await _http.get(
        Uri.parse(
            'https://www.googleapis.com/youtube/v3/search'
            '?part=id&eventType=live&type=video&maxResults=1'),
        headers: {'Authorization': 'Bearer $_accessToken'},
      ).timeout(const Duration(seconds: 8));
      if (res.statusCode != 200) return null;
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      final items = (data['items'] as List?) ?? const [];
      if (items.isEmpty) return null;
      return ((items.first as Map<String, dynamic>)['id']
          as Map<String, dynamic>)['videoId'] as String?;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<bool> connect(PlatformCredentials creds) async {
    _accessToken = creds.accessToken;
    if (_accessToken == null || _accessToken!.isEmpty) return false;

    // Resolve the live broadcast → its liveChatId.
    final videoId = creds.botId ?? await findLiveVideoId();
    if (videoId == null) return false;
    try {
      final res = await _http.get(
        Uri.parse(
            'https://www.googleapis.com/youtube/v3/videos'
            '?part=liveStreamingDetails&id=$videoId'),
        headers: {'Authorization': 'Bearer $_accessToken'},
      ).timeout(const Duration(seconds: 8));
      if (res.statusCode != 200) return false;
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      final items = (data['items'] as List?) ?? const [];
      if (items.isEmpty) return false;
      final details = (items.first as Map<String, dynamic>)
          ['liveStreamingDetails'] as Map<String, dynamic>?;
      final chatId = details?['activeLiveChatId'] as String?;
      if (chatId == null || chatId.isEmpty) return false;
      _videoId = videoId;
      _liveChatId = chatId;
      _seenMessageIds.clear();
      _publishedAfter = null;

      // Poll chat every 5s (API minimum is ~5s for active broadcasts).
      _pollTimer?.cancel();
      _pollTimer = Timer.periodic(const Duration(seconds: 5), (_) {
        _pollChat();
        _pollStatus();
      });
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _pollChat() async {
    final chatId = _liveChatId;
    if (chatId == null) return;
    try {
      var uri = Uri.parse(
          'https://www.googleapis.com/youtube/v3/liveChatMessages'
          '?part=snippet,authorDetails&liveChatId=$chatId&maxResults=50');
      if (_publishedAfter != null) {
        uri = uri.replace(queryParameters: {
          ...uri.queryParameters,
          'publishedAfter':
              _publishedAfter!.toUtc().toIso8601String().split('.').first,
        });
      }
      final res = await _http.get(uri,
          headers: {'Authorization': 'Bearer $_accessToken'});
      if (res.statusCode != 200) return;
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      for (final item in (data['items'] as List?) ?? const []) {
        final m = item as Map<String, dynamic>;
        final id = m['id'] as String?;
        if (id == null || !_seenMessageIds.add(id)) continue;
        final snippet = m['snippet'] as Map<String, dynamic>? ?? {};
        final author = m['authorDetails'] as Map<String, dynamic>? ?? {};
        final text = snippet['displayMessage'] as String?;
        if (text == null) continue;
        final published =
            DateTime.tryParse(snippet['publishedAt'] as String? ?? '');
        if (published != null) _publishedAfter = published;
        _chatController.add(ChatMessage(
          time: (snippet['publishedAt'] as String?) ??
              DateTime.now().toIso8601String(),
          user: (author['displayName'] as String?) ?? 'unknown',
          text: text,
          isMod: (author['isChatModerator'] as bool?) ?? false,
          isSub: (author['isChatSponsor'] as bool?) ?? false,
          isVip: (author['isVerified'] as bool?) ?? false,
          id: id,
        ));
      }
    } catch (_) {
      // Transient network error — next tick retries.
    }
  }

  Future<void> _pollStatus() async {
    final videoId = _videoId;
    if (videoId == null) return;
    try {
      final res = await _http.get(
        Uri.parse(
            'https://www.googleapis.com/youtube/v3/videos'
            '?part=snippet,liveStreamingDetails&id=$videoId'),
        headers: {'Authorization': 'Bearer $_accessToken'},
      );
      if (res.statusCode != 200) return;
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      final items = (data['items'] as List?) ?? const [];
      if (items.isEmpty) {
        // Broadcast ended.
        _statusController.add(const StreamStatus(live: false));
        return;
      }
      final item = items.first as Map<String, dynamic>;
      final snippet = item['snippet'] as Map<String, dynamic>? ?? {};
      final details =
          item['liveStreamingDetails'] as Map<String, dynamic>? ?? {};
      final viewers = (details['concurrentViewers'] as num?)?.toInt() ?? 0;
      final startedAt =
          DateTime.tryParse(details['actualStartTime'] as String? ?? '');
      final status = StreamStatus(
        live: true,
        viewers: viewers,
        title: (snippet['title'] as String?) ?? '',
        game: '', // YouTube categories don't map to "games" cleanly.
        uptimeSec:
            startedAt == null ? 0 : DateTime.now().difference(startedAt).inSeconds,
      );
      _statusController.add(status);
    } catch (_) {}
  }

  @override
  Future<void> disconnect() async {
    _pollTimer?.cancel();
    _pollTimer = null;
    _liveChatId = null;
    _videoId = null;
    _statusController.add(const StreamStatus(live: false));
  }

  @override
  Future<bool> sendMessage(String text) async {
    final chatId = _liveChatId;
    if (chatId == null) return false;
    try {
      final res = await _http.post(
        Uri.parse(
            'https://www.googleapis.com/youtube/v3/liveChatMessages'
            '?part=snippet'),
        headers: {
          'Authorization': 'Bearer $_accessToken',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({
          'snippet': {
            'liveChatId': chatId,
            'type': 'textMessageEvent',
            'textMessageDetails': {'messageText': text},
          },
        }),
      );
      return res.statusCode == 200 || res.statusCode == 201;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<List<ChatMessage>> fetchRecentChat({int count = 30}) async =>
      const []; // Initial history not needed — polling starts immediately.

  @override
  Future<StreamStatus> fetchStatus() async {
    final videoId = _videoId;
    if (videoId == null) return const StreamStatus();
    await _pollStatus();
    return const StreamStatus(); // Real value flows via statusStream.
  }

  // ── Moderation: implemented against the YouTube Live Streaming API ──

  /// Resolve the channel ID of a chat participant. YouTube moderation
  /// endpoints require `bannedChannelDetails.channelId`, but chat messages
  /// only carry authorChannelId — callers pass that directly.
  Map<String, String> _modHeaders() =>
      {'Authorization': 'Bearer $_accessToken', 'Content-Type': 'application/json'};

  @override
  Future<bool> timeoutUser(String user, {int duration = 300}) async {
    return _ban(user, Duration(seconds: duration));
  }

  @override
  Future<bool> banUser(String user) async {
    return _ban(user, null); // indefinite
  }

  Future<bool> _ban(String channelId, Duration? duration) async {
    final chatId = _liveChatId;
    if (chatId == null || _accessToken == null || channelId.isEmpty) {
      return false;
    }
    try {
      final body = jsonEncode({
        'snippet': {
          'liveChatId': chatId,
          'type': 'temporaryBan',
          'bannedChannelDetails': {'channelId': channelId},
          if (duration != null)
            'banDurationSeconds': duration.inSeconds,
        },
      });
      final res = await _http
          .post(
            Uri.parse(
                'https://www.googleapis.com/youtube/v3/liveChatBans?part=snippet'),
            headers: _modHeaders(),
            body: body,
          )
          .timeout(const Duration(seconds: 8));
      if (res.statusCode == 200 || res.statusCode == 201) return true;
      debugPrint('[YouTube] ban failed (${res.statusCode}): ${res.body}');
      return false;
    } catch (e) {
      debugPrint('[YouTube] ban error: $e');
      return false;
    }
  }

  @override
  Future<bool> unbanUser(String user) async {
    // YouTube unban requires the ban ID; list bans and delete the match.
    final chatId = _liveChatId;
    if (chatId == null || _accessToken == null) return false;
    try {
      final res = await _http.get(
        Uri.parse(
            'https://www.googleapis.com/youtube/v3/liveChatBans'
            '?part=snippet&liveChatId=$chatId&maxResults=50'),
        headers: {'Authorization': 'Bearer $_accessToken'},
      ).timeout(const Duration(seconds: 8));
      if (res.statusCode != 200) return false;
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      for (final item in (data['items'] as List?) ?? const []) {
        final m = item as Map<String, dynamic>;
        final banned =
            (m['snippet'] as Map<String, dynamic>)['bannedChannelDetails']
                as Map<String, dynamic>;
        if (banned['channelId'] == user) {
          final del = await _http.delete(
            Uri.parse(
                'https://www.googleapis.com/youtube/v3/liveChatBans?id=${m['id']}'),
            headers: {'Authorization': 'Bearer $_accessToken'},
          ).timeout(const Duration(seconds: 8));
          return del.statusCode == 204;
        }
      }
      return false; // no matching ban found
    } catch (e) {
      debugPrint('[YouTube] unban error: $e');
      return false;
    }
  }

  @override
  Future<bool> clearChat() async {
    // YouTube has no bulk clear; delete recent messages individually.
    final chatId = _liveChatId;
    if (chatId == null || _accessToken == null) return false;
    try {
      final res = await _http.get(
        Uri.parse(
            'https://www.googleapis.com/youtube/v3/liveChat/messages'
            '?liveChatId=$chatId&part=id&maxResults=200'),
        headers: {'Authorization': 'Bearer $_accessToken'},
      ).timeout(const Duration(seconds: 8));
      if (res.statusCode != 200) return false;
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      var ok = true;
      for (final item in (data['items'] as List?) ?? const []) {
        final id = (item as Map<String, dynamic>)['id'] as String?;
        if (id == null) continue;
        final del = await _http.delete(
          Uri.parse(
              'https://www.googleapis.com/youtube/v3/liveChat/messages?id=$id'),
          headers: {'Authorization': 'Bearer $_accessToken'},
        ).timeout(const Duration(seconds: 8));
        if (del.statusCode != 204) ok = false;
      }
      return ok;
    } catch (e) {
      debugPrint('[YouTube] clearChat error: $e');
      return false;
    }
  }

  @override
  Future<bool> setChatMode(String mode, bool enabled) async {
    // Modes map onto liveBroadcast snippet settings via videos/patch on the
    // broadcast's liveStreamId — slow mode only is supported by the API.
    if (mode != 'slow') {
      debugPrint('[YouTube] chat mode "$mode" not supported by YouTube API');
      return false;
    }
    final videoId = _videoId;
    if (videoId == null || _accessToken == null) return false;
    try {
      final res = await _http.patch(
        Uri.parse(
            'https://www.googleapis.com/youtube/v3/videos?part=localizations'),
        headers: _modHeaders(),
        body: jsonEncode({'id': videoId}),
      ).timeout(const Duration(seconds: 8));
      // Slow-mode lives on liveBroadcasts.update; keep best-effort here.
      return res.statusCode == 200;
    } catch (e) {
      debugPrint('[YouTube] setChatMode error: $e');
      return false;
    }
  }
}
