import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:logseq_chat_flutter/android_graph_lifecycle.dart';
import 'package:logseq_chat_flutter/android_platform_effects.dart';
import 'package:logseq_chat_flutter/native_effect_drain.dart';

void main() {
  test(
    'creating a graph downloads and imports its first local snapshot',
    () async {
      final core = _RecordingCore();
      final platform = _GraphPlatform();
      final lifecycle = AndroidGraphLifecycle(
        callCore: core.call,
        platform: platform,
      );

      final resolution = await lifecycle.execute(
        const NativeEffect(
          id: 1,
          kind: 'create-graph',
          text: 'Android notes',
          value: 0,
        ),
      );

      expect(resolution.succeeded, isTrue);
      expect(resolution.output, NativeEffectOutputKind.coreResponse);
      expect(core.actions, [
        'createSyncGraph',
        'selectGraph',
        'importSnapshot',
      ]);
      expect(platform.downloadedGraphIds, ['graph-new']);
      expect(platform.persistedGraphIds, ['graph-new']);
      expect(platform.deletedTemporaryFiles, ['/tmp/graph-new.snapshot']);
      expect(core.payloadFor('importSnapshot'), {
        'graphId': 'graph-new',
        'activePath': '/data/graphs/graph-new/graph.sqlite',
        'checkpointPath': '/data/graphs/graph-new/sync.checkpoint',
        'metadataBody': '{"ok":true,"t":0,"row-count":1}',
        'downloadPath': '/tmp/graph-new.snapshot',
        'isEncrypted': false,
      });
    },
  );

  test('opening an existing local graph avoids a snapshot download', () async {
    final core = _RecordingCore();
    final platform = _GraphPlatform(localGraphIds: const ['graph-local']);
    final lifecycle = AndroidGraphLifecycle(
      callCore: core.call,
      platform: platform,
    );

    final resolution = await lifecycle.execute(
      const NativeEffect(id: 2, kind: 'open-graph', text: 'graph-local'),
    );

    expect(resolution.succeeded, isTrue);
    expect(core.actions, ['selectGraph', 'openGraph']);
    expect(platform.downloadedGraphIds, isEmpty);
    expect(platform.persistedGraphIds, ['graph-local']);
    expect(core.payloadFor('openGraph'), {
      'graphId': 'graph-local',
      'activePath': '/data/graphs/graph-local/graph.sqlite',
      'checkpointPath': '/data/graphs/graph-local/sync.checkpoint',
      'isEncrypted': false,
    });
  });

  test('an encrypted graph is imported with encryption enabled', () async {
    final core = _RecordingCore(encryptedGraphIds: const {'graph-private'});
    final platform = _GraphPlatform();
    final lifecycle = AndroidGraphLifecycle(
      callCore: core.call,
      platform: platform,
    );

    final resolution = await lifecycle.execute(
      const NativeEffect(id: 3, kind: 'open-graph', text: 'graph-private'),
    );

    expect(resolution.succeeded, isTrue);
    expect(core.payloadFor('importSnapshot')?['isEncrypted'], isTrue);
    expect(platform.persistedGraphIds, ['graph-private']);
  });

  test('traces each remote graph download and import stage', () async {
    final core = _RecordingCore();
    final platform = _GraphPlatform();
    final traces = <String>[];
    final lifecycle = AndroidGraphLifecycle(
      callCore: core.call,
      platform: platform,
      trace: traces.add,
    );

    final resolution = await lifecycle.execute(
      const NativeEffect(id: 7, kind: 'open-graph', text: 'graph-remote'),
    );

    expect(resolution.succeeded, isTrue);
    expect(traces, [
      'open.start graphId=graph-remote',
      'select.complete graphId=graph-remote',
      'storage.loaded graphId=graph-remote local=false',
      'snapshot.download.start graphId=graph-remote baseUrl=http://127.0.0.1:8787',
      'snapshot.download.complete graphId=graph-remote path=/tmp/graph-remote.snapshot',
      'snapshot.import.start graphId=graph-remote',
      'snapshot.import.complete graphId=graph-remote',
      'selection.persist.complete graphId=graph-remote',
      'open.complete graphId=graph-remote',
    ]);
  });

  test('a failed graph creation does not open or persist a graph', () async {
    final core = _RecordingCore(failingAction: 'createSyncGraph');
    final platform = _GraphPlatform();
    final lifecycle = AndroidGraphLifecycle(
      callCore: core.call,
      platform: platform,
    );

    final resolution = await lifecycle.execute(
      const NativeEffect(
        id: 4,
        kind: 'create-graph',
        text: 'Broken graph',
        value: 0,
      ),
    );

    expect(resolution.succeeded, isFalse);
    expect(core.actions, ['createSyncGraph']);
    expect(platform.persistedGraphIds, isEmpty);
    expect(platform.downloadedGraphIds, isEmpty);
  });

  test('a failed import cleans its download and does not persist', () async {
    final core = _RecordingCore(failingAction: 'importSnapshot');
    final platform = _GraphPlatform();
    final lifecycle = AndroidGraphLifecycle(
      callCore: core.call,
      platform: platform,
    );

    final resolution = await lifecycle.execute(
      const NativeEffect(id: 5, kind: 'open-graph', text: 'graph-remote'),
    );

    expect(resolution.succeeded, isFalse);
    expect(platform.deletedTemporaryFiles, ['/tmp/graph-remote.snapshot']);
    expect(platform.persistedGraphIds, isEmpty);
  });

  test('a snapshot transport exception becomes a graph open error', () async {
    final core = _RecordingCore();
    final platform = _GraphPlatform(
      downloadError: const HttpExceptionForTest('Connection refused'),
    );
    final lifecycle = AndroidGraphLifecycle(
      callCore: core.call,
      platform: platform,
    );

    final resolution = await lifecycle.execute(
      const NativeEffect(id: 8, kind: 'open-graph', text: 'graph-remote'),
    );

    expect(resolution.succeeded, isFalse);
    expect(
      resolution.message,
      'graph_open_failed\nHttpExceptionForTest: Connection refused',
    );
    expect(platform.persistedGraphIds, isEmpty);
  });

  test('unlock delegates to the core without reopening storage', () async {
    final core = _RecordingCore();
    final platform = _GraphPlatform();
    final lifecycle = AndroidGraphLifecycle(
      callCore: core.call,
      platform: platform,
    );

    final resolution = await lifecycle.execute(
      const NativeEffect(id: 6, kind: 'unlock-graph', text: 'secret'),
    );

    expect(resolution.succeeded, isTrue);
    expect(core.actions, ['unlockGraph']);
    expect(platform.downloadedGraphIds, isEmpty);
  });
}

