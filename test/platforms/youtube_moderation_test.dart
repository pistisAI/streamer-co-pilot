import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:streamer_co_pilot/platforms/stream_platform.dart';
import 'package:streamer_co_pilot/platforms/youtube_platform.dart';

http.Response _json(Object body, {int status = 200}) =>
    http.Response(jsonEncode(body), status, headers: {
      'content-type': 'application/json',
    });

void main() {
  Future<YoutubePlatform> connected({
    required MockClient mock,
    List<String> banIds = const [],
  }) async {
    final yt = YoutubePlatform(httpClient: mock);
    // connect() → search (find video) → videos (liveChatId)
    final ok = await yt.connect(PlatformCredentials(
      channelName: 'chan',
      accessToken: 'tok',
      botId: 'vid123',
    ));
    expect(ok, isTrue);
    return yt;
  }

  test('banUser posts liveChatBan and returns true', () async {
    var posted = <String>[];
    final mock = MockClient((req) async {
      if (req.url.host.contains('googleapis') &&
          req.method == 'POST' &&
          req.url.path.endsWith('liveChatBans')) {
        posted.add(req.body);
        return _json({'id': 'b1'}, status: 201);
      }
      if (req.method == 'GET' && req.url.path.endsWith('videos')) {
        return _json({
          'items': [
            {
              'liveStreamingDetails': {'activeLiveChatId': 'chat1'}
            }
          ]
        });
      }
      return _json({});
    });
    final yt = await connected(mock: mock);

    expect(await yt.banUser('UC123'), isTrue);
    expect(posted, hasLength(1));
    final body = jsonDecode(posted.single) as Map<String, dynamic>;
    final snippet = body['snippet'] as Map<String, dynamic>;
    expect(snippet['liveChatId'], 'chat1');
    expect(snippet['type'], 'temporaryBan');
    expect(snippet['banDurationSeconds'], isNull);
  });

  test('timeoutUser includes duration seconds', () async {
    var posted = <String>[];
    final mock = MockClient((req) async {
      if (req.method == 'POST' && req.url.path.endsWith('liveChatBans')) {
        posted.add(req.body);
        return _json({'id': 'b2'}, status: 201);
      }
      if (req.method == 'GET' && req.url.path.endsWith('videos')) {
        return _json({
          'items': [
            {
              'liveStreamingDetails': {'activeLiveChatId': 'chat1'}
            }
          ]
        });
      }
      return _json({});
    });
    final yt = await connected(mock: mock);

    expect(await yt.timeoutUser('UC9', duration: 60), isTrue);
    final snippet =
        (jsonDecode(posted.single) as Map<String, dynamic>)['snippet']
            as Map<String, dynamic>;
    expect(snippet['banDurationSeconds'], 60);
  });

  test('unbanUser lists bans and deletes the matching one', () async {
    String? deletedId;
    final mock = MockClient((req) async {
      if (req.method == 'GET' && req.url.path.endsWith('liveChatBans')) {
        return _json({
          'items': [
            {
              'id': 'banX',
              'snippet': {
                'bannedChannelDetails': {'channelId': 'UC77'}
              }
            },
          ]
        });
      }
      if (req.method == 'DELETE' &&
          req.url.pathSegments.last == 'liveChatBans') {
        deletedId = req.url.queryParameters['id'];
        return http.Response('', 204);
      }
      if (req.method == 'GET' && req.url.path.endsWith('videos')) {
        return _json({
          'items': [
            {
              'liveStreamingDetails': {'activeLiveChatId': 'chat1'}
            }
          ]
        });
      }
      return _json({});
    });
    final yt = await connected(mock: mock);

    expect(await yt.unbanUser('UC77'), isTrue);
    expect(deletedId, 'banX');

    expect(await yt.unbanUser('UC-nope'), isFalse);
  });

  test('clearChat deletes each recent message id', () async {
    final deleted = <String>[];
    final mock = MockClient((req) async {
      if (req.method == 'GET' && req.url.path.endsWith('messages')) {
        return _json({
          'items': [
            {'id': 'm1'},
            {'id': 'm2'},
          ]
        });
      }
      if (req.method == 'DELETE' &&
          req.url.pathSegments.last == 'messages') {
        deleted.add(req.url.queryParameters['id']!);
        return http.Response('', 204);
      }
      if (req.method == 'GET' && req.url.path.endsWith('videos')) {
        return _json({
          'items': [
            {
              'liveStreamingDetails': {'activeLiveChatId': 'chat1'}
            }
          ]
        });
      }
      return _json({});
    });
    final yt = await connected(mock: mock);

    expect(await yt.clearChat(), isTrue);
    expect(deleted, ['m1', 'm2']);
  });

  test('moderation fails cleanly when not connected or API errors', () async {
    final yt = YoutubePlatform(httpClient: MockClient((req) async => _json({})));
    expect(await yt.banUser('UC1'), isFalse);

    final mock = MockClient((req) async {
      if (req.method == 'POST' && req.url.path.endsWith('liveChatBans')) {
        return _json({'error': {}}, status: 403);
      }
      if (req.method == 'GET' && req.url.path.endsWith('videos')) {
        return _json({
          'items': [
            {
              'liveStreamingDetails': {'activeLiveChatId': 'chat1'}
            }
          ]
        });
      }
      return _json({});
    });
    final yt2 = await connected(mock: mock);
    expect(await yt2.banUser('UC1'), isFalse);
  });
}
