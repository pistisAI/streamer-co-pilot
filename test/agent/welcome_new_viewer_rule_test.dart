import 'package:flutter_test/flutter_test.dart';
import 'package:streamer_co_pilot/agent/agent_client.dart';
import 'package:streamer_co_pilot/agent/decision_loop.dart';

class FakeAgentClient implements AgentClient {
  final List<String> sent = [];
  @override
  Future<CommandResult> sendCommand(String command,
      [Map<String, dynamic>? params]) async {
    sent.add('$command:${params?['message'] ?? ''}');
    return const CommandResult(success: true, message: 'ok');
  }
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

AgentState _state({List<String> chat = const [], bool connected = true}) {
  return AgentState(
    obsConnected: false,
    scenes: const [],
    streaming: false,
    recording: false,
    streamDurationSec: 0,
    sources: const [],
    audioChannels: const [],
    platformConnected: connected,
    chatMessageCount: chat.length,
    recentChatPreview: chat,
  );
}

void main() {
  test('greets a first-time chatter with their name', () async {
    final greeted = <String>{};
    final rule = welcomeNewViewerRule(greetedUsers: greeted);
    final client = FakeAgentClient();
    final state = _state(chat: ['alice: hi everyone']);

    expect(rule.condition(state), isTrue);
    final result = await rule.action(client, state);
    expect(result.success, isTrue);
    expect(client.sent.single, contains('alice'));
    expect(greeted, contains('alice'));
  });

  test('does not greet the same user twice', () async {
    final greeted = <String>{};
    final client = FakeAgentClient();
    final state = _state(chat: ['bob: hello']);

    var rule = welcomeNewViewerRule(greetedUsers: greeted);
    await rule.action(client, state);
    expect(rule.condition(_state(chat: ['bob: again'])), isFalse);
    expect(client.sent.length, 1);
  });

  test('no condition met when all chatters already greeted', () {
    final greeted = {'carol'};
    final rule = welcomeNewViewerRule(greetedUsers: greeted);
    expect(rule.condition(_state(chat: ['carol: yo'])), isFalse);
  });

  test('parses Twitch IRC-style preview lines', () async {
    final greeted = <String>{};
    final rule = welcomeNewViewerRule(greetedUsers: greeted);
    final client = FakeAgentClient();
    final state = _state(chat: ['#mychannel dave: yo yo']);

    expect(rule.condition(state), isTrue);
    await rule.action(client, state);
    expect(client.sent.single, contains('dave'));
  });

  test('unparseable lines never trigger greeting', () {
    final rule = welcomeNewViewerRule();
    expect(rule.condition(_state(chat: ['just some text', 'also:no-colon-space'])),
        isFalse);
  });
}
