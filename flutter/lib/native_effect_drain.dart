import 'dart:async';
import 'dart:convert';

abstract interface class NativeEffectRuntime {
  String takeEffect();

  String resolveEffect({
    required int id,
    required bool succeeded,
    required String message,
  });

  String applySnapshot(String response);

  String applyHostUpdate({required String kind, required String payload});
}

final class NativeEffect {
  const NativeEffect({
    required this.id,
    required this.kind,
    required this.text,
    this.uuid,
    this.value,
    this.metadata,
  });

  final int id;
  final String kind;
  final String text;
  final String? uuid;
  final int? value;
  final String? metadata;
}

enum NativeEffectOutputKind { coreResponse, hostUpdate, discard }

final class NativeEffectResolution {
  const NativeEffectResolution({
    required this.succeeded,
    required this.message,
    required this.output,
    this.hostUpdateKind,
  });

  const NativeEffectResolution.coreResponse(String response)
    : succeeded = true,
      message = response,
      output = NativeEffectOutputKind.coreResponse,
      hostUpdateKind = null;

  const NativeEffectResolution.hostUpdate({
    required String kind,
    required String payload,
  }) : succeeded = true,
       message = payload,
       output = NativeEffectOutputKind.hostUpdate,
       hostUpdateKind = kind;

  const NativeEffectResolution.discard({
    this.succeeded = true,
    this.message = '',
  }) : output = NativeEffectOutputKind.discard,
       hostUpdateKind = null;

  final bool succeeded;
  final String message;
  final NativeEffectOutputKind output;
  final String? hostUpdateKind;
}

typedef NativeEffectExecutor = Future<NativeEffectResolution> Function(
  NativeEffect effect,
);
typedef CoreResponseApplied = Future<void> Function(String response);
typedef NativeEffectTrace = void Function(String message);

void _ignoreNativeEffectTrace(String message) {}

final class NativeEffectDrain {
  NativeEffectDrain({
    required this.runtime,
    required this.execute,
    required this.applyPatch,
    required this.onError,
    this.trace = _ignoreNativeEffectTrace,
    this.afterCoreResponseApplied,
    this.outlinerAutosaveDelay = const Duration(seconds: 1),
  });

  final NativeEffectRuntime runtime;
  final NativeEffectExecutor execute;
  final void Function(String patch) applyPatch;
  final void Function(Object error, StackTrace stackTrace) onError;
  final NativeEffectTrace trace;
  final CoreResponseApplied? afterCoreResponseApplied;
  final Duration outlinerAutosaveDelay;
  Future<void>? _activeDrain;
  Timer? _outlinerAutosaveTimer;
  var _outlinerAutosavePending = false;
  var _disposed = false;

  Future<void> drain() {
    if (_disposed) return Future<void>.value();
    final active = _activeDrain;
    if (active != null) return active;

    late final Future<void> operation;
    operation = _run().whenComplete(() {
      if (identical(_activeDrain, operation)) _activeDrain = null;
    });
    _activeDrain = operation;
    return operation;
  }

  Future<void> _run() async {
    while (true) {
      final encoded = runtime.takeEffect();
      if (encoded.isEmpty) {
        if (_outlinerAutosavePending) {
          _outlinerAutosavePending = false;
          await _executeOutlinerAutosave();
          continue;
        }
        return;
      }

      final _EffectDispatch dispatch;
      try {
        dispatch = _EffectDispatch.decode(encoded);
      } catch (error, stackTrace) {
        onError(error, stackTrace);
        return;
      }

      _apply(dispatch.patch, 'dispatch kind=${dispatch.effect.kind}');
      _cancelOutlinerAutosaveBeforeExecuting(dispatch.effect);
      final stopwatch = Stopwatch()..start();
      trace('start id=${dispatch.effect.id} kind=${dispatch.effect.kind}');
      final resolution = await execute(dispatch.effect);
      stopwatch.stop();
      trace(
        'finish id=${dispatch.effect.id} kind=${dispatch.effect.kind} '
        'succeeded=${resolution.succeeded} output=${resolution.output.name} '
        'elapsedMs=${stopwatch.elapsedMilliseconds} '
        '${_resolutionSummary(dispatch.effect, resolution)}',
      );
      if (resolution.succeeded) {
        switch (resolution.output) {
          case NativeEffectOutputKind.coreResponse:
            _apply(runtime.applySnapshot(resolution.message), 'applySnapshot');
            await afterCoreResponseApplied?.call(resolution.message);
            _scheduleOutlinerAutosaveIfNeeded(
              dispatch.effect,
              resolution.message,
            );
            break;
          case NativeEffectOutputKind.hostUpdate:
            _apply(
              runtime.applyHostUpdate(
                kind: resolution.hostUpdateKind!,
                payload: resolution.message,
              ),
              'applyHostUpdate kind=${resolution.hostUpdateKind}',
            );
            break;
          case NativeEffectOutputKind.discard:
            break;
        }
      }
      _apply(
        runtime.resolveEffect(
          id: dispatch.effect.id,
          succeeded: resolution.succeeded,
          message: resolution.message,
        ),
        'resolveEffect id=${dispatch.effect.id} '
        'succeeded=${resolution.succeeded}',
      );
    }
  }

