import 'package:flutter_test/flutter_test.dart';
import 'package:streamer_co_pilot/platforms/twitch_auth.dart';
import 'package:streamer_co_pilot/platforms/twitch_eventsub_client.dart';

void main() {
  group('TwitchEventSubClient.parseFrame', () {
    late TwitchEventSubClient client;

    setUp(() {
      client = TwitchEventSubClient(auth: TwitchAuth());
    });

    test('parses a channel.follow notification', () {
      final event = client.parseFrame(_frame('channel.follow', {
        'user_name': 'alice',
      }));
      expect(event, isNotNull);
      expect(event!.type, 'follow');
      expect(event.user, 'alice');
    });

    test('parses a channel.cheer notification with bits', () {
      final event = client.parseFrame(_frame('channel.cheer', {
        'user_name': 'bob',
        'bits': 500,
        'message': 'great stream!',
      }));
      expect(event, isNotNull);
      expect(event!.type, 'cheer');
      expect(event.user, 'bob');
      expect(event.count, 500);
      expect(event.message, 'great stream!');
    });

    test('parses a channel.raid notification', () {
      final event = client.parseFrame(_frame('channel.raid', {
        'from_broadcaster_user_name': 'carol',
        'viewers': 42,
      }));
      expect(event, isNotNull);
      expect(event!.type, 'raid');
      expect(event.user, 'carol');
      expect(event.count, 42);
    });

    test('returns null for keepalive frames', () {
      const raw =
          '{"metadata":{"message_type":"session_keepalive"},"payload":{}}';
      expect(client.parseFrame(raw), isNull);
    });

    test('returns null for malformed JSON', () {
      expect(client.parseFrame('not json'), isNull);
    });
  });
}

String _frame(String subType, Map<String, dynamic> event) =>
    '{"metadata":{"message_type":"notification"},'
    '"payload":{"subscription":{"type":"$subType"},'
    '"event":${_json(event)}}}';

String _json(Map<String, dynamic> m) => '{${m.entries.map((e) {
      final v = e.value;
      final encoded = v is int ? '$v' : '"$v"';
      return '"${e.key}":$encoded';
    }).join(',')}}';
