import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:shelf/shelf.dart' as shelf;
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart' as shelf_router;
import 'package:shelf_web_socket/shelf_web_socket.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import '../providers/obs_controller.dart';
import '../platforms/kick_platform.dart';
import '../platforms/multi_platform_manager.dart';
import '../platforms/stream_platform.dart';
import '../platforms/twitch_platform.dart';
import '../platforms/youtube_platform.dart';
import '../models/chat_message.dart';
import '../models/channel_event.dart';

/// Full state snapshot sent to the agent (Hermes / OpenClaw).
class AgentStateSnapshot {
  final ObsState obs;
  final bool platformConnected;
  final int chatMessageCount;
  final List<String> recentChatPreview;

  const AgentStateSnapshot({
    required this.obs,
    required this.platformConnected,
    this.chatMessageCount = 0,
    this.recentChatPreview = const [],
  });

  Map<String, dynamic> toJson() => {
    'obs': {
      'connected': obs.connected,
      'current_scene': obs.currentScene,
      'scenes': obs.scenes,
      'streaming': obs.streaming,
      'recording': obs.recording,
      'stream_duration_sec': obs.streamDurationSec,
      'sources': obs.sources.map((s) => {
        'name': s.name,
        'enabled': s.enabled,
        'volume_mul': s.volumeMul,
        'volume_db': s.volumeDb,
        'muted': s.muted,
        'audio_balance': s.audioBalance,
        'audio_sync_offset': s.audioSyncOffset,
        'audio_monitor_type': s.audioMonitorType,
        'audio_tracks': s.audioTracks,
      }).toList(),
      'audio_channels': obs.audioChannels.map((c) => {
        'type': c.type.name,
        'name': c.name,
        'source_name': c.sourceName,
        'source_found': c.sourceFound,
        'volume_mul': c.volumeMul,
        'volume_db': c.volumeDb,
        'muted': c.muted,
        'audio_balance': c.audioBalance,
        'audio_sync_offset': c.audioSyncOffset,
        'audio_monitor_type': c.audioMonitorType,
        'audio_tracks': c.audioTracks,
      }).toList(),
    },
    'platform': {
      'connected': platformConnected,
    },
    'chat': {
      'total_messages': chatMessageCount,
      'recent': recentChatPreview,
    },
  };
}

/// Result of an agent command.
class AgentCommandResult {
  final bool success;
  final String? message;

  const AgentCommandResult({required this.success, this.message});

  Map<String, dynamic> toJson() => {
    'success': success,
    'message': message,
  };
}

/// Embedded HTTP server that exposes stream state and accepts agent commands.
///
/// Hermes Agent or OpenClaw connects here to read state and send actions.
class AgentServer extends ChangeNotifier {
  ObsController? _obs;
  StreamPlatform? _platform;

  HttpServer? _server;
  HttpServer? _sseServer;
  int _port = 8511;
  bool _running = false;
  bool get running => _running;
  int get port => _port;

  // Chat message buffer for context
  final List<ChatMessage> _chatBuffer = [];
  StreamStatus? _lastStatus;
  final List<Map<String, dynamic>> _customCommands = [];
  static const _maxChatBuffer = 100;

  // Error buffer for /errors endpoint
  final List<Map<String, String>> _errorBuffer = [];
  static const _maxErrorBuffer = 50;

  // SSE event stream for real-time updates
  final StreamController<String> _sseController = StreamController<String>.broadcast();
  // WebSocket clients for real-time updates
  final List<WebSocketChannel> _wsClients = [];
  StreamSubscription? _platformStatusListener;
  StreamSubscription? _platformEventListener;
  StreamSubscription? _platformChatListener;
  VoidCallback? _obsListener;

  AgentServer();

  /// Set the OBS controller reference (called after construction).
  void setObs(ObsController obs) {
    if (_obsListener != null && _obs != null) {
      _obs!.removeListener(_obsListener!);
    }
    _obs = obs;
    _obsListener = _emitObsStateEvent;
    _obs!.addListener(_obsListener!);
    // Emit initial state for any connected SSE clients
    _emitObsStateEvent();
  }

  void setMultiPlatform({
    TwitchPlatform? twitch,
    KickPlatform? kick,
    YoutubePlatform? youtube,
  }) {
    final manager = createMultiPlatformManager(
        twitch: twitch, kick: kick, youtube: youtube);
    setPlatform(manager);
    _multiManager = manager;
  }

  MultiPlatformManager? get multiManager => _multiManager;
  MultiPlatformManager? _multiManager;

  void setPlatform(StreamPlatform? platform) {
    _platformStatusListener?.cancel();
    _platformChatListener?.cancel();
    _platformEventListener?.cancel();
    _platform = platform;
    if (_platform != null) {
      // ignore: unused_local_variable
      final chatBufferListener = _platform!.chatStream.listen(_onChatMessage);
      _platformChatListener = _platform!.chatStream.listen(_emitChatEvent);
      _platformStatusListener = _platform!.statusStream.listen(_emitPlatformStatusEvent);
      _platform!.fetchStatus().then((s) {
        _lastStatus = s;
        _emitPlatformStatusEvent(s);
      });
      final twitch = _platform as TwitchPlatform?;
      if (twitch != null) {
        _platformEventListener = twitch.eventStream.listen(_emitChannelEvent);
      }
    }
  }

  void _onChatMessage(ChatMessage msg) {
    _chatBuffer.add(msg);
    if (_chatBuffer.length > _maxChatBuffer) {
      _chatBuffer.removeAt(0);
    }
  }

