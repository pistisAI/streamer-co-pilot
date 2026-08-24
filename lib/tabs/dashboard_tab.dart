import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/streamer_bot_provider.dart';
import '../providers/obs_controller.dart';
import '../platforms/twitch_platform.dart';
import '../widgets/alert_overlay.dart';

class DashboardTab extends StatelessWidget {
  const DashboardTab({super.key});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Stack(
        children: [
          const AlertOverlay(),
          Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ── Stream Status Card ──
          Consumer<StreamerBotProvider>(
            builder: (_, provider, child) {
              return Card(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            provider.streamStatus == 'live'
                                ? Icons.circle
                                : Icons.circle_outlined,
                            color: provider.streamStatus == 'live'
                                ? Colors.red
                                : Colors.grey,
                            size: 16,
                          ),
                          const SizedBox(width: 8),
                          Text(
                            provider.streamStatus == 'live'
                                ? '🔴 LIVE'
                                : provider.streamStatus == 'offline'
                                    ? '⚫ OFFLINE'
                                    : '❓ Checking...',
                            style: const TextStyle(
                              fontSize: 28,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      if (provider.title.isNotEmpty) ...[
                        Text(
                          provider.title,
                          style: const TextStyle(fontSize: 18),
                          textAlign: TextAlign.center,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 8),
                      ],
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          if (provider.game.isNotEmpty) ...[
                            const Icon(Icons.videogame_asset, size: 16),
                            const SizedBox(width: 4),
                            Text(provider.game),
                            const SizedBox(width: 24),
                          ],
                          const Icon(Icons.visibility, size: 16),
                          const SizedBox(width: 4),
                          Text('${provider.viewers} viewers'),
                        ],
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
          const SizedBox(height: 12),

          // ── OBS Status Card ──
          Consumer<ObsController>(
            builder: (_, obs, child) {
              return Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(
                            obs.state.connected ? Icons.check_circle : Icons.error_outline,
                            color: obs.state.connected ? Colors.green : Colors.red,
                            size: 16,
                          ),
                          const SizedBox(width: 8),
                          Text(
                            'OBS Studio',
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const Spacer(),
                          if (obs.state.connected) ...[
                            _obsBadge(obs.state.streaming ? '🔴 LIVE' : '⚫ OFF', obs.state.streaming ? Colors.red : Colors.grey),
                            const SizedBox(width: 8),
                            _obsBadge(obs.state.recording ? '⏺ REC' : '⏹ STOP', obs.state.recording ? Colors.red : Colors.grey),
                          ],
                        ],
                      ),
                      if (obs.state.connected) ...[
                        const SizedBox(height: 12),
                        Row(
                          children: [
                            const Icon(Icons.layers, size: 14, color: Colors.grey),
                            const SizedBox(width: 4),
                            Text(
                              'Scene: ${obs.state.currentScene ?? "N/A"}',
                              style: const TextStyle(fontSize: 13),
                            ),
                            const Spacer(),
                            Text(
                              '${obs.state.scenes.length} scenes',
                              style: const TextStyle(fontSize: 12, color: Colors.grey),
                            ),
                          ],
                        ),
                        if (obs.state.sources.isNotEmpty) ...[
                          const SizedBox(height: 8),
                          const Text('Sources:', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.grey)),
                          const SizedBox(height: 4),
                          Wrap(
                            spacing: 6,
                            runSpacing: 4,
                            children: obs.state.sources.map((s) {
                              return _sourceChip(s.name, s.enabled);
                            }).toList(),
                          ),
                        ],
                      ],
                    ],
                  ),
                ),
              );
            },
          ),
          const SizedBox(height: 12),

          // ── Platform Status Card ──
          Consumer<TwitchPlatform>(
            builder: (_, twitch, child) {
              return Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    children: [
                      Icon(
                        twitch.connected ? Icons.check_circle : Icons.error_outline,
                        color: twitch.connected ? Colors.green : Colors.red,
                        size: 16,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        'Twitch',
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const Spacer(),
                      Text(
                        twitch.connected ? 'Connected' : 'Disconnected',
                        style: TextStyle(
                          color: twitch.connected ? Colors.green : Colors.red,
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
          const SizedBox(height: 12),

          // ── Buttons ──
          Row(
            children: [
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: () => context.read<StreamerBotProvider>().connectSse(),
                  icon: const Icon(Icons.refresh),
                  label: const Text('Reconnect'),
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: () => context.read<StreamerBotProvider>().fetchStatus(),
                  icon: const Icon(Icons.download),
                  label: const Text('Refresh'),
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),

          // ── Recent Chat ──
          Expanded(
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Recent Chat',
                      style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
                    ),
                    const Divider(),
                    Expanded(
                      child: Consumer<StreamerBotProvider>(
                        builder: (_, provider, child) {
                          if (provider.chat.isEmpty) {
                            return const Center(
                              child: Text(
                                'No messages yet',
                                style: TextStyle(color: Colors.grey),
                              ),
                            );
                          }
                          return ListView.builder(
                            itemCount: provider.chat.length,
                            itemBuilder: (_, i) {
                              final msg = provider.chat[i];
                              return Padding(
                                padding: const EdgeInsets.symmetric(vertical: 2),
                                child: RichText(
                                  text: TextSpan(
                                    style: const TextStyle(fontSize: 13, height: 1.3),
                                    children: [
                                      TextSpan(
                                        text: '${msg.time} ',
                                        style: const TextStyle(color: Colors.grey),
                                      ),
                                      if (msg.isMod)
                                        const WidgetSpan(
                                          child: Text('🛡️ ', style: TextStyle(fontSize: 12)),
                                        ),
                                      TextSpan(
                                        text: '${msg.user}: ',
                                        style: TextStyle(
                                          fontWeight: FontWeight.bold,
                                          color: Colors.purple.shade200,
                                        ),
                                      ),
                                      TextSpan(
                                        text: msg.text,
                                        style: const TextStyle(color: Colors.white70),
                                      ),
                                    ],
                                  ),
                                ),
                              );
                            },
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
        ),
        ],
      ),
    );
  }

  Widget _obsBadge(String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Text(label, style: TextStyle(fontSize: 11, color: color, fontWeight: FontWeight.bold)),
    );
  }

  Widget _sourceChip(String name, bool enabled) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: enabled ? Colors.green.withValues(alpha: 0.1) : Colors.grey.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: enabled ? Colors.green.withValues(alpha: 0.3) : Colors.grey.withValues(alpha: 0.2),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            enabled ? Icons.visibility : Icons.visibility_off,
            size: 12,
            color: enabled ? Colors.green : Colors.grey,
          ),
          const SizedBox(width: 4),
          Text(
            name,
            style: TextStyle(
              fontSize: 11,
              color: enabled ? Colors.green.shade200 : Colors.grey,
            ),
          ),
        ],
      ),
    );
  }
}
