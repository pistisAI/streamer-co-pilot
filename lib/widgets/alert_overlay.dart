import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/streamer_bot_provider.dart';

/// Animated alert banner for channel events (subs, raids, follows, cheers).
///
/// Listens to [StreamerBotProvider.currentAlert]; shows one alert at a time
/// with an entry animation. Place at the top of any layout (dashboard,
/// compact overlay) to surface live events.
class AlertOverlay extends StatelessWidget {
  const AlertOverlay({super.key, this.alignment = Alignment.topCenter});

  final AlignmentGeometry alignment;

  static const _typeStyles = <String, ({IconData icon, Color color, String label})>{
    'subscription': (icon: Icons.star_rounded, color: Color(0xFF9147FF), label: 'SUBSCRIBED'),
    'resub': (icon: Icons.repeat_rounded, color: Color(0xFF9147FF), label: 'RESUBSCRIBED'),
    'raid': (icon: Icons.groups_rounded, color: Color(0xFFF47067), label: 'IS RAIDING'),
    'follow': (icon: Icons.favorite_rounded, color: Color(0xFF00C8AF), label: 'FOLLOWED'),
    'cheer': (icon: Icons.diamond_outlined, color: Color(0xFFFAD000), label: 'CHEERED'),
  };

  @override
  Widget build(BuildContext context) {
    return Consumer<StreamerBotProvider>(
      builder: (_, provider, _) {
        final alert = provider.currentAlert;
        if (alert == null) return const SizedBox.shrink();

        final type = alert['type'] as String? ?? '';
        final style = _typeStyles[type] ??
            (icon: Icons.notifications_active_rounded,
             color: const Color(0xFF58A6FF),
             label: type.toUpperCase());
        final user = alert['user'] as String? ?? 'someone';
        final count = alert['count'] as int?;
        final message = alert['message'] as String?;

        return Align(
          alignment: alignment,
          child: SafeArea(
            child: Padding(
              padding: const EdgeInsets.only(top: 12),
              child: _AlertCard(
                key: ValueKey('$type:$user:${alert['time']}'),
                icon: style.icon,
                color: style.color,
                label: style.label,
                user: user,
                count: count,
                message: message,
                onDismiss: provider.dismissAlert,
              ),
            ),
          ),
        );
      },
    );
  }
}

class _AlertCard extends StatefulWidget {
  const _AlertCard({
    super.key,
    required this.icon,
    required this.color,
    required this.label,
    required this.user,
    required this.count,
    required this.message,
    required this.onDismiss,
  });

  final IconData icon;
  final Color color;
  final String label;
  final String user;
  final int? count;
  final String? message;
  final VoidCallback onDismiss;

  @override
  State<_AlertCard> createState() => _AlertCardState();
}

class _AlertCardState extends State<_AlertCard>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 350),
  )..forward();

  late final Animation<Offset> _slide =
      Tween(begin: const Offset(0, -1), end: Offset.zero)
          .animate(CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic));

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  String get _detail {
    if (widget.count != null) {
      if (widget.label == 'IS RAIDING') {
        return '${widget.count} viewers!';
      }
      return '${widget.count} months!';
    }
    return '';
  }

  @override
  Widget build(BuildContext context) {
    return SlideTransition(
      position: _slide,
      child: Dismissible(
        key: UniqueKey(),
        direction: DismissDirection.horizontal,
        onDismissed: (_) => widget.onDismiss(),
        background: const SizedBox.shrink(),
        child: Material(
          elevation: 6,
          borderRadius: BorderRadius.circular(14),
          color: Colors.transparent,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [widget.color.withValues(alpha: 0.95), widget.color.withValues(alpha: 0.75)],
              ),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(widget.icon, color: Colors.white, size: 28),
                    const SizedBox(width: 10),
                    Flexible(
                      child: Text.rich(
                        TextSpan(
                          children: [
                            TextSpan(
                                text: widget.user,
                                style: const TextStyle(
                                    fontWeight: FontWeight.w800,
                                    fontSize: 17,
                                    color: Colors.white)),
                            TextSpan(
                                text: '  ${widget.label}',
                                style: TextStyle(
                                    fontWeight: FontWeight.w500,
                                    fontSize: 15,
                                    color: Colors.white.withValues(alpha: 0.9))),
                            if (_detail.isNotEmpty)
                              TextSpan(
                                  text: '  $_detail',
                                  style: const TextStyle(
                                      fontWeight: FontWeight.w700,
                                      fontSize: 15,
                                      color: Colors.white)),
                          ],
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
                if (widget.message != null && widget.message!.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text(
                    '"${widget.message}"',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontStyle: FontStyle.italic,
                        fontSize: 13,
                        color: Colors.white.withValues(alpha: 0.85)),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
