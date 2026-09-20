import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:logseq_chat_flutter/native_runtime_scheduler.dart';

void main() {
  test('defers UI native calls while a core call owns the runtime', () async {
    final scheduler = NativeRuntimeScheduler();
    final core = Completer<String>();
    final events = <String>[];

    final result = scheduler.runCore(() async {
      events.add('core-start');
      return core.future;
    });
    await Future<void>.delayed(Duration.zero);

    scheduler.runUi(() => events.add('ui'));
    expect(events, ['core-start']);

    core.complete('done');
    expect(await result, 'done');
    expect(events, ['core-start', 'ui']);
  });

  test(
    'serializes core calls and flushes UI only after all core work',
    () async {
      final scheduler = NativeRuntimeScheduler();
      final first = Completer<void>();
      final events = <String>[];

      final firstResult = scheduler.runCore(() async {
        events.add('core-1-start');
        await first.future;
        events.add('core-1-end');
        return 1;
      });
      final secondResult = scheduler.runCore(() async {
        events.add('core-2');
        return 2;
      });
      scheduler.runUi(() => events.add('ui'));
      await Future<void>.delayed(Duration.zero);

      expect(events, ['core-1-start']);
      first.complete();
      expect(await firstResult, 1);
      expect(await secondResult, 2);
      expect(events, ['core-1-start', 'core-1-end', 'core-2', 'ui']);
    },
  );

  test('reports idle after deferred UI calls are flushed', () async {
    final events = <String>[];
    late final NativeRuntimeScheduler scheduler;
    scheduler = NativeRuntimeScheduler(onIdle: () => events.add('idle'));
    final core = Completer<void>();

    final result = scheduler.runCore(() => core.future);
    scheduler.runUi(() => events.add('ui'));
    await Future<void>.delayed(Duration.zero);
    expect(scheduler.isCoreBusy, isTrue);

    core.complete();
    await result;
    expect(scheduler.isCoreBusy, isFalse);
    expect(events, ['ui', 'idle']);
  });
}