  void _recordError(String context, String message) {
    _errorBuffer.add({'context': context, 'message': message});
    if (_errorBuffer.length > _maxErrorBuffer) {
      _errorBuffer.removeAt(0);
    }
  }

  void _emitObsStateEvent() {
    if (_obs == null) return;
    final snapshot = buildSnapshot();
    _emitSseEvent('obs_state', snapshot.toJson());
  }

  void _emitChatEvent(ChatMessage msg) {
    _emitSseEvent('chat_message', {
      'user': msg.user,
      'text': msg.text,
      'time': msg.time,
      'is_mod': msg.isMod,
      'is_sub': msg.isSub,
      'is_vip': msg.isVip,
      'is_broadcaster': msg.isBroadcaster,
      'id': msg.id,
    });
  }

  void _emitPlatformStatusEvent(StreamStatus status) {
    _lastStatus = status;
    _emitSseEvent('platform_status', {
      'live': status.live,
      'viewers': status.viewers,
      'game': status.game,
      'title': status.title,
      'uptime_sec': status.uptimeSec,
    });
  }

  void _emitChannelEvent(ChannelEvent event) {
    _emitSseEvent('channel_event', event.toJson());
  }

  void _emitSseEvent(String eventType, Map<String, dynamic> data) {
      if (!_sseController.hasListener && _wsClients.isEmpty) return;
      final eventJson = jsonEncode({'event': eventType, 'data': data});
      final sseEvent = 'event: $eventType\ndata: $eventJson\n\n';
      final wsMessage = jsonEncode({'event': eventType, 'data': data});

      // Broadcast to SSE clients
      if (_sseController.hasListener) {
        _sseController.add(sseEvent);
      }

      // Broadcast to WebSocket clients
          for (final client in _wsClients) {
            if (client.closeCode != null) continue;
            client.sink.add(wsMessage);
          }
          // Clean up closed clients
          _wsClients.removeWhere((c) => c.closeCode != null);
    }

  /// Build the current state snapshot for the agent.
  AgentStateSnapshot buildSnapshot() {
    return AgentStateSnapshot(
      obs: _obs?.state ?? const ObsState(),
      platformConnected: _platform?.connected ?? false,
      chatMessageCount: _chatBuffer.length,
      recentChatPreview: _chatBuffer
          .map((m) => '${m.user}: ${m.text}')
          .toList()
          .reversed
          .take(10)
          .toList(),
    );
  }

