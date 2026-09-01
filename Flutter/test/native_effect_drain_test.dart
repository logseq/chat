import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:logseq_chat_flutter/native_effect_drain.dart';

void main() {
  test(
    'drains effects in order and applies core snapshots before resolution',
    () async {
      final runtime = _RecordingRuntime([
        _dispatch(id: 1, kind: 'refresh-graphs', patch: 'dequeue-1'),
        _dispatch(id: 2, kind: 'load-page', patch: 'dequeue-2'),
      ]);
      final operations = runtime.operations;
      final drain = NativeEffectDrain(
        runtime: runtime,
        execute: (effect) async {
          operations.add('execute:${effect.id}:${effect.kind}');
          return NativeEffectResolution.coreResponse('response-${effect.id}');
        },
        applyPatch: (patch) => operations.add('patch:$patch'),
        afterCoreResponseApplied: (response) async {
          operations.add('commands:$response');
        },
        onError: (error, _) => fail('Unexpected error: $error'),
      );

      await drain.drain();

      expect(operations, [
        'take',
        'patch:dequeue-1',
        'execute:1:refresh-graphs',
        'snapshot:response-1',
        'patch:snapshot-patch',
        'commands:response-1',
        'resolve:1:true:response-1',
        'patch:resolve-patch',
        'take',
        'patch:dequeue-2',
        'execute:2:load-page',
        'snapshot:response-2',
        'patch:snapshot-patch',
        'commands:response-2',
        'resolve:2:true:response-2',
        'patch:resolve-patch',
        'take',
      ]);
    },
  );

  test(
    'discard output resolves without applying a snapshot or host update',
    () async {
      final runtime = _RecordingRuntime([
        _dispatch(id: 3, kind: 'persist-composer-draft', patch: 'dequeue'),
      ]);
      final drain = NativeEffectDrain(
        runtime: runtime,
        execute: (_) async => const NativeEffectResolution.discard(),
        applyPatch: (patch) => runtime.operations.add('patch:$patch'),
        onError: (error, _) => fail('Unexpected error: $error'),
      );

      await drain.drain();

      expect(runtime.operations, [
        'take',
        'patch:dequeue',
        'resolve:3:true:',
        'patch:resolve-patch',
        'take',
      ]);
    },
  );

  test('host output is published before the effect is resolved', () async {
    final runtime = _RecordingRuntime([
      _dispatch(id: 4, kind: 'refresh-runtime-log', patch: 'dequeue'),
    ]);
    final drain = NativeEffectDrain(
      runtime: runtime,
      execute: (_) async => const NativeEffectResolution.hostUpdate(
        kind: 'runtime-log',
        payload: '[{"message":"ready"}]',
      ),
      applyPatch: (patch) => runtime.operations.add('patch:$patch'),
      onError: (error, _) => fail('Unexpected error: $error'),
    );

    await drain.drain();

    expect(runtime.operations, [
      'take',
      'patch:dequeue',
      'host:runtime-log:[{"message":"ready"}]',
      'patch:host-patch',
      'resolve:4:true:[{"message":"ready"}]',
      'patch:resolve-patch',
      'take',
    ]);
  });

  test(
    'failed execution rolls back through resolve without publishing output',
    () async {
      final runtime = _RecordingRuntime([
        _dispatch(id: 5, kind: 'sign-in', patch: 'signing-in'),
      ]);
      final drain = NativeEffectDrain(
        runtime: runtime,
        execute: (_) async => const NativeEffectResolution.discard(
          succeeded: false,
          message: 'Hosted sign-in failed',
        ),
        applyPatch: (patch) => runtime.operations.add('patch:$patch'),
        onError: (error, _) => fail('Unexpected error: $error'),
      );

      await drain.drain();

      expect(runtime.operations, [
        'take',
        'patch:signing-in',
        'resolve:5:false:Hosted sign-in failed',
        'patch:resolve-patch',
        'take',
      ]);
    },
  );

  test('traces every effect from dequeue through resolution', () async {
    final runtime = _RecordingRuntime([
      _dispatch(id: 14, kind: 'open-graph', text: 'graph-remote'),
    ]);
    final traces = <String>[];
    final drain = NativeEffectDrain(
      runtime: runtime,
      execute: (_) async => const NativeEffectResolution.discard(
        succeeded: false,
        message: 'graph_open_failed\nSnapshot download timed out',
      ),
      applyPatch: (_) {},
      onError: (error, _) => fail('Unexpected error: $error'),
      trace: traces.add,
    );

    await drain.drain();

    expect(traces, hasLength(2));
    expect(traces.first, 'start id=14 kind=open-graph');
    expect(
      traces.last,
      startsWith(
        'finish id=14 kind=open-graph succeeded=false output=discard '
        'elapsedMs=',
      ),
    );
    expect(traces.last, contains('message=graph_open_failed'));
    expect(traces.last, contains('Snapshot download timed out'));
  });

  test('traces search response query and result count without result text', () async {
    final runtime = _RecordingRuntime([
      _dispatch(id: 15, kind: 'search-nodes', text: 'private query'),
    ]);
    final traces = <String>[];
    final drain = NativeEffectDrain(
      runtime: runtime,
      execute: (_) async => NativeEffectResolution.coreResponse(
        jsonEncode({
          'ok': true,
          'result': {
            'searchQuery': 'private query',
            'searchResults': [
              {'title': 'sensitive result'},
              {'title': 'another result'},
            ],
          },
        }),
      ),
      applyPatch: (_) {},
      onError: (error, _) => fail('Unexpected error: $error'),
      trace: traces.add,
    );

    await drain.drain();

    expect(traces.last, contains('searchQueryChars=13 searchResults=2'));
    expect(traces.last, isNot(contains('private query')));
    expect(traces.last, isNot(contains('sensitive result')));
  });

  test('preserves optional effect values for platform execution', () async {
    final runtime = _RecordingRuntime([
      _dispatch(
        id: 8,
        kind: 'present-asset',
        text: 'asset.png',
        uuid: 'block-a',
        value: 42,
        metadata: '{"assetType":"image"}',
      ),
    ]);
    NativeEffect? received;
    final drain = NativeEffectDrain(
      runtime: runtime,
      execute: (effect) async {
        received = effect;
        return const NativeEffectResolution.discard();
      },
      applyPatch: (_) {},
      onError: (error, _) => fail('Unexpected error: $error'),
    );

    await drain.drain();

    expect(received?.id, 8);
    expect(received?.kind, 'present-asset');
    expect(received?.text, 'asset.png');
    expect(received?.uuid, 'block-a');
    expect(received?.value, 42);
    expect(received?.metadata, '{"assetType":"image"}');
  });

  test(
    'reports malformed native payloads and stops the current drain',
    () async {
      final runtime = _RecordingRuntime(['not-json', _dispatch(id: 6)]);
      final errors = <Object>[];
      final drain = NativeEffectDrain(
        runtime: runtime,
        execute: (_) async => const NativeEffectResolution.discard(),
        applyPatch: (patch) => runtime.operations.add('patch:$patch'),
        onError: (error, _) => errors.add(error),
      );

      await drain.drain();

      expect(errors.single, isA<FormatException>());
      expect(runtime.operations, ['take']);
    },
  );

  test(
    'coalesces concurrent drain requests without executing an effect twice',
    () async {
      final runtime = _RecordingRuntime([_dispatch(id: 7)]);
      final executionStarted = Completer<void>();
      final allowExecutionToFinish = Completer<void>();
      var executions = 0;
      final drain = NativeEffectDrain(
        runtime: runtime,
        execute: (_) async {
          executions += 1;
          executionStarted.complete();
          await allowExecutionToFinish.future;
          return const NativeEffectResolution.discard();
        },
        applyPatch: (_) {},
        onError: (error, _) => fail('Unexpected error: $error'),
      );

      final first = drain.drain();
      await executionStarted.future;
      final second = drain.drain();
      allowExecutionToFinish.complete();
      await Future.wait([first, second]);

      expect(executions, 1);
      expect(
        runtime.operations.where((entry) => entry == 'take'),
        hasLength(2),
      );
    },
  );

  test('debounces text editing into the core autosave action', () async {
    final runtime = _RecordingRuntime([
      _dispatch(id: 9, kind: 'change-outliner-text', patch: 'dequeue'),
    ]);
    final effects = <String>[];
    final autosaved = Completer<void>();
    final drain = NativeEffectDrain(
      runtime: runtime,
      outlinerAutosaveDelay: Duration.zero,
      execute: (effect) async {
        effects.add(effect.kind);
        if (effect.kind == 'save-outliner-editing') autosaved.complete();
        return const NativeEffectResolution.coreResponse(
          '{"ok":true,"result":{"outlinerState":{"autocomplete":null}}}',
        );
      },
      applyPatch: (_) {},
      onError: (error, _) => fail('Unexpected error: $error'),
    );

    await drain.drain();
    await autosaved.future.timeout(const Duration(seconds: 1));

    expect(effects, ['change-outliner-text', 'save-outliner-editing']);
    drain.dispose();
  });

  test('does not autosave while autocomplete is visible', () async {
    final runtime = _RecordingRuntime([
      _dispatch(id: 10, kind: 'change-outliner-text', patch: 'dequeue'),
    ]);
    final effects = <String>[];
    final drain = NativeEffectDrain(
      runtime: runtime,
      outlinerAutosaveDelay: Duration.zero,
      execute: (effect) async {
        effects.add(effect.kind);
        return const NativeEffectResolution.coreResponse(
          '{"ok":true,"result":{"outlinerState":{"autocomplete":{"query":"#"}}}}',
        );
      },
      applyPatch: (_) {},
      onError: (error, _) => fail('Unexpected error: $error'),
    );

    await drain.drain();
    await Future<void>.delayed(Duration.zero);

    expect(effects, ['change-outliner-text']);
    drain.dispose();
  });

  test('rapid text changes collapse into one autosave', () async {
    final runtime = _RecordingRuntime([
      _dispatch(id: 11, kind: 'change-outliner-text', patch: 'dequeue-1'),
      _dispatch(id: 12, kind: 'change-outliner-text', patch: 'dequeue-2'),
    ]);
    final effects = <String>[];
    final autosaved = Completer<void>();
    final drain = NativeEffectDrain(
      runtime: runtime,
      outlinerAutosaveDelay: const Duration(milliseconds: 10),
      execute: (effect) async {
        effects.add(effect.kind);
        if (effect.kind == 'save-outliner-editing') autosaved.complete();
        return const NativeEffectResolution.coreResponse(
          '{"ok":true,"result":{"outlinerState":{"autocomplete":null}}}',
        );
      },
      applyPatch: (_) {},
      onError: (error, _) => fail('Unexpected error: $error'),
    );

    await drain.drain();
    await autosaved.future.timeout(const Duration(seconds: 1));

    expect(effects, [
      'change-outliner-text',
      'change-outliner-text',
      'save-outliner-editing',
    ]);
    drain.dispose();
  });
}

String _dispatch({
  int id = 1,
  String kind = 'effect',
  String text = '',
  String patch = '',
  String? uuid,
  int? value,
  String? metadata,
}) => jsonEncode({
  'effect': {
    'id': id,
    'kind': kind,
    'text': text,
    'uuid': ?uuid,
    'value': ?value,
    'metadata': ?metadata,
  },
  'patch': patch,
});

final class _RecordingRuntime implements NativeEffectRuntime {
  _RecordingRuntime(List<String> effects) : _effects = List.of(effects);

  final List<String> _effects;
  final operations = <String>[];

  @override
  String applyHostUpdate({required String kind, required String payload}) {
    operations.add('host:$kind:$payload');
    return 'host-patch';
  }

  @override
  String applySnapshot(String response) {
    operations.add('snapshot:$response');
    return 'snapshot-patch';
  }

  @override
  String resolveEffect({
    required int id,
    required bool succeeded,
    required String message,
  }) {
    operations.add('resolve:$id:$succeeded:$message');
    return 'resolve-patch';
  }

  @override
  String takeEffect() {
    operations.add('take');
    return _effects.isEmpty ? '' : _effects.removeAt(0);
  }
}
