import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

final class RecordedAudioAsset {
  const RecordedAudioAsset({
    required this.uuid,
    required this.title,
    required this.assetType,
    required this.size,
    required this.checksum,
    required this.localPath,
  });

  factory RecordedAudioAsset.fromMap(Map<String, Object?> value) {
    String requiredString(String key) {
      final result = value[key];
      if (result is! String || result.isEmpty) {
        throw FormatException('Recorded audio is missing $key');
      }
      return result;
    }

    final size = value['size'];
    if (size is! int || size <= 0) {
      throw const FormatException('Recorded audio has an invalid size');
    }
    return RecordedAudioAsset(
      uuid: requiredString('uuid'),
      title: requiredString('title'),
      assetType: requiredString('assetType'),
      size: size,
      checksum: requiredString('checksum'),
      localPath: requiredString('localPath'),
    );
  }

  final String uuid;
  final String title;
  final String assetType;
  final int size;
  final String checksum;
  final String localPath;

  Map<String, Object?> coreRequest({String? targetBlockId}) {
    final payload = <String, Object?>{
      'uuid': uuid,
      'title': title,
      'assetType': assetType,
      'assetSize': size,
      'assetChecksum': checksum,
      'localPath': localPath,
      if (targetBlockId != null && targetBlockId.isNotEmpty)
        'targetBlockId': targetBlockId,
    };
    return {
      'apiVersion': 1,
      'method': 'dispatch',
      'params': {'action': 'addAsset', 'payload': jsonEncode(payload)},
    };
  }

  Map<String, Object?> transcriptCoreRequest({
    required String transcriptUuid,
    required String transcript,
  }) => {
    'apiVersion': 1,
    'method': 'dispatch',
    'params': {
      'action': 'addChildBlock',
      'payload': jsonEncode({
        'uuid': transcriptUuid,
        'title': transcript,
        'parentId': uuid,
      }),
    },
  };
}

final class RecordedAudioRecordingResult {
  const RecordedAudioRecordingResult({
    required this.asset,
    required this.transcriptionEnabled,
  });

  final RecordedAudioAsset asset;
  final bool transcriptionEnabled;
}

abstract interface class AndroidAudioRecordingBackend {
  Future<bool> supportsTranscription();

  Future<void> start();

  Future<RecordedAudioAsset> stop();

  Future<void> cancel();

  Future<String> transcribe(String path);
}

final class MethodChannelAndroidAudioRecordingBackend
    implements AndroidAudioRecordingBackend {
  const MethodChannelAndroidAudioRecordingBackend({
    this.channel = const MethodChannel('com.logseq.chat/platform'),
  });

  final MethodChannel channel;

  @override
  Future<bool> supportsTranscription() async =>
      await channel.invokeMethod<bool>('supportsAudioTranscription') ?? false;

  @override
  Future<void> start() => channel.invokeMethod<void>('startAudioRecording');

  @override
  Future<RecordedAudioAsset> stop() async {
    final value = await channel.invokeMapMethod<String, Object?>(
      'stopAudioRecording',
    );
    if (value == null) {
      throw const FormatException('Android did not return recorded audio');
    }
    return RecordedAudioAsset.fromMap(value);
  }

  @override
  Future<void> cancel() => channel.invokeMethod<void>('cancelAudioRecording');

  @override
  Future<String> transcribe(String path) async =>
      (await channel.invokeMethod<String>('transcribeAudio', {
        'path': path,
      }))?.trim() ??
      '';
}

Future<RecordedAudioRecordingResult?> showAndroidAudioRecordingSheet({
  required BuildContext context,
  required AndroidAudioRecordingBackend backend,
}) => showModalBottomSheet<RecordedAudioRecordingResult>(
  context: context,
  useSafeArea: true,
  isScrollControlled: true,
  isDismissible: false,
  enableDrag: false,
  builder: (_) => _AndroidAudioRecordingSheet(backend: backend),
);

final class _AndroidAudioRecordingSheet extends StatefulWidget {
  const _AndroidAudioRecordingSheet({required this.backend});

  final AndroidAudioRecordingBackend backend;