  /// Execute a command from the agent.
  Future<AgentCommandResult> executeCommand(String command, Map<String, dynamic> params) async {
    switch (command) {
      // ── OBS commands ──
      case 'switch_scene':
        final name = params['scene'] as String?;
        if (name == null) return const AgentCommandResult(success: false, message: 'Missing scene');
        if (_obs == null) return const AgentCommandResult(success: false, message: 'OBS not connected');
        final ok = await _obs!.switchScene(name);
        return AgentCommandResult(success: ok, message: ok ? 'Switched to $name' : 'Failed');

      case 'toggle_source':
        final name = params['source'] as String?;
        if (name == null) return const AgentCommandResult(success: false, message: 'Missing source');
        if (_obs == null) return const AgentCommandResult(success: false, message: 'OBS not connected');
        final ok = await _obs!.toggleSource(name);
        return AgentCommandResult(success: ok, message: ok ? 'Toggled $name' : 'Failed');

      case 'set_source':
        final name = params['source'] as String?;
        final enabled = params['enabled'] as bool?;
        if (name == null || enabled == null) {
          return const AgentCommandResult(success: false, message: 'Missing source or enabled');
        }
        if (_obs == null) return const AgentCommandResult(success: false, message: 'OBS not connected');
        final ok = await _obs!.setSourceEnabled(name, enabled);
        return AgentCommandResult(success: ok, message: ok
            ? '${enabled ? "Enabled" : "Disabled"} $name'
            : 'Failed');

      case 'toggle_stream':
        if (_obs == null) return const AgentCommandResult(success: false, message: 'OBS not connected');
        final ok = await _obs!.toggleStream();
        return AgentCommandResult(success: ok, message: ok ? 'Toggled stream' : 'Failed');

      case 'toggle_recording':
        if (_obs == null) return const AgentCommandResult(success: false, message: 'OBS not connected');
        final ok = await _obs!.toggleRecording();
        return AgentCommandResult(success: ok, message: ok ? 'Toggled recording' : 'Failed');

      // ── Audio commands ──
      case 'get_source_volume':
        final volName = params['source'] as String?;
        if (volName == null) return const AgentCommandResult(success: false, message: 'Missing source');
        if (_obs == null) return const AgentCommandResult(success: false, message: 'OBS not connected');
        final vol = await _obs!.getSourceVolume(volName);
        return AgentCommandResult(success: vol != null, message: vol != null ? '${vol.mul} / ${vol.db} dB' : 'Failed');

      case 'set_source_volume':
        final volName = params['source'] as String?;
        final volumeMul = (params['volume'] as num?)?.toDouble();
        if (volName == null || volumeMul == null) {
          return const AgentCommandResult(success: false, message: 'Missing source or volume');
        }
        if (_obs == null) return const AgentCommandResult(success: false, message: 'OBS not connected');
        final volOk = await _obs!.setSourceVolume(volName, volumeMul);
        return AgentCommandResult(success: volOk, message: volOk ? 'Volume set to $volumeMul' : 'Failed');

      case 'get_source_mute':
        final muteName = params['source'] as String?;
        if (muteName == null) return const AgentCommandResult(success: false, message: 'Missing source');
        if (_obs == null) return const AgentCommandResult(success: false, message: 'OBS not connected');
        final mute = await _obs!.getSourceMute(muteName);
        return AgentCommandResult(success: mute != null, message: mute != null ? (mute ? 'muted' : 'unmuted') : 'Failed');

      case 'set_source_mute':
        final muteName = params['source'] as String?;
        final muted = params['muted'] as bool?;
        if (muteName == null || muted == null) {
          return const AgentCommandResult(success: false, message: 'Missing source or muted');
        }
        if (_obs == null) return const AgentCommandResult(success: false, message: 'OBS not connected');
        final muteOk = await _obs!.setSourceMute(muteName, muted);
        return AgentCommandResult(success: muteOk, message: muteOk ? '${muted ? "Muted" : "Unmuted"} $muteName' : 'Failed');

      case 'toggle_source_mute':
        final tmName = params['source'] as String?;
        if (tmName == null) return const AgentCommandResult(success: false, message: 'Missing source');
        if (_obs == null) return const AgentCommandResult(success: false, message: 'OBS not connected');
        final tmOk = await _obs!.toggleSourceMute(tmName);
        return AgentCommandResult(success: tmOk, message: tmOk ? 'Toggled mute' : 'Failed');

      case 'get_source_audio_balance':
        final balName = params['source'] as String?;
        if (balName == null) return const AgentCommandResult(success: false, message: 'Missing source');
        if (_obs == null) return const AgentCommandResult(success: false, message: 'OBS not connected');
        final bal = await _obs!.getSourceAudioBalance(balName);
        return AgentCommandResult(success: bal != null, message: bal != null ? '$bal' : 'Failed');

      case 'set_source_audio_balance':
        final balName = params['source'] as String?;
        final balance = (params['balance'] as num?)?.toDouble();
        if (balName == null || balance == null) {
          return const AgentCommandResult(success: false, message: 'Missing source or balance');
        }
        if (_obs == null) return const AgentCommandResult(success: false, message: 'OBS not connected');
        final balOk = await _obs!.setSourceAudioBalance(balName, balance);
        return AgentCommandResult(success: balOk, message: balOk ? 'Balance set to $balance' : 'Failed');

      case 'get_source_audio_sync_offset':
        final syncName = params['source'] as String?;
        if (syncName == null) return const AgentCommandResult(success: false, message: 'Missing source');
        if (_obs == null) return const AgentCommandResult(success: false, message: 'OBS not connected');
        final sync = await _obs!.getSourceAudioSyncOffset(syncName);
        return AgentCommandResult(success: sync != null, message: sync != null ? '$sync ms' : 'Failed');

      case 'set_source_audio_sync_offset':
        final syncName = params['source'] as String?;
        final offsetMs = params['offset_ms'] as int?;
        if (syncName == null || offsetMs == null) {
          return const AgentCommandResult(success: false, message: 'Missing source or offset_ms');
        }
        if (_obs == null) return const AgentCommandResult(success: false, message: 'OBS not connected');
        final syncOk = await _obs!.setSourceAudioSyncOffset(syncName, offsetMs);
        return AgentCommandResult(success: syncOk, message: syncOk ? 'Sync offset set to $offsetMs ms' : 'Failed');

      case 'get_source_audio_monitor_type':
        final monName = params['source'] as String?;
        if (monName == null) return const AgentCommandResult(success: false, message: 'Missing source');
        if (_obs == null) return const AgentCommandResult(success: false, message: 'OBS not connected');
        final mon = await _obs!.getSourceAudioMonitorType(monName);
        return AgentCommandResult(success: mon != null, message: mon != null ? '$mon' : 'Failed');

      case 'set_source_audio_monitor_type':
        final monName = params['source'] as String?;
        final monitorType = params['monitor_type'] as int?;
        if (monName == null || monitorType == null) {
          return const AgentCommandResult(success: false, message: 'Missing source or monitor_type');
        }
        if (_obs == null) return const AgentCommandResult(success: false, message: 'OBS not connected');
        final monOk = await _obs!.setSourceAudioMonitorType(monName, monitorType);
        return AgentCommandResult(success: monOk, message: monOk ? 'Monitor type set to $monitorType' : 'Failed');

      // ── Audio Channel commands (logical channels) ──
      case 'get_audio_channel_volume':
        final chVolType = params['channel'] as String?; // 'microphone' or 'music_desktop'
        if (chVolType == null) return const AgentCommandResult(success: false, message: 'Missing channel');
        if (_obs == null) return const AgentCommandResult(success: false, message: 'OBS not connected');
        final chType = chVolType == 'microphone' ? AudioChannelType.microphone : AudioChannelType.musicDesktop;
        final chVol = await _obs!.getAudioChannelVolume(chType);
        return AgentCommandResult(success: chVol != null, message: chVol != null ? '${chVol.mul} / ${chVol.db} dB' : 'Channel not found or no source');

      case 'set_audio_channel_volume':
        final chVolType2 = params['channel'] as String?;
        final volumeMul = (params['volume'] as num?)?.toDouble();
        if (chVolType2 == null || volumeMul == null) {
          return const AgentCommandResult(success: false, message: 'Missing channel or volume');
        }
        if (_obs == null) return const AgentCommandResult(success: false, message: 'OBS not connected');
        final chType2 = chVolType2 == 'microphone' ? AudioChannelType.microphone : AudioChannelType.musicDesktop;
        final chVolOk = await _obs!.setAudioChannelVolume(chType2, volumeMul);
        return AgentCommandResult(success: chVolOk, message: chVolOk ? 'Channel volume set to $volumeMul' : 'Failed');

      case 'get_audio_channel_mute':
        final chMuteType = params['channel'] as String?;
        if (chMuteType == null) return const AgentCommandResult(success: false, message: 'Missing channel');
        if (_obs == null) return const AgentCommandResult(success: false, message: 'OBS not connected');
        final chMuteTypeEnum = chMuteType == 'microphone' ? AudioChannelType.microphone : AudioChannelType.musicDesktop;
        final chMute = await _obs!.getAudioChannelMute(chMuteTypeEnum);
        return AgentCommandResult(success: chMute != null, message: chMute != null ? (chMute ? 'muted' : 'unmuted') : 'Channel not found or no source');

      case 'set_audio_channel_mute':
        final chMuteType3 = params['channel'] as String?;
        final muted = params['muted'] as bool?;
        if (chMuteType3 == null || muted == null) {
          return const AgentCommandResult(success: false, message: 'Missing channel or muted');
        }
        if (_obs == null) return const AgentCommandResult(success: false, message: 'OBS not connected');
        final chMuteTypeEnum3 = chMuteType3 == 'microphone' ? AudioChannelType.microphone : AudioChannelType.musicDesktop;
        final chMuteOk = await _obs!.setAudioChannelMute(chMuteTypeEnum3, muted);
        return AgentCommandResult(success: chMuteOk, message: chMuteOk ? '${muted ? "Muted" : "Unmuted"} channel' : 'Failed');

      case 'toggle_audio_channel_mute':
        final chToggleType = params['channel'] as String?;
        if (chToggleType == null) return const AgentCommandResult(success: false, message: 'Missing channel');
        if (_obs == null) return const AgentCommandResult(success: false, message: 'OBS not connected');
        final chToggleTypeEnum = chToggleType == 'microphone' ? AudioChannelType.microphone : AudioChannelType.musicDesktop;
        final chToggleOk = await _obs!.toggleAudioChannelMute(chToggleTypeEnum);
        return AgentCommandResult(success: chToggleOk, message: chToggleOk ? 'Toggled channel mute' : 'Failed');

      case 'get_audio_channel_monitor_type':
        final chMonType = params['channel'] as String?;
        if (chMonType == null) return const AgentCommandResult(success: false, message: 'Missing channel');
        if (_obs == null) return const AgentCommandResult(success: false, message: 'OBS not connected');
        final chMonTypeEnum = chMonType == 'microphone' ? AudioChannelType.microphone : AudioChannelType.musicDesktop;
        final chMon = await _obs!.getAudioChannelMonitorType(chMonTypeEnum);
        return AgentCommandResult(success: chMon != null, message: chMon != null ? '$chMon' : 'Channel not found or no source');

      case 'set_audio_channel_monitor_type':
        final chMonType2 = params['channel'] as String?;
        final monitorType = params['monitor_type'] as int?;
        if (chMonType2 == null || monitorType == null) {
          return const AgentCommandResult(success: false, message: 'Missing channel or monitor_type');
        }
        if (_obs == null) return const AgentCommandResult(success: false, message: 'OBS not connected');
        final chMonTypeEnum2 = chMonType2 == 'microphone' ? AudioChannelType.microphone : AudioChannelType.musicDesktop;
        final chMonOk = await _obs!.setAudioChannelMonitorType(chMonTypeEnum2, monitorType);
        return AgentCommandResult(success: chMonOk, message: chMonOk ? 'Channel monitor type set to $monitorType' : 'Failed');

      case 'set_audio_channel_source':
        final chSourceType = params['channel'] as String?;
        final sourceName = params['source'] as String?;
        if (chSourceType == null || sourceName == null) {
          return const AgentCommandResult(success: false, message: 'Missing channel or source');
        }
        if (_obs == null) return const AgentCommandResult(success: false, message: 'OBS not connected');
        final chSourceTypeEnum = chSourceType == 'microphone' ? AudioChannelType.microphone : AudioChannelType.musicDesktop;
        final chSourceOk = await _obs!.setAudioChannelSource(chSourceTypeEnum, sourceName);
        return AgentCommandResult(success: chSourceOk, message: chSourceOk ? 'Channel source set to $sourceName' : 'Failed');

      case 'clear_audio_channel_source':
        final chClearType = params['channel'] as String?;
        if (chClearType == null) return const AgentCommandResult(success: false, message: 'Missing channel');
        if (_obs == null) return const AgentCommandResult(success: false, message: 'OBS not connected');
        final chClearTypeEnum = chClearType == 'microphone' ? AudioChannelType.microphone : AudioChannelType.musicDesktop;
        final chClearOk = await _obs!.clearAudioChannelSource(chClearTypeEnum);
        return AgentCommandResult(success: chClearOk, message: chClearOk ? 'Channel source cleared (auto-detect)' : 'Failed');

      // ── Chat commands ──
      case 'send_message':
        final text = params['message'] as String?;
        if (text == null || text.isEmpty) {
          return const AgentCommandResult(success: false, message: 'Missing message');
        }
        final ok = await _platform?.sendMessage(text) ?? false;
        return AgentCommandResult(success: ok, message: ok ? 'Sent' : 'Failed');

      case 'timeout':
        final user = params['user'] as String?;
        if (user == null) return const AgentCommandResult(success: false, message: 'Missing user');
        final ok = await _platform?.timeoutUser(user) ?? false;
        return AgentCommandResult(success: ok, message: ok ? 'Timed out $user' : 'Failed');

      case 'ban':
        final user = params['user'] as String?;
        if (user == null) return const AgentCommandResult(success: false, message: 'Missing user');
        final ok = await _platform?.banUser(user) ?? false;
        return AgentCommandResult(success: ok, message: ok ? 'Banned $user' : 'Failed');

      case 'unban':
        final user = params['user'] as String?;
        if (user == null) return const AgentCommandResult(success: false, message: 'Missing user');
        final ok = await _platform?.unbanUser(user) ?? false;
        return AgentCommandResult(success: ok, message: ok ? 'Unbanned $user' : 'Failed');

      case 'clear_chat':
        final ok = await _platform?.clearChat() ?? false;
        return AgentCommandResult(success: ok, message: ok ? 'Chat cleared' : 'Failed');

      case 'chat_mode':
        final mode = params['mode'] as String?;
        final enabled = params['enabled'] as bool? ?? true;
        if (mode == null) return const AgentCommandResult(success: false, message: 'Missing mode');
        final ok = await _platform?.setChatMode(mode, enabled) ?? false;
        return AgentCommandResult(success: ok, message: ok ? 'Chat mode $mode=$enabled' : 'Failed');

      case 'connect_platform':
        final platform = params['platform'] as String?;
        final channel = params['channel'] as String?;
        if (platform == null || channel == null) {
          return const AgentCommandResult(
              success: false, message: 'Missing platform or channel');
        }
        return await _connectPlatform(platform, channel);

      case 'disconnect_platform':
        final platform = params['platform'] as String?;
        if (platform == null) {
          return const AgentCommandResult(success: false, message: 'Missing platform');
        }
        _multiManager?.disconnectPlatform(_typeForName(platform));
        return AgentCommandResult(success: true, message: 'Disconnected $platform');

      default:
        return AgentCommandResult(success: false, message: 'Unknown command: $command');
    }
  }