  void dispose() {
    _disposed = true;
    _outlinerAutosaveTimer?.cancel();
    _outlinerAutosaveTimer = null;
    _outlinerAutosavePending = false;
  }

  void _cancelOutlinerAutosaveBeforeExecuting(NativeEffect effect) {
    if (!effect.kind.contains('outliner') ||
        effect.kind == 'move-outliner-caret') {
      return;
    }
    _outlinerAutosaveTimer?.cancel();
    _outlinerAutosaveTimer = null;
    _outlinerAutosavePending = false;
  }

  void _scheduleOutlinerAutosaveIfNeeded(NativeEffect effect, String response) {
    final shouldSchedule = switch (effect.kind) {
      'choose-outliner-autocomplete' => true,
      'change-outliner-text' => !_responseHasOutlinerAutocomplete(response),
      _ => false,
    };
    if (!shouldSchedule || _disposed) return;
    _outlinerAutosaveTimer?.cancel();
    _outlinerAutosaveTimer = Timer(outlinerAutosaveDelay, () {
      _outlinerAutosaveTimer = null;
      if (_disposed) return;
      _outlinerAutosavePending = true;
      unawaited(drain());
    });
  }

  bool _responseHasOutlinerAutocomplete(String response) {
    try {
      final envelope = jsonDecode(response);
      if (envelope is! Map<String, Object?>) return false;
      final result = envelope['result'];
      if (result is! Map<String, Object?>) return false;
      final state = result['outlinerState'];
      return state is Map<String, Object?> && state['autocomplete'] != null;
    } on FormatException {
      return false;
    }
  }

  Future<void> _executeOutlinerAutosave() async {
    try {
      final resolution = await execute(
        const NativeEffect(id: 0, kind: 'save-outliner-editing', text: ''),
      );
      if (!resolution.succeeded) {
        throw StateError('Outliner autosave failed: ${resolution.message}');
      }
      if (resolution.output != NativeEffectOutputKind.coreResponse) {
        throw StateError('Outliner autosave did not return a core response');
      }
      _apply(
        runtime.applySnapshot(resolution.message),
        'applySnapshot(outliner-autosave)',
      );
      await afterCoreResponseApplied?.call(resolution.message);
    } catch (error, stackTrace) {
      onError(error, stackTrace);
    }
  }

  void _apply(String patch, String source) {
    if (patch.isNotEmpty) {
      applyPatch(patch);
    } else {
      // An OCaml exception in a lui_* FFI call surfaces as an empty patch —
      // log the producer so a wedged pipeline is visible in the drain trace.
      trace('empty patch from $source');
    }
  }

  String _singleLine(String message) => message.replaceAll('\n', r'\n');

  String _resolutionSummary(
    NativeEffect effect,
    NativeEffectResolution resolution,
  ) {
    if (resolution.succeeded) {
      if (effect.kind == 'search-nodes' &&
          resolution.output == NativeEffectOutputKind.coreResponse) {
        try {
          final envelope = jsonDecode(resolution.message);
          final result = envelope is Map<String, Object?>
              ? envelope['result']
              : null;
          if (result is Map<String, Object?>) {
            final query = result['searchQuery'];
            final results = result['searchResults'];
            return 'messageChars=${resolution.message.length} '
                'searchQueryChars=${query is String ? query.length : -1} '
                'searchResults=${results is List<Object?> ? results.length : -1}';
          }
        } on FormatException {
          // The normal response validation reports malformed JSON elsewhere.
        }
      }
      return 'messageChars=${resolution.message.length}';
    }
    final message = _singleLine(resolution.message);
    const limit = 240;
    return 'message=${message.length <= limit ? message : '${message.substring(0, limit)}…'}';
  }
}

final class _EffectDispatch {
  const _EffectDispatch({required this.effect, required this.patch});

  factory _EffectDispatch.decode(String encoded) {
    final decoded = jsonDecode(encoded);
    if (decoded is! Map<String, Object?>) {
      throw const FormatException('Effect dispatch must be an object');
    }
    final effectValue = decoded['effect'];
    final patch = decoded['patch'];
    if (effectValue is! Map<String, Object?> || patch is! String) {
      throw const FormatException('Effect dispatch is missing effect or patch');
    }

    final id = effectValue['id'];
    final kind = effectValue['kind'];
    final text = effectValue['text'];
    final uuid = effectValue['uuid'];
    final value = effectValue['value'];
    final metadata = effectValue['metadata'];
    if (id is! int || kind is! String || text is! String) {
      throw const FormatException('Effect contains invalid required values');
    }
    if (uuid != null && uuid is! String ||
        value != null && value is! int ||
        metadata != null && metadata is! String) {
      throw const FormatException('Effect contains invalid optional values');
    }

    return _EffectDispatch(
      effect: NativeEffect(
        id: id,
        kind: kind,
        text: text,
        uuid: uuid as String?,
        value: value as int?,
        metadata: metadata as String?,
      ),
      patch: patch,
    );
  }

  final NativeEffect effect;
  final String patch;
}
