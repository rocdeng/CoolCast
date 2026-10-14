import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../models/cast_models.dart';
import '../platform/player_bridge.dart';

@visibleForTesting
class DebugAlertOverlayForTest extends StatelessWidget {
  const DebugAlertOverlayForTest({super.key, required this.alerts});

  final List<CoolCastDebugAlert> alerts;

  @override
  Widget build(BuildContext context) => DebugAlertOverlay(alerts: alerts);
}


@visibleForTesting
class PlayingPageForTest extends StatelessWidget {
  const PlayingPageForTest({
    super.key,
    required this.showControls,
    this.imageUrl = '',
    this.imageBytes,
    this.mediaChips = const [],
    this.onShowControls,
  });

  final bool showControls;
  final String imageUrl;
  final Uint8List? imageBytes;
  final List<String> mediaChips;
  final VoidCallback? onShowControls;

  @override
  Widget build(BuildContext context) {
    return PlayingPage(
      player: null,
      imageUrl: imageUrl,
      imageBytes: imageBytes,
      state: PlaybackState.playing,
      source: 'DLNA/UPnP',
      fileName: '测试视频.mp4',
      connection: '192.168.1.20',
      mediaChips: mediaChips,
      previewPosition: const Duration(minutes: 18, seconds: 42),
      previewDuration: const Duration(hours: 1, minutes: 24, seconds: 16),
      showControls: showControls,
      onBack: () {},
      onShowControls: onShowControls ?? () {},
      onPlayPause: () {},
      onRewind: () {},
      onForward: () {},
    );
  }
}


class PlayingPage extends StatelessWidget {
  const PlayingPage({
    super.key,
    required this.player,
    required this.imageUrl,
    required this.imageBytes,
    required this.state,
    required this.source,
    required this.fileName,
    required this.connection,
    required this.mediaChips,
    required this.previewPosition,
    required this.previewDuration,
    required this.showControls,
    required this.onBack,
    required this.onShowControls,
    required this.onPlayPause,
    required this.onRewind,
    required this.onForward,
  });

