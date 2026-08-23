// Decision loop for Streamer Co-Pilot agents.
//
// Implements the "poll `/state`, decide, send `/command`" pattern from the roadmap.
// Designed to be simple, testable, and extensible for Hermes/OpenClaw integration.
import 'dart:async';
import 'agent_client.dart';

/// A single decision rule: condition + action.
class DecisionRule {
  final String name;
  final bool Function(AgentState state) condition;
  final Future<CommandResult> Function(AgentClient client, AgentState state) action;

  const DecisionRule({
    required this.name,
    required this.condition,
    required this.action,
  });
}

/// Configuration for the decision loop.
class DecisionLoopConfig {
  final Duration pollInterval;
  final List<DecisionRule> rules;
  final bool Function(AgentState)? shouldContinue;
  final void Function(String)? onLog;

  const DecisionLoopConfig({
    this.pollInterval = const Duration(seconds: 5),
    this.rules = const [],
    this.shouldContinue,
    this.onLog,
  });
}

/// Result of a decision loop iteration.
class DecisionResult {
  final String ruleName;
  final bool conditionMet;
  final CommandResult? commandResult;
  final String? error;

  const DecisionResult({
    required this.ruleName,
    required this.conditionMet,
    this.commandResult,
    this.error,
  });

  bool get success => conditionMet && (commandResult?.success ?? true) && error == null;
}

/// The core decision loop: polls state, evaluates rules, executes actions.
class DecisionLoop {
  final AgentClient client;
  final DecisionLoopConfig config;
  Timer? _timer;
  bool _running = false;
  int _iteration = 0;

  DecisionLoop({required this.client, required this.config});

  bool get isRunning => _running;
  int get iteration => _iteration;

  /// Start the decision loop.
  Future<void> start() async {
    if (_running) return;

    // Initial health check
    final healthy = await client.healthCheck();
    if (!healthy) {
      throw Exception('AgentServer health check failed');
    }
    _log('Health check passed, starting decision loop');

    _running = true;
    _runIteration();
    _timer = Timer.periodic(config.pollInterval, (_) => _runIteration());
  }

  /// Stop the decision loop.
  Future<void> stop() async {
    _timer?.cancel();
    _timer = null;
    _running = false;
    _log('Decision loop stopped after $_iteration iterations');
  }

  /// Run a single iteration manually (useful for testing).
  Future<List<DecisionResult>> runOnce() async {
    return _runIteration();
  }

  Future<List<DecisionResult>> _runIteration() async {
    _iteration++;
    _log('Iteration $_iteration: polling state');

    final state = await client.getState();
    _log('State: obs=${state.obsConnected}, streaming=${state.streaming}, '
        'platform=${state.platformConnected}, chat=${state.chatMessageCount}');

    // Check continuation condition
    if (config.shouldContinue != null && !config.shouldContinue!(state)) {
      _log('Continuation condition not met, stopping');
      await stop();
      return [];
    }

    final results = <DecisionResult>[];

    for (final rule in config.rules) {
      final conditionMet = rule.condition(state);
      if (!conditionMet) continue;

      _log('Rule "${rule.name}" triggered');
      try {
        final commandResult = await rule.action(client, state);
        results.add(DecisionResult(
          ruleName: rule.name,
          conditionMet: true,
          commandResult: commandResult,
        ));
        _log('  -> ${commandResult.success ? "OK" : "FAILED"}: ${commandResult.message}');
      } catch (e) {
        results.add(DecisionResult(
          ruleName: rule.name,
          conditionMet: true,
          error: e.toString(),
        ));
        _log('  -> ERROR: $e');
      }
    }

    if (results.isEmpty) {
      _log('No rules triggered');
    }

    return results;
  }

  void _log(String message) {
    config.onLog?.call('[DecisionLoop] $message');
  }
}

/// Built-in rule: auto-start stream when platform goes live and OBS is ready.
DecisionRule autoStartStreamRule() => DecisionRule(
      name: 'auto_start_stream',
      condition: (state) =>
          state.platformConnected &&
          state.obsConnected &&
          !state.streaming &&
          state.scenes.isNotEmpty,
      action: (client, state) async =>
          client.sendCommand('toggle_stream', {}),
    );

/// Built-in rule: switch to "Starting" scene when going live.
DecisionRule switchToStartingSceneRule() => DecisionRule(
      name: 'switch_to_starting_scene',
      condition: (state) =>
          state.platformConnected &&
          state.obsConnected &&
          state.streaming &&
          state.currentScene != 'Starting' &&
          state.scenes.contains('Starting'),
      action: (client, state) async =>
          client.sendCommand('switch_scene', {'scene': 'Starting'}),
    );

/// Built-in rule: switch to "Gaming" scene when chat says !game.
DecisionRule chatGameCommandRule() => DecisionRule(
      name: 'chat_game_command',
      condition: (state) => state.recentChatPreview.any(
        (msg) => msg.toLowerCase().contains('!game'),
      ),
      action: (client, state) async =>
          client.sendCommand('switch_scene', {'scene': 'Gaming'}),
    );

/// Built-in rule: mute microphone when chat says !mute.
DecisionRule chatMuteCommandRule() => DecisionRule(
      name: 'chat_mute_command',
      condition: (state) => state.recentChatPreview.any(
        (msg) => msg.toLowerCase().contains('!mute'),
      ),
      action: (client, state) async =>
          client.sendCommand('set_audio_channel_mute', {
            'channel': 'microphone',
            'muted': true,
          }),
    );

/// Built-in rule: greet each new chatter exactly once per session.
///
/// Tracks already-greeted users in [greetedUsers]; pass a fresh set per
/// stream session. Greeting fires when a previously-unseen user appears in
/// the recent chat preview.
DecisionRule welcomeNewViewerRule({Set<String>? greetedUsers}) {
  final greeted = greetedUsers ?? <String>{};
  return DecisionRule(
    name: 'welcome_new_viewer',
    condition: (state) =>
        state.platformConnected &&
        state.recentChatPreview.any((msg) {
          final user = _chatUserOf(msg);
          return user != null && !greeted.contains(user);
        }),
    action: (client, state) async {
      final msg = state.recentChatPreview
          .map(_chatUserOf)
          .firstWhere((u) => u != null && !greeted.contains(u), orElse: () => null);
      if (msg == null) {
        return const CommandResult(success: false, message: 'no new user');
      }
      greeted.add(msg);
      return client.sendCommand(
          'send_message', {'message': 'Welcome to the stream, $msg! 👋'});
    },
  );
}

/// Best-effort extraction of the chatter name from a chat preview line.
/// Preview lines are free-form; common shapes are "user: message" and
/// "#channel user: message" (Twitch IRC). Returns null if unparseable.
String? _chatUserOf(String line) {
  final idx = line.indexOf(':');
  if (idx <= 0 || idx + 1 >= line.length || line[idx + 1] != ' ') return null;
  var user = line.substring(0, idx).trim();
  if (user.startsWith('#')) {
    final parts = user.split(' ');
    user = parts.length > 1 ? parts[1].trim() : '';
  }
  if (user.isEmpty || user.contains(' ')) return null;
  return user;
}

/// Default rule set for a basic streaming agent.
List<DecisionRule> defaultRules() => [
      autoStartStreamRule(),
      switchToStartingSceneRule(),
      // chatGameCommandRule(), // Enable when you have a "Gaming" scene
      // chatMuteCommandRule(), // Enable when you want chat-controlled mute
      // welcomeNewViewerRule(), // Enable with care (spam risk)
    ];