  // ── HTTP Server ──

  Type _typeForName(String name) {
    switch (name.toLowerCase()) {
      case 'twitch':
        return TwitchPlatform;
      case 'kick':
        return KickPlatform;
      case 'youtube':
        return YoutubePlatform;
      default:
        throw ArgumentError('Unknown platform: $name');
    }
  }

  Future<AgentCommandResult> _connectPlatform(
      String platform, String channel) async {
    try {
      final type = _typeForName(platform);
      final ok = await _multiManager?.connectPlatform(
            type,
            PlatformCredentials(channelName: channel),
          ) ??
          false;
      return AgentCommandResult(
        success: ok,
        message: ok ? 'Connected to $platform ($channel)' : 'Failed to connect $platform',
      );
    } on ArgumentError catch (e) {
      _recordError('platform', 'Bad platform: ${e.message}');
      return AgentCommandResult(success: false, message: e.message?.toString() ?? 'Bad platform');
    } on UnsupportedError catch (e) {
      _recordError('platform', 'Unsupported: ${e.message}');
      return AgentCommandResult(success: false, message: e.message ?? 'Unsupported');
    }
  }

  Future<bool> start({int port = 8511}) async {
    _port = port;
    try {
      final router = shelf_router.Router();

      // GET /state — full state snapshot for the agent
      router.get('/state', (request) {
        final snapshot = buildSnapshot();
        return shelf.Response.ok(
          jsonEncode(snapshot.toJson()),
          headers: {'Content-Type': 'application/json'},
        );
      });

      // POST /command — execute an agent command
      router.post('/command', (request) async {
        final body = jsonDecode(await request.readAsString()) as Map<String, dynamic>;
        final command = body['command'] as String?;
        final params = body['params'] as Map<String, dynamic>? ?? {};
        if (command == null) {
          return shelf.Response.badRequest(
            body: jsonEncode({'error': 'Missing command'}),
          );
        }
        final result = await executeCommand(command, params);
        return shelf.Response.ok(
          jsonEncode(result.toJson()),
          headers: {'Content-Type': 'application/json'},
        );
      });

      // GET /health — simple health check
      router.get('/health', (request) {
        return shelf.Response.ok(
          jsonEncode({'status': 'ok', 'obs_connected': _obs?.state.connected ?? false}),
          headers: {'Content-Type': 'application/json'},
        );
      });

      // GET /stream/status — dashboard status card
      router.get('/stream/status', (request) {
        final s = _lastStatus;
        return shelf.Response.ok(
          jsonEncode({
            'status': (s?.live ?? false) ? 'live' : 'offline',
            'viewers': s?.viewers ?? 0,
            'game': s?.game ?? '',
            'title': s?.title ?? '',
          }),
          headers: {'Content-Type': 'application/json'},
        );
      });

      // GET /chat/recent?count=N — recent chat for the dashboard
      router.get('/chat/recent', (request) {
        final countStr = request.url.queryParameters['count'] ?? '30';
        final count = int.tryParse(countStr) ?? 30;
        final recent = _chatBuffer.reversed.take(count).toList();
        return shelf.Response.ok(
          jsonEncode({
            'messages': [for (final m in recent.reversed) m.toJson()],
          }),
          headers: {'Content-Type': 'application/json'},
        );
      });

      // POST /chat/send — send a chat message
      router.post('/chat/send', (request) async {
        final body = jsonDecode(await request.readAsString()) as Map<String, dynamic>;
        final message = body['message'] as String?;
        if (message == null || message.isEmpty) {
          return shelf.Response.badRequest(
            body: jsonEncode({'error': 'Missing message'}),
          );
        }
        final ok = await _platform?.sendMessage(message) ?? false;
        return shelf.Response.ok(
          jsonEncode({'success': ok}),
          headers: {'Content-Type': 'application/json'},
        );
      });

      // ── Custom chat commands (in-memory; UI Settings tab manages them) ──
      router.get('/command/list', (request) {
        return shelf.Response.ok(
          jsonEncode({
            'commands': _customCommands.map((c) => {
                  'name': c['name'],
                  'response': c['response'],
                  'enabled': c['enabled'],
                }).toList(),
          }),
          headers: {'Content-Type': 'application/json'},
        );
      });

      router.post('/command/save', (request) async {
        final body = jsonDecode(await request.readAsString()) as Map<String, dynamic>;
        final name = body['name'] as String?;
        final response = body['response'] as String?;
        if (name == null || name.isEmpty || response == null || response.isEmpty) {
          return shelf.Response.badRequest(
            body: jsonEncode({'error': 'Missing name or response'}),
          );
        }
        _customCommands.removeWhere((c) => c['name'] == name);
        _customCommands.add({
          'name': name,
          'response': response,
          'enabled': body['enabled'] ?? true,
        });
        return shelf.Response.ok(
          jsonEncode({'success': true}),
          headers: {'Content-Type': 'application/json'},
        );
      });

      router.post('/command/delete', (request) async {
        final body = jsonDecode(await request.readAsString()) as Map<String, dynamic>;
        final name = body['name'] as String?;
        if (name == null) {
          return shelf.Response.badRequest(body: jsonEncode({'error': 'Missing name'}));
        }
        _customCommands.removeWhere((c) => c['name'] == name);
        return shelf.Response.ok(
          jsonEncode({'success': true}),
          headers: {'Content-Type': 'application/json'},
        );
      });

      router.post('/command/run', (request) async {
        final body = jsonDecode(await request.readAsString()) as Map<String, dynamic>;
        final name = body['name'] as String?;
        if (name == null) {
          return shelf.Response.badRequest(body: jsonEncode({'error': 'Missing name'}));
        }
        final cmd = _customCommands.cast<Map<String, dynamic>?>().firstWhere(
              (c) => c!['name'] == name,
              orElse: () => null,
            );
        if (cmd != null && cmd['enabled'] == true && _platform?.connected == true) {
          await _platform!.sendMessage(cmd['response'] as String);
        }
        return shelf.Response.ok(
          jsonEncode({'success': true}),
          headers: {'Content-Type': 'application/json'},
        );
      });

      // GET /ws — WebSocket for real-time event push
      router.get(
        '/ws',
        webSocketHandler((WebSocketChannel channel, String? protocol) {
          _wsClients.add(channel);
          debugPrint('[AgentServer] WebSocket client connected (${_wsClients.length} total)');

          // Send initial state snapshot
          final snapshot = buildSnapshot();
          channel.sink.add(jsonEncode({'event': 'state', 'data': snapshot.toJson()}));

          // Listen for messages from client (optional - for future command support over WS)
          channel.stream.listen(
            (message) {
              // Could handle incoming WebSocket commands here
              debugPrint('[AgentServer] WebSocket message: $message');
            },
            onDone: () {
              _wsClients.remove(channel);
              debugPrint('[AgentServer] WebSocket client disconnected (${_wsClients.length} total)');
            },
            onError: (error) {
              _wsClients.remove(channel);
              debugPrint('[AgentServer] WebSocket error: $error');
            },
          );
        }),
      );

      // GET /events/stream — Server-Sent Events for real-time state updates
      // Handled by separate _sseServer on port + 1
      router.get('/events/stream', (request) {
        return shelf.Response(
          HttpStatus.movedTemporarily,
          headers: {'Location': 'http://${request.requestedUri.host}:${_port + 1}/events/stream'},
        );
      });

      // Start SSE server on port + 1
      _sseServer = await HttpServer.bind('0.0.0.0', _port + 1);
      _sseServer!.listen(_handleSseRequest);

      // GET /overlay — serve the OBS browser source overlay
      router.get('/overlay', (request) {
        return shelf.Response.ok(
          _overlayHtml,
          headers: {'Content-Type': 'text/html; charset=utf-8'},
        );
      });

      // POST /mod/timeout — timeout a user
      router.post('/mod/timeout', (request) async {
        final body = await request.readAsString();
        final params = jsonDecode(body) as Map<String, dynamic>;
        final result = await executeCommand('timeout', params);
        return shelf.Response.ok(
          jsonEncode({'success': result.success, 'message': result.message}),
          headers: {'Content-Type': 'application/json'},
        );
      });

      // POST /mod/ban — ban a user
      router.post('/mod/ban', (request) async {
        final body = await request.readAsString();
        final params = jsonDecode(body) as Map<String, dynamic>;
        final result = await executeCommand('ban', params);
        return shelf.Response.ok(
          jsonEncode({'success': result.success, 'message': result.message}),
          headers: {'Content-Type': 'application/json'},
        );
      });

      // POST /mod/unban — unban a user
      router.post('/mod/unban', (request) async {
        final body = await request.readAsString();
        final params = jsonDecode(body) as Map<String, dynamic>;
        final result = await executeCommand('unban', params);
        return shelf.Response.ok(
          jsonEncode({'success': result.success, 'message': result.message}),
          headers: {'Content-Type': 'application/json'},
        );
      });

      // POST /mod/clear — clear chat
      router.post('/mod/clear', (request) async {
        final result = await executeCommand('clear_chat', {});
        return shelf.Response.ok(
          jsonEncode({'success': result.success, 'message': result.message}),
          headers: {'Content-Type': 'application/json'},
        );
      });

      // POST /mod/chatmode — set chat mode (slow, subscribers, emote-only, etc.)
      router.post('/mod/chatmode', (request) async {
        final body = await request.readAsString();
        final params = jsonDecode(body) as Map<String, dynamic>;
        final result = await executeCommand('chat_mode', params);
        return shelf.Response.ok(
          jsonEncode({'success': result.success, 'message': result.message}),
          headers: {'Content-Type': 'application/json'},
        );
      });

      // GET /errors — return buffered backend errors
      router.get('/errors', (request) {
        return shelf.Response.ok(
          jsonEncode({'errors': _errorBuffer.toList()}),
          headers: {'Content-Type': 'application/json'},
        );
      });

      // GET /auth/callback — Twitch OAuth redirect handler
      router.get('/auth/callback', (request) async {
        final code = request.url.queryParameters['code'];
        if (code == null) {
          return shelf.Response.ok(
            '<html><body><h2>❌ Authorization failed</h2><p>No code received.</p></body></html>',
            headers: {'Content-Type': 'text/html; charset=utf-8'},
          );
        }
        final twitch = _platform as TwitchPlatform?;
        if (twitch == null) {
          return shelf.Response.ok(
            '<html><body><h2>❌ Twitch platform not available</h2></body></html>',
            headers: {'Content-Type': 'text/html; charset=utf-8'},
          );
        }
        final ok = await twitch.handleAuthCallback(code);
        if (ok) {
          // Auto-connect after successful auth
          twitch.connect(PlatformCredentials(channelName: null));
          return shelf.Response.ok(
            '<html><body><h2>✅ Authorized!</h2><p>You can close this window and return to Streamer Co-Pilot.</p></body></html>',
            headers: {'Content-Type': 'text/html; charset=utf-8'},
          );
        }
        return shelf.Response.ok(
          '<html><body><h2>❌ Authorization failed</h2><p>Token exchange failed.</p></body></html>',
          headers: {'Content-Type': 'text/html; charset=utf-8'},
        );
      });

      _server = await shelf_io.serve(router.call, '0.0.0.0', _port);
      _running = true;
      notifyListeners();
      debugPrint('[AgentServer] Started on port $port');
      return true;
    } catch (e) {
      debugPrint('[AgentServer] Failed to start: $e');
      _recordError('server', 'Failed to start: $e');
      _running = false;
      notifyListeners();
      return false;
    }
  }

