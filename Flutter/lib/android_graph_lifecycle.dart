import 'dart:convert';

import 'android_platform_effects.dart';
import 'core_effect_executor.dart';
import 'native_effect_drain.dart';

typedef AccessTokenProvider = Future<String?> Function();
typedef AndroidGraphLifecycleTrace = void Function(String message);

void _ignoreGraphLifecycleTrace(String message) {}

final class AndroidGraphLifecycle {
  AndroidGraphLifecycle({
    required this.callCore,
    required this.platform,
    AccessTokenProvider? accessTokenProvider,
    this.trace = _ignoreGraphLifecycleTrace,
  }) : accessTokenProvider = accessTokenProvider ?? (() async => '');

  final NativeCoreCall callCore;
  final AndroidPlatformServices platform;
  final AccessTokenProvider accessTokenProvider;
  final AndroidGraphLifecycleTrace trace;

  Future<NativeEffectResolution> execute(NativeEffect effect) async {
    try {
      switch (effect.kind) {
        case 'create-graph':
          final created = await _call(
            'createSyncGraph',
            payload: jsonEncode({
              'name': effect.text,
              'isEncrypted': effect.value == 1,
            }),
          );
          final failure = _failure(created);
          if (failure != null) return failure;
          final graphId = _selectedGraphId(created);
          if (graphId.isEmpty) {
            return const NativeEffectResolution.discard(
              succeeded: false,
              message: 'The created graph has no selected identifier',
            );
          }
          return await _openGraph(graphId);
        case 'open-graph':
          return await _openGraph(effect.text);
        case 'unlock-graph':
          return _resolution(await _call('unlockGraph', payload: effect.text));
        default:
          return NativeEffectResolution.discard(
            succeeded: false,
            message: 'Unsupported Android graph effect: ${effect.kind}',
          );
      }
    } catch (error) {
      final message = '${_failureCode(effect.kind)}\n$error';
      trace(
        'effect.failed kind=${effect.kind} message=${message.replaceAll('\n', r'\n')}',
      );
      return NativeEffectResolution.discard(succeeded: false, message: message);
    }
  }

  String _failureCode(String kind) => switch (kind) {
    'create-graph' => 'graph_create_failed',
    'open-graph' => 'graph_open_failed',
    'unlock-graph' => 'graph_unlock_failed',
    _ => 'graph_operation_failed',
  };

  Future<NativeEffectResolution> _openGraph(String graphId) async {
    trace('open.start graphId=$graphId');
    final selected = await _call('selectGraph', payload: graphId);
    final selectionFailure = _failure(selected);
    if (selectionFailure != null) return selectionFailure;
    trace('select.complete graphId=$graphId');

    final state = await platform.loadStorageState();
    final directory = '${state.graphsDirectory}/$graphId';
    final isEncrypted = _graphIsEncrypted(selected, graphId);
    final isLocal = state.localGraphIds.contains(graphId);
    trace('storage.loaded graphId=$graphId local=$isLocal');
    late final String opened;
    if (isLocal) {
      opened = await _call(
        'openGraph',
        payload: jsonEncode({
          'graphId': graphId,
          'activePath': '$directory/graph.sqlite',
          'checkpointPath': '$directory/sync.checkpoint',
          'isEncrypted': isEncrypted,
        }),
      );
    } else {
      final token = await accessTokenProvider() ?? '';
      trace(
        'snapshot.download.start graphId=$graphId baseUrl=${state.baseUrl}',
      );
      final artifact = await platform.downloadGraphSnapshot(
        baseUrl: state.baseUrl,
        graphId: graphId,
        accessToken: token,
        workingDirectory: directory,
      );
      trace(
        'snapshot.download.complete graphId=$graphId path=${artifact.filePath}',
      );
      try {
        trace('snapshot.import.start graphId=$graphId');
        opened = await _call(
          'importSnapshot',
          payload: jsonEncode({
            'graphId': graphId,
            'activePath': '$directory/graph.sqlite',
            'checkpointPath': '$directory/sync.checkpoint',
            'metadataBody': artifact.metadataBody,
            'downloadPath': artifact.filePath,
            'isEncrypted': isEncrypted,
          }),
        );
        trace('snapshot.import.complete graphId=$graphId');
      } finally {
        await platform.deleteTemporaryFile(artifact.filePath);
      }
    }

    final openFailure = _failure(opened);
    if (openFailure != null) return openFailure;
    await platform.persistSelectedGraphId(graphId);
    trace('selection.persist.complete graphId=$graphId');
    trace('open.complete graphId=$graphId');
    return NativeEffectResolution.coreResponse(opened);
  }

  Future<String> _call(String action, {String? payload}) {
    final params = <String, Object?>{'action': action};
    if (payload != null) params['payload'] = payload;
    return callCore(
      jsonEncode({'apiVersion': 1, 'method': 'dispatch', 'params': params}),
    );
  }

  NativeEffectResolution _resolution(String response) =>
      _failure(response) ?? NativeEffectResolution.coreResponse(response);

  NativeEffectResolution? _failure(String response) {
    final decoded = _decodedResponse(response);
    if (decoded['ok'] == true) return null;
    final error = decoded['error'];
    final code = error is Map<String, Object?> && error['code'] is String
        ? error['code']! as String
        : 'core_error';
    final message = error is Map<String, Object?> && error['message'] is String
        ? error['message']! as String
        : 'The OCaml core rejected the graph operation';
    return NativeEffectResolution.discard(
      succeeded: false,
      message: '$code\n$message',
    );
  }

  String _selectedGraphId(String response) {
    final result = _decodedResponse(response)['result'];
    if (result is! Map<String, Object?>) return '';
    return result['selectedGraphId'] is String
        ? result['selectedGraphId']! as String
        : '';
  }

  bool _graphIsEncrypted(String response, String graphId) {
    final result = _decodedResponse(response)['result'];
    if (result is! Map<String, Object?>) return false;
    final graphs = result['graphs'];
    if (graphs is! List<Object?>) return false;
    for (final graph in graphs) {
      if (graph is Map<String, Object?> && graph['id'] == graphId) {
        return graph['isEncrypted'] == true;
      }
    }
    return false;
  }

  Map<String, Object?> _decodedResponse(String response) {
    final decoded = jsonDecode(response);
    if (decoded is! Map<String, Object?>) {
      throw const FormatException('The native core response must be an object');
    }
    return decoded;
  }
}