  final CoolCastPlayer? player;
  final String imageUrl;
  final Uint8List? imageBytes;
  final PlaybackState state;
  final String source;
  final String fileName;
  final String connection;
  final List<String> mediaChips;
  final Duration previewPosition;
  final Duration previewDuration;
  final bool showControls;
  final VoidCallback onBack;
  final VoidCallback onShowControls;
  final VoidCallback onPlayPause;
  final VoidCallback onRewind;
  final VoidCallback onForward;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onShowControls,
      child: Center(
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: SizedBox(
            width: 1920,
            height: 1080,
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (imageUrl.isNotEmpty || imageBytes != null)
                  _ImageSurface(url: imageUrl, bytes: imageBytes)
                else
                  _VideoSurface(player: player),
                Positioned.fill(
                  child: GestureDetector(
                    key: const ValueKey('playing-page-tap-layer'),
                    behavior: HitTestBehavior.translucent,
                    onTap: onShowControls,
                  ),
                ),
                if (showControls)
                  Positioned(
                    left: 72,
                    top: 56,
                    child: _BackButton(onPressed: onBack),
                  ),
                if (showControls)
                  Positioned(
                    right: 80,
                    top: 54,
                    child: _PlaybackInfoCard(
                      source: source,
                      fileName: fileName,
                      connection: connection,
                      mediaChips: mediaChips,
                    ),
                  ),
                if (state == PlaybackState.ready)
                  const Center(
                    child: SizedBox(
                      width: 56,
                      height: 56,
                      child: CircularProgressIndicator(strokeWidth: 5),
                    ),
                  ),
                if (showControls)
                  Positioned(
                    left: 470,
                    bottom: 80,
                    child: SizedBox(
                      width: 980,
                      child: _PlaybackControlBar(
                        player: player,
                        state: state,
                        previewPosition: previewPosition,
                        previewDuration: previewDuration,
                        onPlayPause: onPlayPause,
                        onRewind: onRewind,
                        onForward: onForward,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ImageSurface extends StatelessWidget {
  const _ImageSurface({required this.url, required this.bytes});

  final String url;
  final Uint8List? bytes;

  @override
  Widget build(BuildContext context) {
    final imageBytes = bytes;
    return ColoredBox(
      key: const ValueKey('cast-image-surface'),
      color: Colors.black,
      child: Center(
        child: imageBytes != null
            ? Image.memory(imageBytes, fit: BoxFit.contain)
            : Image.network(
                url,
                fit: BoxFit.contain,
                errorBuilder: (context, error, stackTrace) {
                  return const Icon(
                    Icons.broken_image,
                    color: Colors.white54,
                    size: 92,
                  );
                },
              ),
      ),
    );
  }
}

class _VideoSurface extends StatelessWidget {
  const _VideoSurface({required this.player});

  final CoolCastPlayer? player;

  @override
  Widget build(BuildContext context) {
    final videoPlayer = player;
    if (videoPlayer is NativePlayerController && videoPlayer.isInitialized) {
      return const AndroidView(viewType: nativePlayerViewType);
    }
    if (videoPlayer is FlutterVideoPlayerController &&
        videoPlayer.isInitialized) {
      final aspectRatio =
          videoPlayer.aspectRatio == 0 ? 16 / 9 : videoPlayer.aspectRatio;
      return DecoratedBox(
        decoration: const BoxDecoration(color: Colors.black),
        child: Center(
          child: AspectRatio(
            aspectRatio: aspectRatio,
            child: VideoPlayer(videoPlayer.controller),
          ),
        ),
      );
    }

    return const DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.centerLeft,
          end: Alignment.centerRight,
          colors: [Color(0xFFF6FAFF), Color(0xFFEAF5FF), Colors.white],
          stops: [0, 0.62, 1],
        ),
      ),
      child: Stack(
        children: [
          Positioned(
            left: 520,
            top: 210,
            width: 900,
            height: 520,
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  colors: [Color(0x260A84FF), Color(0x000A84FF)],
                ),
              ),
            ),
          ),
          Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.cast, color: Color(0x300A84FF), size: 92),
                SizedBox(height: 24),
                Text(
                  '正在播放投屏内容',
                  style: TextStyle(
                    color: Color(0x26102033),
                    fontSize: 42,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _BackButton extends StatelessWidget {
  const _BackButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 56,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(999),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 22, sigmaY: 22),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: const Color(0xCCFFFFFF),
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: const Color(0xFFD6E6F5)),
              boxShadow: const [
                BoxShadow(
                  color: Color(0x1F0A3A6B),
                  blurRadius: 24,
                  offset: Offset(0, 8),
                ),
              ],
            ),
            child: TextButton.icon(
              onPressed: onPressed,
              icon: const Icon(Icons.arrow_back, size: 26),
              label: const Text(
                '返回',
                style: TextStyle(fontSize: 24, fontWeight: FontWeight.w700),
              ),
              style: TextButton.styleFrom(
                foregroundColor: const Color(0xFF102033),
                padding: const EdgeInsets.symmetric(horizontal: 20),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _PlaybackInfoCard extends StatelessWidget {
  const _PlaybackInfoCard({
    required this.source,
    required this.fileName,
    required this.connection,
    required this.mediaChips,
  });

  final String source;
  final String fileName;
  final String connection;
  final List<String> mediaChips;

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      cornerRadius: 24,
      padding: const EdgeInsets.all(22),
      fill: const Color(0xDFFFFFFF),
      child: SizedBox(
        width: 516,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _SourceLine(source: source),
            const SizedBox(height: 14),
            _MediaFileLine(fileName: fileName),
            if (mediaChips.isNotEmpty) ...[
              const SizedBox(height: 14),
              _MediaChips(chips: mediaChips),
            ],
            const SizedBox(height: 14),
            _ConnectionLine(connection: connection),
          ],
        ),
      ),
    );
  }
}

class _SourceLine extends StatelessWidget {
  const _SourceLine({required this.source});

  final String source;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        const _PlayingIconTile(icon: Icons.smartphone),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '投屏来源',
                style: TextStyle(
                  color: Color(0xFF5E7186),
                  fontSize: 17,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                source,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Color(0xFF102033),
                  fontSize: 24,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _MediaFileLine extends StatelessWidget {
  const _MediaFileLine({required this.fileName});

  final String fileName;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          '播放文件',
          style: TextStyle(
            color: Color(0xFF5E7186),
            fontSize: 17,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 5),
        Text(
          fileName,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            color: Color(0xFF102033),
            fontSize: 22,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    );
  }
}

class _MediaChips extends StatelessWidget {
  const _MediaChips({required this.chips});

  final List<String> chips;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 10,
      runSpacing: 8,
      children: [for (final chip in chips) _MediaChip(label: chip)],
    );
  }
}

class _MediaChip extends StatelessWidget {
  const _MediaChip({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xFFEAF5FF),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        child: Text(
          label,
          style: const TextStyle(
            color: Color(0xFF102033),
            fontSize: 15,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}

class _ConnectionLine extends StatelessWidget {
  const _ConnectionLine({required this.connection});

  final String connection;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xCCE9FBEF),
        borderRadius: BorderRadius.circular(14),
      ),
      child: SizedBox(
        height: 44,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14),
          child: Row(
            children: [
              const SizedBox(
                width: 10,
                height: 10,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: Color(0xFF30D158),
                    shape: BoxShape.circle,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Text(
                connection == 'Browser Preview'
                    ? '连接来源  预览模式'
                    : '接收端 IP  $connection',
                style: const TextStyle(
                  color: Color(0xFF102033),
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const Spacer(),
              const Text(
                '稳定',
                style: TextStyle(
                  color: Color(0xFF5E7186),
                  fontSize: 17,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PlayingIconTile extends StatelessWidget {
  const _PlayingIconTile({required this.icon});

  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0x2638BDF8),
        borderRadius: BorderRadius.circular(12),
      ),
      child: SizedBox(
        width: 40,
        height: 40,
        child: Icon(icon, color: const Color(0xFF0A84FF), size: 22),
      ),
    );
  }
}

class _PlaybackControlBar extends StatelessWidget {
  const _PlaybackControlBar({
    required this.player,
    required this.state,
    required this.previewPosition,
    required this.previewDuration,
    required this.onPlayPause,
    required this.onRewind,
    required this.onForward,
  });

  final CoolCastPlayer? player;
  final PlaybackState state;
  final Duration previewPosition;
  final Duration previewDuration;
  final VoidCallback onPlayPause;
  final VoidCallback onRewind;
  final VoidCallback onForward;

  @override
  Widget build(BuildContext context) {
    final currentPlayer = player;
    final position = currentPlayer?.position ?? previewPosition;
    final duration = currentPlayer?.duration ?? previewDuration;

    return GlassCard(
      cornerRadius: 34,
      padding: const EdgeInsets.symmetric(horizontal: 34, vertical: 24),
      fill: const Color(0xD9FFFFFF),
      child: Column(
        children: [
          _ProgressBar(position: position, duration: duration),
          const SizedBox(height: 18),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _PlaybackCircleButton(
                icon: Icons.fast_rewind,
                label: '后退 10 秒',
                onPressed: onRewind,
              ),
              const SizedBox(width: 24),
              _PlaybackCircleButton(
                icon: state == PlaybackState.playing
                    ? Icons.pause
                    : Icons.play_arrow,
                label: state == PlaybackState.playing ? '暂停' : '播放',
                onPressed: onPlayPause,
                large: true,
                primary: true,
              ),
              const SizedBox(width: 24),
              _PlaybackCircleButton(
                icon: Icons.fast_forward,
                label: '前进 10 秒',
                onPressed: onForward,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class DebugAlertOverlay extends StatelessWidget {
  const DebugAlertOverlay({super.key, required this.alerts});

  final List<CoolCastDebugAlert> alerts;

  @override
  Widget build(BuildContext context) {
    final visibleAlerts = alerts
        .where((alert) => alert.isHighSeverity)
        .toList()
        .reversed
        .take(2)
        .toList();
    if (visibleAlerts.isEmpty) {
      return const SizedBox.shrink();
    }

    return Positioned(
      right: 34,
      bottom: 34,
      width: 680,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: const Color(0xEA000000),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: const Color(0xFFFF6B6B), width: 2),
          boxShadow: const [
            BoxShadow(
              color: Color(0x66000000),
              blurRadius: 28,
              offset: Offset(0, 12),
            ),
          ],
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Row(
                children: [
                  Icon(Icons.error_outline, color: Color(0xFFFF6B6B), size: 28),
                  SizedBox(width: 10),
                  Text(
                    '调试错误',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 24,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              for (final alert in visibleAlerts) ...[
                _DebugAlertRow(alert: alert),
                if (alert != visibleAlerts.last) const SizedBox(height: 10),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _DebugAlertRow extends StatelessWidget {
  const _DebugAlertRow({required this.alert});

  final CoolCastDebugAlert alert;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '[${alert.level}]',
          style: const TextStyle(
            color: Color(0xFFFFD166),
            fontSize: 20,
            fontWeight: FontWeight.w800,
            fontFamily: 'monospace',
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            '${formatDebugTime(alert.timestamp)} ${alert.message}',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 20,
              fontWeight: FontWeight.w700,
              height: 1.25,
              fontFamily: 'monospace',
            ),
          ),
        ),
      ],
    );
  }
}

class _PlaybackCircleButton extends StatelessWidget {
  const _PlaybackCircleButton({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.large = false,
    this.primary = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onPressed;
  final bool large;
  final bool primary;

  @override
  Widget build(BuildContext context) {
    final size = large ? 74.0 : 58.0;
    return SizedBox(
      width: size,
      height: size,
      child: IconButton(
        onPressed: onPressed,
        tooltip: label,
        autofocus: primary,
        icon: Icon(icon, size: large ? 34 : 26),
        color: primary ? const Color(0xFF04111F) : const Color(0xFF102033),
        style: ButtonStyle(
          backgroundColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.focused)) {
              return primary
                  ? const Color(0xFF38BDF8)
                  : const Color(0xFFE4F4FF);
            }
            return primary ? const Color(0xFF0A84FF) : const Color(0xFFF2F8FF);
          }),
          shape: WidgetStateProperty.all(const CircleBorder()),
          side: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.focused)) {
              return const BorderSide(color: Color(0xFF0A84FF), width: 3);
            }
            return const BorderSide(color: Color(0xFFD6E6F5));
          }),
          elevation: WidgetStateProperty.resolveWith((states) {
            return states.contains(WidgetState.focused) ? 8 : 0;
          }),
        ),
      ),
    );
  }
}

class _ProgressBar extends StatelessWidget {
  const _ProgressBar({required this.position, required this.duration});

  final Duration position;
  final Duration duration;

  @override
  Widget build(BuildContext context) {
    final progress = duration.inMilliseconds <= 0
        ? 0.0
        : (position.inMilliseconds / duration.inMilliseconds).clamp(0.0, 1.0);
    return Column(
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(formatDuration(position), style: playTimeStyle),
            Text(formatDuration(duration), style: playTimeStyle),
          ],
        ),
        const SizedBox(height: 10),
        SizedBox(
          height: 18,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final trackWidth = constraints.maxWidth;
              final filledWidth =
                  (trackWidth * progress).clamp(0.0, trackWidth);
              return Stack(
                alignment: Alignment.centerLeft,
                children: [
                  Container(
                    height: 8,
                    decoration: BoxDecoration(
                      color: const Color(0xFFD8E7F5),
                      borderRadius: BorderRadius.circular(999),
                    ),
                  ),
                  Container(
                    width: filledWidth,
                    height: 8,
                    decoration: BoxDecoration(
                      color: const Color(0xFF0A84FF),
                      borderRadius: BorderRadius.circular(999),
                    ),
                  ),
                  Positioned(
                    left: (filledWidth - 9).clamp(0.0, trackWidth - 18),
                    child: Container(
                      width: 18,
                      height: 18,
                      decoration: BoxDecoration(
                        color: Colors.white,
                        shape: BoxShape.circle,
                        border: Border.all(color: const Color(0xFFB7D8F5)),
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ],
    );
  }
}

class GlassCard extends StatelessWidget {
  const GlassCard({
    super.key,
    required this.child,
    this.compact = false,
    this.fill = const Color(0xCCFFFFFF),
    this.cornerRadius = 28,
    this.padding,
  });

  final Widget child;
  final bool compact;
  final Color fill;
  final double cornerRadius;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: fill,
        borderRadius: BorderRadius.circular(cornerRadius),
        border: Border.all(color: Colors.white.withValues(alpha: 0.80)),
        boxShadow: const [
          BoxShadow(
            color: Color(0x1F4DA3FF),
            blurRadius: 36,
            offset: Offset(0, 18),
          ),
        ],
      ),
      child: Padding(
        padding: padding ?? EdgeInsets.all(compact ? 24 : 30),
        child: child,
      ),
    );
  }
}

class DebugUrlInput extends StatelessWidget {
  const DebugUrlInput({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.onLoad,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final VoidCallback onLoad;

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      compact: true,
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: controller,
              focusNode: focusNode,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => onLoad(),
              decoration: const InputDecoration(
                hintText: '浏览器调试 URL',
                border: OutlineInputBorder(),
              ),
            ),
          ),
          const SizedBox(width: 12),
          FilledButton(onPressed: onLoad, child: const Text('载入')),
        ],
      ),
    );
  }
}

const TextStyle playTimeStyle = TextStyle(
  color: Color(0xFF5E7186),
  fontSize: 18,
  fontWeight: FontWeight.w600,
);
