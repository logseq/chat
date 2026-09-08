import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:logseq_chat_flutter/core_bootstrap.dart';

void main() {
  test(
    'opens the catalog, configures auth, and restores a local graph',
    () async {
      final requests = <Map<String, Object?>>[];
      final bootstrap = CoreBootstrap(
        callCore: (encoded) async {
          final request = jsonDecode(encoded) as Map<String, Object?>;
          requests.add(request);
          final method = request['method'];
          final params = request['params'] as Map<String, Object?>;
          final action = params['action'];
          if (method == 'open') {
            return _response({
              'graphs': [
                {'id': 'graph-a', 'name': 'Work', 'isEncrypted': false},
              ],
            });
          }
          if (action == 'openGraph') {
            return _response({
              'selectedGraphId': 'graph-a',
              'outlinerRows': [],
            });
          }
          return _response({});
        },
      );

      final result = await bootstrap.restore(
        const CoreStartupState(
          databasePath: '/data/logseq-chat.sqlite',
          graphsDirectory: '/data/graphs',
          baseUrl: 'https://api.logseq.test',
          selectedGraphId: 'graph-a',
          localGraphIds: ['graph-a'],
          accessToken: 'token',
        ),
      );

      expect(requests.map((request) => request['method']), [
        'open',
        'dispatch',
        'dispatch',
      ]);
      expect(
        (requests[1]['params'] as Map<String, Object?>)['action'],
        'configure',
      );
      final openGraphParams = requests[2]['params'] as Map<String, Object?>;
      expect(openGraphParams['action'], 'openGraph');
      expect(
        jsonDecode(openGraphParams['payload']! as String),
        containsPair('activePath', '/data/graphs/graph-a/graph.sqlite'),
      );
      expect(result.graphResponse, isNotNull);
      expect(result.localGraphIds, ['graph-a']);
    },
  );

  test(
    'shows the catalog without blocking on a missing selected graph',
    () async {
      final actions = <Object?>[];
      final bootstrap = CoreBootstrap(
        callCore: (encoded) async {
          final request = jsonDecode(encoded) as Map<String, Object?>;
          actions.add((request['params'] as Map<String, Object?>)['action']);
          return _response({'graphs': []});
        },
      );

      final result = await bootstrap.restore(
        const CoreStartupState(
          databasePath: '/data/logseq-chat.sqlite',
          graphsDirectory: '/data/graphs',
          baseUrl: 'http://127.0.0.1:8787',
          selectedGraphId: '',
          localGraphIds: [],
          accessToken: '',
        ),
      );

      expect(actions, [null, 'configure']);
      expect(result.graphResponse, isNull);
    },
  );

  test('does not open an encrypted graph until it is unlocked', () async {
    final actions = <Object?>[];
    final bootstrap = CoreBootstrap(
      callCore: (encoded) async {
        final request = jsonDecode(encoded) as Map<String, Object?>;
        final action = (request['params'] as Map<String, Object?>)['action'];
        actions.add(action);
        return action == null
            ? _response({
                'graphs': [
                  {'id': 'private', 'name': 'Private', 'isEncrypted': true},
                ],
              })
            : _response({});
      },
    );

    final result = await bootstrap.restore(
      const CoreStartupState(
        databasePath: '/data/logseq-chat.sqlite',
        graphsDirectory: '/data/graphs',
        baseUrl: 'https://api.logseq.test',
        selectedGraphId: 'private',
        localGraphIds: ['private'],
        accessToken: 'token',
      ),
    );

    expect(actions, [null, 'configure']);
    expect(result.graphResponse, isNull);
  });

  test('traces every startup core boundary with its elapsed time', () async {
    final traces = <String>[];
    final bootstrap = CoreBootstrap(
      trace: traces.add,
      callCore: (encoded) async {
        final request = jsonDecode(encoded) as Map<String, Object?>;
        final action = (request['params'] as Map<String, Object?>)['action'];
        return action == null
            ? _response({
                'graphs': [
                  {'id': 'graph-a', 'name': 'Work', 'isEncrypted': false},
                ],
              })
            : _response({});
      },
    );

    await bootstrap.restore(
      const CoreStartupState(
        databasePath: '/data/logseq-chat.sqlite',
        graphsDirectory: '/data/graphs',
        baseUrl: 'https://api.logseq.test',
        selectedGraphId: 'graph-a',
        localGraphIds: ['graph-a'],
        accessToken: 'token',
      ),
    );

    expect(traces.where((trace) => trace.endsWith('started')), [
      'open catalog started',
      'configure graph started',
      'open local graph started',
    ]);
    expect(
      traces.where((trace) => trace.contains('completed durationMs=')),
      hasLength(3),
    );
  });
}

String _response(Map<String, Object?> result) =>
    jsonEncode({'apiVersion': 1, 'ok': true, 'result': result});
