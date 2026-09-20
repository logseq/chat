import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:logseq_chat_flutter/core_effect_executor.dart';
import 'package:logseq_chat_flutter/native_effect_drain.dart';

void main() {
  const successfulResponse = '{"apiVersion":1,"ok":true,"result":{}}';

  test(
    'routes every core-backed effect through the native RPC contract',
    () async {
      final requests = <Map<String, Object?>>[];
      final executor = CoreEffectExecutor(
        callCore: (request) async {
          requests.add(jsonDecode(request) as Map<String, Object?>);
          return successfulResponse;
        },
        executePlatformEffect: (_) async =>
            const NativeEffectResolution.discard(),
        executeGraphEffect: (_) async => const NativeEffectResolution.discard(),
        nowMilliseconds: () => 1234,
        newUuid: () => 'operation-id',
      );

      final cases = <(NativeEffect, String)>[
        (const NativeEffect(id: 1, kind: 'send-capture', text: 'Note'), 'send'),
        (
          const NativeEffect(
            id: 2,
            kind: 'send-task',
            text: 'Task',
            metadata:
                '{"uuid":"todo","ident":"status.todo","title":"Todo",'
                '"iconType":null,"iconId":null,"iconColor":null}',
          ),
          'sendTask',
        ),
        (
          const NativeEffect(id: 3, kind: 'search-nodes', text: 'query'),
          'searchNodes',
        ),
        (
          const NativeEffect(id: 4, kind: 'open-node', text: 'node'),
          'openNode',
        ),
        (
          const NativeEffect(id: 5, kind: 'close-node', text: 'node'),
          'closeNode',
        ),
        (
          const NativeEffect(id: 6, kind: 'select-sidebar-page', text: 'page'),
          'selectPage',
        ),
        (
          const NativeEffect(id: 7, kind: 'clear-selected-page', text: ''),
          'clearSelectedPage',
        ),
        (
          const NativeEffect(id: 8, kind: 'load-older-journals', text: ''),
          'loadOlderJournals',
        ),
        (
          const NativeEffect(
            id: 9,
            kind: 'set-page-favorite',
            text: 'page',
            value: 1,
          ),
          'setPageFavorite',
        ),
        (
          const NativeEffect(id: 10, kind: 'delete-page', text: 'page'),
          'deletePage',
        ),
        (
          const NativeEffect(id: 11, kind: 'load-flashcards', text: ''),
          'loadFlashcards',
        ),
        (
          const NativeEffect(
            id: 12,
            kind: 'review-flashcard',
            text: 'good',
            uuid: 'card',
          ),
          'reviewFlashcard',
        ),
        (
          const NativeEffect(id: 13, kind: 'refresh-graphs', text: ''),
          'refresh',
        ),
        (
          const NativeEffect(id: 17, kind: 'tap-outliner-block', text: 'block'),
          'outlinerEvent',
        ),
        (
          const NativeEffect(
            id: 18,
            kind: 'toggle-outliner-collapsed',
            text: 'block',
          ),
          'outlinerEvent',
        ),
        (
          const NativeEffect(
            id: 19,
            kind: 'long-press-outliner-block',
            text: 'block',
          ),
          'outlinerEvent',
        ),
        (
          const NativeEffect(id: 20, kind: 'add-root-block', text: 'block'),
          'outlinerEvent',
        ),
        (
          const NativeEffect(
            id: 21,
            kind: 'drop-outliner-blocks',
            text: 'target',
            metadata: 'inside',
          ),
          'outlinerEvent',
        ),
        (
          const NativeEffect(
            id: 22,
            kind: 'set-outliner-task-status',
            text: 'block',
            metadata:
                '{"uuid":"done","ident":"status.done","title":"Done",'
                '"iconType":null,"iconId":null,"iconColor":null}',
          ),
          'outlinerEvent',
        ),
        (
          const NativeEffect(id: 23, kind: 'outliner-toolbar', text: 'indent'),
          'outlinerEvent',
        ),
        (
          const NativeEffect(
            id: 24,
            kind: 'choose-outliner-autocomplete',
            text: '[[Page]]',
          ),
          'outlinerEvent',
        ),
        (
          const NativeEffect(id: 25, kind: 'cancel-outliner-editing', text: ''),
          'outlinerEvent',
        ),
        (
          const NativeEffect(
            id: 26,
            kind: 'change-outliner-text',
            text: 'Updated',
            uuid: 'block',
            value: 7,
          ),
          'outlinerEvent',
        ),
        (
          const NativeEffect(
            id: 27,
            kind: 'return-outliner-editor',
            text: 'Updated',
            uuid: 'block',
            value: 7,
          ),
          'outlinerEvent',
        ),
        (
          const NativeEffect(
            id: 28,
            kind: 'backspace-outliner-editor',
            text: '',
            uuid: 'block',
            value: 0,
          ),
          'outlinerEvent',
        ),
        (
          const NativeEffect(
            id: 29,
            kind: 'move-outliner-caret',
            text: '',
            uuid: 'block',
            value: 4,
          ),
          'outlinerEvent',
        ),
      ];

      for (final (effect, expectedAction) in cases) {
        final resolution = await executor.execute(effect);
        expect(resolution.succeeded, isTrue, reason: effect.kind);
        expect(resolution.output, NativeEffectOutputKind.coreResponse);
        expect(
          ((requests.last['params'] as Map<String, Object?>)['action']),
          expectedAction,
          reason: effect.kind,
        );
      }
    },
  );

  test('delegates Android-owned effects without touching the core', () async {
    final delegated = <String>[];
    final executor = CoreEffectExecutor(
      callCore: (_) async => fail('platform effects must not call the core'),
      executePlatformEffect: (effect) async {
        delegated.add(effect.kind);
        return const NativeEffectResolution.discard();
      },
      executeGraphEffect: (_) async => const NativeEffectResolution.discard(),
    );

    const kinds = [
      'persist-composer-draft',
      'present-attachment',
      'present-asset',
      'present-page-share',
      'sync-now',
      'delete-local-graph',
      'save-settings',
      'export-graph-database',
      'open-external-url',
      'refresh-runtime-log',
      'copy-runtime-log',
      'sign-in',
      'sign-out',
    ];

    for (final kind in kinds) {
      await executor.execute(NativeEffect(id: 1, kind: kind, text: ''));
    }

    expect(delegated, kinds);
  });

  test('delegates graph lifecycle effects without issuing raw RPCs', () async {
    final delegated = <String>[];
    final executor = CoreEffectExecutor(
      callCore: (_) async => fail('graph effects must use the lifecycle'),
      executePlatformEffect: (_) async =>
          const NativeEffectResolution.discard(),
      executeGraphEffect: (effect) async {
        delegated.add(effect.kind);
        return const NativeEffectResolution.discard();
      },
    );

    for (final kind in ['open-graph', 'unlock-graph', 'create-graph']) {
      await executor.execute(NativeEffect(id: 1, kind: kind, text: 'graph'));
    }

    expect(delegated, ['open-graph', 'unlock-graph', 'create-graph']);
  });

  test(
    'surfaces typed native core failures without applying a snapshot',
    () async {
      final executor = CoreEffectExecutor(
        callCore: (_) async =>
            '{"apiVersion":1,"ok":false,"error":{"code":"invalid",'
            '"message":"Bad request"}}',
        executePlatformEffect: (_) async =>
            const NativeEffectResolution.discard(),
        executeGraphEffect: (_) async => const NativeEffectResolution.discard(),
      );

      final resolution = await executor.execute(
        const NativeEffect(id: 1, kind: 'search-nodes', text: 'query'),
      );

      expect(resolution.succeeded, isFalse);
      expect(resolution.output, NativeEffectOutputKind.discard);
      expect(resolution.message, 'invalid\nBad request');
    },
  );

  test('rejects unknown effects explicitly', () async {
    final executor = CoreEffectExecutor(
      callCore: (_) async => successfulResponse,
      executePlatformEffect: (_) async =>
          const NativeEffectResolution.discard(),
      executeGraphEffect: (_) async => const NativeEffectResolution.discard(),
    );

    final resolution = await executor.execute(
      const NativeEffect(id: 1, kind: 'unknown-effect', text: ''),
    );

    expect(resolution.succeeded, isFalse);
    expect(resolution.message, 'Unsupported LG effect: unknown-effect');
  });

  test('autosave reuses the authoritative core saveEditing event', () async {
    Map<String, Object?>? request;
    final executor = CoreEffectExecutor(
      callCore: (encoded) async {
        request = jsonDecode(encoded) as Map<String, Object?>;
        return successfulResponse;
      },
      executePlatformEffect: (_) async =>
          const NativeEffectResolution.discard(),
      executeGraphEffect: (_) async => const NativeEffectResolution.discard(),
    );

    final resolution = await executor.execute(
      const NativeEffect(id: 0, kind: 'save-outliner-editing', text: ''),
    );

    final params = request!['params']! as Map<String, Object?>;
    expect(params['action'], 'outlinerEvent');
    expect(jsonDecode(params['payload']! as String), {'type': 'saveEditing'});
    expect(resolution.succeeded, isTrue);
  });
}