  void _handleSseRequest(HttpRequest request) {
    if (request.uri.path == '/events/stream') {
      request.response.headers
        ..set('Content-Type', 'text/event-stream')
        ..set('Cache-Control', 'no-cache')
        ..set('Connection', 'keep-alive')
        ..set('Access-Control-Allow-Origin', '*')
        ..set('X-Accel-Buffering', 'no');

      // Send initial connection event immediately to establish SSE connection
      request.response.add(utf8.encode(': connected\n\n'));
      request.response.flush(); // Non-blocking flush

      final byteController = StreamController<List<int>>(sync: true);
      final subscription = _sseController.stream.listen(
        (event) {
          byteController.add(utf8.encode(event));
        },
        onError: byteController.addError,
        onDone: byteController.close,
      );

      request.response.done.then((_) {
        subscription.cancel();
        byteController.close();
      });

      final byteSubscription = byteController.stream.listen(
        request.response.add,
        onError: request.response.addError,
        onDone: request.response.close,
      );

      request.response.done.then((_) {
        byteSubscription.cancel();
      });
    } else {
      request.response.statusCode = HttpStatus.notFound;
      request.response.close();
    }
  }

  void stop() {
    _server?.close(force: true);
    _server = null;
    _sseServer?.close(force: true);
    _sseServer = null;
    // Close all WebSocket connections
    for (final client in _wsClients) {
      client.sink.close();
    }
    _wsClients.clear();
    _running = false;
    notifyListeners();
  }

