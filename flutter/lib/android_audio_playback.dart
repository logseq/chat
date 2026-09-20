import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

const _audioExtensions = {'m4a', 'mp3', 'wav', 'aac', 'caf', 'ogg', 'opus'};

bool isAndroidAudioAsset(String assetType, String localPath) {
  final normalizedType = assetType.toLowerCase();
  if (normalizedType.startsWith('audio/')) return true;
  if (_audioExtensions.contains(normalizedType)) return true;
  final dot = localPath.lastIndexOf('.');
  return dot >= 0 &&
      _audioExtensions.contains(localPath.substring(dot + 1).toLowerCase());
}

final class AndroidAudioPlaybackSession {
  const AndroidAudioPlaybackSession({required this.id, required this.duration});

  final int id;
  final Duration duration;
}

final class AndroidAudioPlaybackStatus {
  const AndroidAudioPlaybackStatus({
    required this.isActive,
    required this.isPlaying,
    required this.position,
    required this.duration,
  });

  final bool isActive;
  final bool isPlaying;
  final Duration position;
  final Duration duration;
}

abstract interface class AndroidAudioPlaybackBackend {
  Future<AndroidAudioPlaybackSession> start(String path);
  Future<void> pause(int sessionId);
  Future<void> resume(int sessionId);
  Future<AndroidAudioPlaybackStatus> status(int sessionId);
  Future<void> stop(int sessionId);
}

final class MethodChannelAndroidAudioPlaybackBackend
    implements AndroidAudioPlaybackBackend {
  const MethodChannelAndroidAudioPlaybackBackend({
    this.channel = const MethodChannel('com.logseq.chat/platform'),
  });

  final MethodChannel channel;

  @override
  Future<AndroidAudioPlaybackSession> start(String path) async {
    final response = await channel.invokeMapMethod<String, Object?>(
      'startAudioPlayback',
      {'path': path},
    );
    if (response == null) throw StateError('Audio playback did not start');
    return AndroidAudioPlaybackSession(
      id: response['sessionId']! as int,
      duration: Duration(milliseconds: response['durationMs']! as int),
    );
  }

  @override
  Future<void> pause(int sessionId) => channel.invokeMethod<void>(
    'pauseAudioPlayback',
    {'sessionId': sessionId},
  );

  @override
  Future<void> resume(int sessionId) => channel.invokeMethod<void>(
    'resumeAudioPlayback',
    {'sessionId': sessionId},
  );

  @override
  Future<AndroidAudioPlaybackStatus> status(int sessionId) async {
    final response = await channel.invokeMapMethod<String, Object?>(
      'audioPlaybackStatus',
      {'sessionId': sessionId},
    );
    if (response == null) throw StateError('Audio playback status is missing');
    return AndroidAudioPlaybackStatus(
      isActive: response['isActive']! as bool,
      isPlaying: response['isPlaying']! as bool,
      position: Duration(milliseconds: response['positionMs']! as int),
      duration: Duration(milliseconds: response['durationMs']! as int),
    );
  }

  @override
  Future<void> stop(int sessionId) =>
      channel.invokeMethod<void>('stopAudioPlayback', {'sessionId': sessionId});
}

final class AndroidAudioPlayer extends StatefulWidget {
  const AndroidAudioPlayer({
    super.key,
    required this.title,
    required this.path,
    this.backend = const MethodChannelAndroidAudioPlaybackBackend(),
  });

  final String title;
  final String path;
  final AndroidAudioPlaybackBackend backend;

  @override
  State<AndroidAudioPlayer> createState() => _AndroidAudioPlayerState();
}

final class _AndroidAudioPlayerState extends State<AndroidAudioPlayer> {
  AndroidAudioPlaybackSession? _session;
  Timer? _statusTimer;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  bool _playing = false;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _statusTimer?.cancel();
    final session = _session;
    if (session != null) unawaited(widget.backend.stop(session.id));
    super.dispose();
  }

  Future<void> _togglePlayback() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final session = _session;
      if (session == null) {
        final started = await widget.backend.start(widget.path);
        if (!mounted) {
          unawaited(widget.backend.stop(started.id));
          return;
        }
        _session = started;
        _duration = started.duration;
        _playing = true;
        _startStatusUpdates();
      } else if (_playing) {
        await widget.backend.pause(session.id);
        if (!mounted) return;
        _playing = false;
        _statusTimer?.cancel();
      } else {
        await widget.backend.resume(session.id);
        if (!mounted) return;
        _playing = true;
        _startStatusUpdates();
      }
    } catch (_) {
      if (!mounted) return;
      _error = 'Could not play audio';
      _playing = false;
      _statusTimer?.cancel();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _startStatusUpdates() {
    _statusTimer?.cancel();
    _statusTimer = Timer.periodic(
      const Duration(milliseconds: 400),
      (_) => unawaited(_refreshStatus()),
    );
  }

  Future<void> _refreshStatus() async {
    final session = _session;
    if (session == null) return;
    try {
      final status = await widget.backend.status(session.id);
      if (!mounted || _session?.id != session.id) return;
      setState(() {
        _position = status.position;
        _duration = status.duration;
        _playing = status.isPlaying;
        if (!status.isActive) {
          _session = null;
          _position = Duration.zero;
          _statusTimer?.cancel();
        }
      });
    } catch (_) {
      if (!mounted) return;
      _statusTimer?.cancel();
      setState(() {
        _session = null;
        _playing = false;
        _position = Duration.zero;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final progress = _duration.inMilliseconds <= 0
        ? 0.0
        : (_position.inMilliseconds / _duration.inMilliseconds).clamp(0.0, 1.0);
    return Semantics(
      key: const ValueKey('player.asset.audio'),
      identifier: 'player.asset.audio',
      container: true,
      label: _playing ? 'Pause audio' : 'Play audio',
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: colorScheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 8, 16, 8),
          child: Row(
            children: [
              IconButton.filledTonal(
                key: const ValueKey('button.audio.play-pause'),
                tooltip: _playing ? 'Pause audio' : 'Play audio',
                onPressed: _busy ? null : _togglePlayback,
                icon: _busy
                    ? const SizedBox.square(
                        dimension: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Icon(
                        _playing
                            ? Icons.pause_rounded
                            : Icons.play_arrow_rounded,
                      ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      widget.title.isEmpty ? 'Untitled audio' : widget.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                    const SizedBox(height: 6),
                    LinearProgressIndicator(
                      value: progress,
                      minHeight: 3,
                      borderRadius: BorderRadius.circular(2),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _playing ? 'Pause audio' : 'Play audio',
                      style: Theme.of(context).textTheme.labelSmall
                          ?.copyWith(color: colorScheme.onSurfaceVariant),
                    ),
                    if (_error case final error?) ...[
                      const SizedBox(height: 4),
                      Text(
                        error,
                        style: Theme.of(context).textTheme.labelSmall
                            ?.copyWith(color: colorScheme.error),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Text(
                _formatDuration(_position),
                style: Theme.of(context).textTheme.labelSmall
                    ?.copyWith(color: colorScheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

String _formatDuration(Duration duration) {
  final minutes = duration.inMinutes;
  final seconds = duration.inSeconds.remainder(60);
  return '$minutes:${seconds.toString().padLeft(2, '0')}';
}
