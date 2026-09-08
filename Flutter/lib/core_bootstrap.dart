import 'dart:convert';

import 'core_effect_executor.dart';

typedef CoreBootstrapTrace = void Function(String message);

final class CoreStartupState {
  const CoreStartupState({
    required this.databasePath,
    required this.graphsDirectory,
    required this.baseUrl,
    required this.selectedGraphId,
    required this.localGraphIds,
    required this.accessToken,
  });

  final String databasePath;
  final String graphsDirectory;
  final String baseUrl;
  final String selectedGraphId;
  final List<String> localGraphIds;
  final String accessToken;
}

final class CoreBootstrapResult {
  const CoreBootstrapResult({
    required this.catalogResponse,
    required this.graphResponse,
    required this.localGraphIds,
  });

  final String catalogResponse;
  final String? graphResponse;
  final List<String> localGraphIds;
}

final class CoreBootstrap {
  const CoreBootstrap({required this.callCore, this.trace});

  final NativeCoreCall callCore;
  final CoreBootstrapTrace? trace;

  Future<CoreBootstrapResult> restore(CoreStartupState state) async {
    final catalogResponse = await _call(
      operation: 'open catalog',
      request: _request(method: 'open', path: state.databasePath),
    );
    final catalog = _successfulResult(
      catalogResponse,
      operation: 'open catalog',
    );
    final configureResponse = await _call(
      operation: 'configure graph',
      request: _request(
        method: 'dispatch',
        action: 'configure',
        payload: jsonEncode({
          'baseUrl': state.baseUrl,
          'graphId': state.selectedGraphId,
          'token': state.accessToken,
        }),
      ),
    );
    _successfulResult(configureResponse, operation: 'configure graph');

    String? graphResponse;
    if (state.selectedGraphId.isNotEmpty &&
        state.localGraphIds.contains(state.selectedGraphId) &&
        !_graphIsEncrypted(catalog, state.selectedGraphId)) {
      final directory = '${state.graphsDirectory}/${state.selectedGraphId}';
      graphResponse = await _call(
        operation: 'open local graph',
        request: _request(
          method: 'dispatch',
          action: 'openGraph',
          payload: jsonEncode({
            'graphId': state.selectedGraphId,
            'activePath': '$directory/graph.sqlite',
            'checkpointPath': '$directory/sync.checkpoint',
            'isEncrypted': false,
          }),
        ),
      );
      _successfulResult(graphResponse, operation: 'open local graph');
    }

    return CoreBootstrapResult(
      catalogResponse: catalogResponse,
      graphResponse: graphResponse,
      localGraphIds: state.localGraphIds,
    );
  }

  Future<String> _call({
    required String operation,
    required String request,
  }) async {
    trace?.call('$operation started');
    final stopwatch = Stopwatch()..start();
    try {
      return await callCore(request);
    } finally {
      trace?.call(
        '$operation completed durationMs=${stopwatch.elapsedMilliseconds}',
      );
    }
  }

  bool _graphIsEncrypted(Map<String, Object?> catalog, String graphId) {
    final graphs = catalog['graphs'];
    if (graphs is! List<Object?>) return false;
    for (final graph in graphs) {
      if (graph is Map<String, Object?> && graph['id'] == graphId) {
        return graph['isEncrypted'] == true;
      }
    }
    return false;
  }

  Map<String, Object?> _successfulResult(
    String encoded, {
    required String operation,
  }) {
    final response = jsonDecode(encoded);
    if (response is! Map<String, Object?>) {
      throw FormatException(
        'Could not $operation: core response is not an object',
      );
    }
    if (response['ok'] != true) {
      final error = response['error'];
      final message = error is Map<String, Object?>
          ? error['message'] as String?
          : null;
      throw StateError(
        'Could not $operation: ${message ?? 'unknown core error'}',
      );
    }
    final result = response['result'];
    return result is Map<String, Object?> ? result : const {};
  }

  String _request({
    required String method,
    String? action,
    String? payload,
    String? path,
  }) {
    final params = <String, Object?>{};
    if (action != null) params['action'] = action;
    if (payload != null) params['payload'] = payload;
    if (path != null) params['path'] = path;
    return jsonEncode({'apiVersion': 1, 'method': method, 'params': params});
  }
}