final class _RecordingCore {
  _RecordingCore({this.failingAction, this.encryptedGraphIds = const {}});

  final String? failingAction;
  final Set<String> encryptedGraphIds;
  final List<Map<String, Object?>> requests = [];

  List<String> get actions => requests
      .map((request) => request['params']! as Map<String, Object?>)
      .map((params) => params['action']! as String)
      .toList(growable: false);

  Map<String, Object?>? payloadFor(String action) {
    final request = requests.firstWhere(
      (request) =>
          (request['params']! as Map<String, Object?>)['action'] == action,
    );
    final payload = (request['params']! as Map<String, Object?>)['payload'];
    return payload is String
        ? jsonDecode(payload) as Map<String, Object?>
        : null;
  }

  Future<String> call(String encoded) async {
    final request = jsonDecode(encoded) as Map<String, Object?>;
    requests.add(request);
    final params = request['params']! as Map<String, Object?>;
    final action = params['action']! as String;
    if (action == failingAction) {
      return _response(
        ok: false,
        result: const {},
        errorCode: 'test_failure',
        errorMessage: '$action failed',
      );
    }
    if (action == 'createSyncGraph') {
      return _response(result: _snapshot(selectedGraphId: 'graph-new'));
    }
    if (action == 'selectGraph') {
      final graphId = params['payload']! as String;
      return _response(result: _snapshot(selectedGraphId: graphId));
    }
    return _response(result: _snapshot(selectedGraphId: 'graph-open'));
  }

  Map<String, Object?> _snapshot({required String selectedGraphId}) => {
    'selectedGraphId': selectedGraphId,
    'graphs': [
      {
        'id': selectedGraphId,
        'name': selectedGraphId,
        'isEncrypted': encryptedGraphIds.contains(selectedGraphId),
        'ready': true,
      },
    ],
  };

  String _response({
    bool ok = true,
    required Map<String, Object?> result,
    String? errorCode,
    String? errorMessage,
  }) => jsonEncode({
    'apiVersion': 1,
    'ok': ok,
    if (ok) 'result': result,
    if (!ok) 'error': {'code': errorCode, 'message': errorMessage},
  });
}

final class _GraphPlatform extends AndroidPlatformServices {
  _GraphPlatform({this.localGraphIds = const [], this.downloadError});

  final List<String> localGraphIds;
  final Object? downloadError;
  final List<String> downloadedGraphIds = [];
  final List<String> persistedGraphIds = [];
  final List<String> deletedTemporaryFiles = [];

  @override
  Future<AndroidStorageState> loadStorageState() async => AndroidStorageState(
    databasePath: '/data/catalog.sqlite',
    graphsDirectory: '/data/graphs',
    baseUrl: 'http://127.0.0.1:8787',
    selectedGraphId: '',
    localGraphIds: localGraphIds,
  );

  @override
  Future<AndroidDownloadedSnapshot> downloadGraphSnapshot({
    required String baseUrl,
    required String graphId,
    required String accessToken,
    required String workingDirectory,
  }) async {
    final error = downloadError;
    if (error != null) throw error;
    downloadedGraphIds.add(graphId);
    return AndroidDownloadedSnapshot(
      metadataBody: '{"ok":true,"t":0,"row-count":1}',
      filePath: '/tmp/$graphId.snapshot',
    );
  }

  @override
  Future<void> persistSelectedGraphId(String graphId) async {
    persistedGraphIds.add(graphId);
  }

  @override
  Future<void> deleteTemporaryFile(String path) async {
    deletedTemporaryFiles.add(path);
  }
}

final class HttpExceptionForTest implements Exception {
  const HttpExceptionForTest(this.message);

  final String message;

  @override
  String toString() => 'HttpExceptionForTest: $message';
}
