import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:logseq_chat_flutter/graph_catalog_auto_refresh.dart';

void main() {
  test(
    'refreshes the graph catalog and applies the authoritative response',
    () async {
      final requests = <Map<String, Object?>>[];
      final applied = <String>[];
      final refresher = GraphCatalogAutoRefresh(
        callCore: (encoded) async {
          requests.add(jsonDecode(encoded) as Map<String, Object?>);
          return _response({'graphs': const []});
        },
        applyCoreResponse: (response) async => applied.add(response),
      );

      final refreshed = await refresher.refresh();

      expect(refreshed, isTrue);
      expect(requests, hasLength(1));
      expect(requests.single['method'], 'dispatch');
      expect(
        (requests.single['params'] as Map<String, Object?>)['action'],
        'refreshGraphCatalog',
      );
      expect(applied, hasLength(1));
    },
  );

  test('coalesces overlapping automatic refresh requests', () async {
    final response = Completer<String>();
    var requestCount = 0;
    var applyCount = 0;
    final refresher = GraphCatalogAutoRefresh(
      callCore: (_) {
        requestCount += 1;
        return response.future;
      },
      applyCoreResponse: (_) async => applyCount += 1,
    );

    final first = refresher.refresh();
    final second = refresher.refresh();
    response.complete(_response({'graphs': const []}));

    expect(await first, isTrue);
    expect(await second, isTrue);
    expect(requestCount, 1);
    expect(applyCount, 1);
  });

  test('skips applying an unchanged catalog after bootstrap', () async {
    final initial = _response({
      'graphs': [
        {'id': 'graph-a', 'name': 'Graph A'},
      ],
    });
    var applyCount = 0;
    final refresher = GraphCatalogAutoRefresh(
      callCore: (_) async => initial,
      applyCoreResponse: (_) async => applyCount += 1,
    );
    refresher.rememberCatalog(initial);

    expect(await refresher.refresh(), isTrue);
    expect(applyCount, 0);
  });

  test('applies a catalog when its graph collection changes', () async {
    final initial = _response({
      'graphs': [
        {'id': 'graph-a', 'name': 'Graph A'},
      ],
    });
    final changed = _response({
      'graphs': [
        {'id': 'graph-a', 'name': 'Graph A'},
        {'id': 'graph-b', 'name': 'Graph B'},
      ],
    });
    var applyCount = 0;
    final refresher = GraphCatalogAutoRefresh(
      callCore: (_) async => changed,
      applyCoreResponse: (_) async => applyCount += 1,
    );
    refresher.rememberCatalog(initial);

    expect(await refresher.refresh(), isTrue);
    expect(applyCount, 1);
  });

  test('does not apply a rejected graph catalog response', () async {
    var applyCount = 0;
    final traces = <String>[];
    final refresher = GraphCatalogAutoRefresh(
      callCore: (_) async => jsonEncode({
        'apiVersion': 1,
        'ok': false,
        'error': {'code': 'offline', 'message': 'Server unavailable'},
      }),
      applyCoreResponse: (_) async => applyCount += 1,
      trace: traces.add,
    );

    expect(await refresher.refresh(), isFalse);
    expect(applyCount, 0);
    expect(
      traces,
      contains(
        'refresh.rejected code=offline message=Server unavailable',
      ),
    );
  });

  test('periodically refreshes the graph catalog while started', () async {
    Duration? scheduledInterval;
    void Function()? scheduledTick;
    final applied = Completer<void>();
    final refresher = GraphCatalogAutoRefresh(
      callCore: (_) async => _response({'graphs': const []}),
      applyCoreResponse: (_) async => applied.complete(),
      schedulePeriodic: (interval, tick) {
        scheduledInterval = interval;
        scheduledTick = tick;
        return _TestTimer();
      },
    );

    refresher.startPeriodic(interval: const Duration(seconds: 15));
    scheduledTick!();
    await applied.future;

    expect(scheduledInterval, const Duration(seconds: 15));
  });

  test('starts only one periodic refresh loop and cancels it when stopped', () {
    final timers = <_TestTimer>[];
    final refresher = GraphCatalogAutoRefresh(
      callCore: (_) async => _response({'graphs': const []}),
      applyCoreResponse: (_) async {},
      schedulePeriodic: (_, _) {
        final timer = _TestTimer();
        timers.add(timer);
        return timer;
      },
    );

    refresher.startPeriodic();
    refresher.startPeriodic();
    refresher.stopPeriodic();

    expect(timers, hasLength(1));
    expect(timers.single.isActive, isFalse);
  });
}

final class _TestTimer implements Timer {
  var _isActive = true;

  @override
  bool get isActive => _isActive;

  @override
  int get tick => 0;

  @override
  void cancel() => _isActive = false;
}

String _response(Map<String, Object?> result) =>
    jsonEncode({'apiVersion': 1, 'ok': true, 'result': result});
