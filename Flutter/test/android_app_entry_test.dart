import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:logseq_chat_flutter/android_app_entry.dart';

void main() {
  test('parses supported Android app entries', () {
    expect(
      AndroidAppEntry.fromMap(const {'kind': 'open-capture'}).kind,
      AndroidAppEntryKind.openCapture,
    );
    expect(
      AndroidAppEntry.fromMap(const {'kind': 'open-journal'}).kind,
      AndroidAppEntryKind.openJournal,
    );
    final shared = AndroidAppEntry.fromMap(const {
      'kind': 'shared-text',
      'text': 'A shared note',
    });
    expect(shared.kind, AndroidAppEntryKind.sharedText);
    expect(shared.text, 'A shared note');
    expect(shared.coreRequest(uuid: 'capture-id', nowMilliseconds: 42), {
      'apiVersion': 1,
      'method': 'dispatch',
      'params': {
        'action': 'send',
        'payload': '{"text":"A shared note","uuid":"capture-id","now":42}',
      },
    });
  });

  test('rejects malformed app entries', () {
    expect(
      () => AndroidAppEntry.fromMap(const {'kind': 'shared-text', 'text': ''}),
      throwsFormatException,
    );
    expect(
      () => AndroidAppEntry.fromMap(const {'kind': 'unknown'}),
      throwsFormatException,
    );
  });

  test('queues cold-start entries until core restore is ready', () async {
    final stream = StreamController<Map<String, Object?>>(sync: true);
    addTearDown(stream.close);
    final handled = <AndroidAppEntryKind>[];
    final coordinator = AndroidAppEntryCoordinator(
      entries: stream.stream,
      handle: (entry) async => handled.add(entry.kind),
    )..start();
    addTearDown(coordinator.dispose);

    stream.add(const {'kind': 'open-capture'});
    stream.add(const {'kind': 'open-journal'});
    await Future<void>.delayed(Duration.zero);
    expect(handled, isEmpty);

    await coordinator.markReady();
    expect(handled, [
      AndroidAppEntryKind.openCapture,
      AndroidAppEntryKind.openJournal,
    ]);

    stream.add(const {'kind': 'shared-text', 'text': 'Warm share'});
    await coordinator.settled;
    expect(handled.last, AndroidAppEntryKind.sharedText);
  });

  test('retains a failed entry for a later retry', () async {
    final stream = StreamController<Map<String, Object?>>(sync: true);
    addTearDown(stream.close);
    var attempts = 0;
    final errors = <Object>[];
    final coordinator = AndroidAppEntryCoordinator(
      entries: stream.stream,
      handle: (_) async {
        attempts += 1;
        if (attempts == 1) throw StateError('core is restoring');
      },
      onError: (error, _) => errors.add(error),
    )..start();
    addTearDown(coordinator.dispose);

    stream.add(const {'kind': 'shared-text', 'text': 'Retain me'});
    await coordinator.markReady();
    expect(attempts, 1);
    expect(errors, hasLength(1));

    await coordinator.markReady();
    expect(attempts, 2);
  });
}
