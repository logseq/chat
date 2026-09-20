import 'dart:async';
import 'dart:convert';

import 'core_effect_executor.dart';

typedef ApplyCoreResponse = Future<void> Function(String response);
typedef GraphCatalogRefreshTrace = void Function(String message);
typedef GraphCatalogPeriodicScheduler = Timer Function(
  Duration interval,
  void Function() tick,
);

void _ignoreGraphCatalogRefreshTrace(String message) {}

Timer _scheduleGraphCatalogRefresh(Duration interval, void Function() tick) =>
    Timer.periodic(interval, (_) => tick());

final class GraphCatalogAutoRefresh {
  GraphCatalogAutoRefresh({
    required this.callCore,
    required this.applyCoreResponse,
    this.trace = _ignoreGraphCatalogRefreshTrace,
    this.schedulePeriodic = _scheduleGraphCatalogRefresh,
  });

  final NativeCoreCall callCore;
  final ApplyCoreResponse applyCoreResponse;
  final GraphCatalogRefreshTrace trace;
  final GraphCatalogPeriodicScheduler schedulePeriodic;
  Future<bool>? _activeRefresh;
  Timer? _periodicTimer;
  String? _catalogFingerprint;

  void rememberCatalog(String response) {
    _catalogFingerprint = _fingerprint(response);
  }

  void startPeriodic({Duration interval = const Duration(seconds: 15)}) {
    if (_periodicTimer != null) return;
    trace('periodic.start intervalMs=${interval.inMilliseconds}');
    _periodicTimer = schedulePeriodic(interval, _periodicTick);
  }

  void stopPeriodic() {
    final timer = _periodicTimer;
    if (timer == null) return;
    timer.cancel();
    _periodicTimer = null;
    trace('periodic.stop');
  }

  void _periodicTick() {
    unawaited(
      refresh().onError((error, stackTrace) {
        trace('periodic.failed error=$error');
        return false;
      }),
    );
  }

  Future<bool> refresh() {
    final active = _activeRefresh;
    if (active != null) return active;
    late final Future<bool> operation;
    operation = _run().whenComplete(() {
      if (identical(_activeRefresh, operation)) _activeRefresh = null;
    });
    _activeRefresh = operation;
    return operation;
  }

  Future<bool> _run() async {
    trace('refresh.start');
    final response = await callCore(
      jsonEncode({
        'apiVersion': 1,
        'method': 'dispatch',
        'params': {'action': 'refreshGraphCatalog'},
      }),
    );
    final decoded = jsonDecode(response);
    if (decoded is! Map<String, Object?> || decoded['ok'] != true) {
      final error = decoded is Map<String, Object?> ? decoded['error'] : null;
      final code = error is Map<String, Object?> ? error['code'] : null;
      final message = error is Map<String, Object?> ? error['message'] : null;
      trace(
        'refresh.rejected code=${code ?? 'unknown'} '
        'message=${message ?? 'Unknown core response'}',
      );
      return false;
    }
    final fingerprint = _fingerprintFromEnvelope(decoded);
    if (fingerprint != null && fingerprint == _catalogFingerprint) {
      trace('refresh.unchanged');
      return true;
    }
    await applyCoreResponse(response);
    _catalogFingerprint = fingerprint;
    trace('refresh.complete');
    return true;
  }

  String? _fingerprint(String response) {
    try {
      final decoded = jsonDecode(response);
      return decoded is Map<String, Object?>
          ? _fingerprintFromEnvelope(decoded)
          : null;
    } on FormatException {
      return null;
    }
  }

  String? _fingerprintFromEnvelope(Map<String, Object?> envelope) {
    final result = envelope['result'];
    if (result is! Map<String, Object?>) return null;
    final graphs = result['graphs'];
    return graphs is List<Object?> ? jsonEncode(graphs) : null;
  }
}