  @override
  State<_AndroidAudioRecordingSheet> createState() =>
      _AndroidAudioRecordingSheetState();
}

final class _AndroidAudioRecordingSheetState
    extends State<_AndroidAudioRecordingSheet> {
  Timer? _timer;
  var _elapsedSeconds = 0;
  var _recording = false;
  var _saving = false;
  var _transcriptionSupported = false;
  var _transcriptionEnabled = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_start());
    unawaited(_loadTranscriptionSupport());
  }

  Future<void> _loadTranscriptionSupport() async {
    final supported = await widget.backend.supportsTranscription();
    if (mounted) setState(() => _transcriptionSupported = supported);
  }

  Future<void> _start() async {
    try {
      await widget.backend.start();
      if (!mounted) return;
      setState(() => _recording = true);
      _timer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() => _elapsedSeconds += 1);
      });
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    }
  }

  Future<void> _stop() async {
    if (!_recording || _saving) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final asset = await widget.backend.stop();
      _recording = false;
      _timer?.cancel();
      if (mounted) {
        Navigator.pop(
          context,
          RecordedAudioRecordingResult(
            asset: asset,
            transcriptionEnabled:
                _transcriptionSupported && _transcriptionEnabled,
          ),
        );
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = error.toString();
        });
      }
    }
  }

  Future<void> _cancel() async {
    if (_saving) return;
    _timer?.cancel();
    try {
      await widget.backend.cancel();
    } finally {
      _recording = false;
      if (mounted) Navigator.pop(context);
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return PopScope(
      canPop: false,
      child: Semantics(
        key: const ValueKey('sheet.audio-recording'),
        container: true,
        explicitChildNodes: true,
        label: 'Audio recording',
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 32,
                height: 4,
                decoration: BoxDecoration(
                  color: colors.onSurfaceVariant.withValues(alpha: 0.4),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Text(
                    'Audio recording',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const Spacer(),
                  TextButton(
                    key: const ValueKey('button.audio.cancel'),
                    onPressed: _saving ? null : _cancel,
                    child: const Text('Cancel'),
                  ),
                ],
              ),
              const SizedBox(height: 28),
              Text(
                _elapsedTitle,
                style: Theme.of(context).textTheme.displaySmall?.copyWith(
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
              const SizedBox(height: 20),
              _Waveform(active: _recording),
              const SizedBox(height: 20),
              Text(_recording ? 'Recording…' : 'Preparing microphone…'),
              if (_transcriptionSupported) ...[
                const SizedBox(height: 12),
                SwitchListTile(
                  key: const ValueKey('toggle.audio.transcription'),
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Transcribe recording'),
                  subtitle: const Text('Add an on-device transcript'),
                  value: _transcriptionEnabled,
                  onChanged: _saving
                      ? null
                      : (value) =>
                            setState(() => _transcriptionEnabled = value),
                ),
              ],
              if (_error case final error?) ...[
                const SizedBox(height: 16),
                Text(
                  error,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: colors.error),
                ),
              ],
              const SizedBox(height: 28),
              FilledButton.icon(
                key: const ValueKey('button.audio.stop'),
                onPressed: _recording && !_saving ? _stop : null,
                style: FilledButton.styleFrom(
                  backgroundColor: colors.error,
                  foregroundColor: colors.onError,
                  minimumSize: const Size(200, 56),
                ),
                icon: _saving
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.stop_rounded),
                label: Text(_saving ? 'Saving…' : 'Stop recording'),
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }

  String get _elapsedTitle {
    final minutes = (_elapsedSeconds ~/ 60).toString().padLeft(2, '0');
    final seconds = (_elapsedSeconds % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }
}

final class _Waveform extends StatelessWidget {
  const _Waveform({required this.active});

  final bool active;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 64,
    child: Row(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: List.generate(17, (index) {
        final height = active ? 12.0 + (index % 5) * 9 : 8.0;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          width: 4,
          height: height,
          margin: const EdgeInsets.symmetric(horizontal: 3),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.primary,
            borderRadius: BorderRadius.circular(2),
          ),
        );
      }),
    ),
  );
}