  @override
  void dispose() {
    if (_obsListener != null && _obs != null) {
      _obs!.removeListener(_obsListener!);
    }
    _platformStatusListener?.cancel();
    _platformChatListener?.cancel();
    _sseController.close();
    stop();
    super.dispose();
  }
}

/// Embedded OBS overlay HTML (served at /overlay)
const _overlayHtml = '''
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>SCP Overlay</title>
<style>
  * { margin: 0; padding: 0; box-sizing: border-box; }
  body {
    font-family: 'Inter', -apple-system, sans-serif;
    background: transparent;
    overflow: hidden;
    color: #fff;
  }
  #status-bar {
    display: flex; align-items: center; gap: 12px;
    padding: 8px 14px;
    background: rgba(0,0,0,0.75);
    backdrop-filter: blur(8px);
    border-radius: 10px;
    margin: 10px;
    font-size: 13px;
    position: fixed; top: 0; left: 0; right: 0;
    z-index: 100;
  }
  .status-dot { width: 10px; height: 10px; border-radius: 50%; flex-shrink: 0; }
  .status-dot.live { background: #ff4444; box-shadow: 0 0 8px #ff444488; }
  .status-dot.offline { background: #666; }
  #status-label { font-weight: 700; }
  #status-label.live { color: #ff4444; }
  #viewer-count { color: #aaa; font-size: 12px; }
  #stream-title { flex: 1; text-align: right; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; color: #ccc; font-size: 12px; }
  #chat-container { position: fixed; bottom: 0; left: 10px; right: 10px; max-height: 60vh; overflow: hidden; padding: 4px; }
  #chat-list { display: flex; flex-direction: column-reverse; gap: 2px; max-height: calc(60vh - 10px); overflow-y: auto; scrollbar-width: none; }
  #chat-list::-webkit-scrollbar { display: none; }
  .chat-msg { background: rgba(0,0,0,0.6); backdrop-filter: blur(4px); padding: 6px 12px; border-radius: 8px; font-size: 14px; line-height: 1.4; animation: fadeIn 0.3s ease-out; display: flex; align-items: baseline; gap: 6px; }
  @keyframes fadeIn { from { opacity: 0; transform: translateY(8px); } to { opacity: 1; transform: translateY(0); } }
  .chat-msg .time { color: #888; font-size: 11px; }
  .chat-msg .user { color: #b388ff; font-weight: 600; }
  .chat-msg .text { color: #eee; word-break: break-word; }
  .chat-empty { color: #666; font-size: 13px; text-align: center; padding: 20px; }
  /* ── Alerts ── */
  #alert-container { position: fixed; top: 70px; left: 0; right: 0; display: flex; flex-direction: column; align-items: center; gap: 8px; pointer-events: none; z-index: 200; }
  .alert { padding: 14px 28px; border-radius: 12px; font-size: 22px; font-weight: 700; background: rgba(0,0,0,0.8); backdrop-filter: blur(10px); border: 2px solid; animation: alertIn 0.5s cubic-bezier(0.18, 0.89, 0.32, 1.28), pulse 2s ease-in-out 0.5s infinite, alertOut 0.6s ease-in forwards 6s; }
  .alert.sub { color: #9147ff; border-color: #9147ff; box-shadow: 0 0 24px #9147ff66; }
  .alert.resub { color: #ff9d00; border-color: #ff9d00; box-shadow: 0 0 24px #ff9d0066; }
  .alert.raid { color: #ff4444; border-color: #ff4444; box-shadow: 0 0 24px #ff444466; }
  .alert.follow { color: #00bfff; border-color: #00bfff; box-shadow: 0 0 24px #00bfff66; }
  .alert.cheer { color: #ffd700; border-color: #ffd700; box-shadow: 0 0 24px #ffd70066; }
  @keyframes alertIn { from { opacity: 0; transform: translateY(-30px) scale(0.8); } to { opacity: 1; transform: translateY(0) scale(1); } }
  @keyframes pulse { 50% { transform: scale(1.04); } }
  @keyframes alertOut { to { opacity: 0; transform: translateY(-20px); } }
</style>
</head>
<body>
<div id="status-bar">
  <div class="status-dot offline"></div>
  <span id="status-label">Connecting...</span>
  <span id="viewer-count"></span>
  <span id="stream-title"></span>
</div>
<div id="chat-container">
  <div id="chat-list"><div class="chat-empty">💬 Chat will appear here...</div></div>
</div>
<div id="alert-container"></div>
<script>
const API = window.location.origin;
const chatList = document.getElementById('chat-list');
const statusDot = document.querySelector('.status-dot');
const statusLabel = document.getElementById('status-label');
const viewerCount = document.getElementById('viewer-count');
const streamTitle = document.getElementById('stream-title');

function applyObsState(obs) {
  if (!obs) return;
  statusDot.className = 'status-dot ' + (obs.streaming ? 'live' : 'offline');
  statusLabel.textContent = obs.streaming ? '🔴 LIVE' : '⚫ OFFLINE';
  statusLabel.className = obs.streaming ? 'live' : '';
}

// Initial load fallback (before SSE connects)
async function fetchStateOnce() {
  try {
    const res = await fetch(API + '/state', { signal: AbortSignal.timeout(3000) });
    if (!res.ok) return;
    const data = await res.json();
    applyObsState(data.obs);
  } catch (_) {}
}
fetchStateOnce();

// SSE: real-time OBS state + alerts + live chat
const alertContainer = document.getElementById('alert-container');
const SSE = new EventSource(window.location.protocol + '//' + window.location.hostname + ':' + (parseInt(window.location.port) + 1) + '/events/stream');

function showAlert(cls, text) {
  const el = document.createElement('div');
  el.className = 'alert ' + cls;
  el.textContent = text;
  alertContainer.appendChild(el);
  setTimeout(() => el.remove(), 7000);
}

SSE.addEventListener('obs_state', (e) => {
  try {
    const obs = JSON.parse(e.data);
    applyObsState(obs);
  } catch (_) {}
});

SSE.addEventListener('channel_event', (e) => {
  try {
    const ev = JSON.parse(e.data);
    if (ev.type === 'subscription') showAlert('sub', '⭐ ' + ev.user + ' subscribed!');
    else if (ev.type === 'resub') showAlert('resub', '🔥 ' + ev.user + ' re-subbed for ' + (ev.count || '?') + ' months!' + (ev.message ? ' — "' + ev.message + '"' : ''));
    else if (ev.type === 'raid') showAlert('raid', '🚀 ' + ev.user + ' raided with ' + (ev.count || '?') + ' viewers!');
    else if (ev.type === 'follow') showAlert('follow', '💙 ' + ev.user + ' followed!');
    else if (ev.type === 'cheer') showAlert('cheer', '✨ ' + ev.user + ' cheered ' + (ev.count || '?') + ' bits!' + (ev.message ? ' — "' + ev.message + '"' : ''));
  } catch (_) {}
});

SSE.addEventListener('platform_status', (e) => {
  try {
    const s = JSON.parse(e.data);
    statusDot.className = 'status-dot ' + (s.live ? 'live' : 'offline');
    statusLabel.textContent = s.live ? '🔴 LIVE' : '⚫ OFFLINE';
    statusLabel.className = s.live ? 'live' : '';
    viewerCount.textContent = s.viewers != null ? '👥 ' + s.viewers : '';
    streamTitle.textContent = s.title || '';
  } catch (_) {}
});
</script>
</body>
</html>
''';