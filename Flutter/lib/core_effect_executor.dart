import 'dart:convert';

import 'native_effect_drain.dart';

typedef NativeCoreCall = Future<String> Function(String request);
typedef MillisecondsClock = int Function();
typedef UuidFactory = String Function();
typedef NativeGraphExecutor = Future<NativeEffectResolution> Function(
  NativeEffect effect,
);

final class CoreEffectExecutor {
  CoreEffectExecutor({
    required this.callCore,
    required this.executePlatformEffect,
    required this.executeGraphEffect,
    MillisecondsClock? nowMilliseconds,
    UuidFactory? newUuid,
  }) : nowMilliseconds =
           nowMilliseconds ?? (() => DateTime.now().millisecondsSinceEpoch),
       newUuid = newUuid ?? newCoreUuid;

  final NativeCoreCall callCore;
  final NativeEffectExecutor executePlatformEffect;
  final NativeGraphExecutor executeGraphEffect;
  final MillisecondsClock nowMilliseconds;
  final UuidFactory newUuid;

  static const _platformEffectKinds = {
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
  };

  static const _graphEffectKinds = {
    'open-graph',
    'unlock-graph',
    'create-graph',
  };

  Future<NativeEffectResolution> execute(NativeEffect effect) async {
    if (_platformEffectKinds.contains(effect.kind)) {
      return executePlatformEffect(effect);
    }
    if (_graphEffectKinds.contains(effect.kind)) {
      return executeGraphEffect(effect);
    }

    try {
      final request = _request(effect);
      if (request == null) {
        return NativeEffectResolution.discard(
          succeeded: false,
          message: 'Unsupported LG effect: ${effect.kind}',
        );
      }
      final response = await callCore(jsonEncode(request));
      return _resolution(response);
    } catch (error) {
      return NativeEffectResolution.discard(
        succeeded: false,
        message: error.toString(),
      );
    }
  }

  Map<String, Object?>? _request(NativeEffect effect) {
    String action;
    String? payload;
    switch (effect.kind) {
      case 'send-capture':
        action = 'send';
        payload = _payload({
          'text': effect.text,
          'uuid': newUuid(),
          'now': nowMilliseconds(),
        });
      case 'send-task':
        action = 'sendTask';
        payload = _payload({
          'text': effect.text,
          'uuid': newUuid(),
          'now': nowMilliseconds(),
          'status': _metadataObject(effect, 'task status'),
        });
      case 'search-nodes':
        action = 'searchNodes';
        payload = effect.text;
      case 'open-node':
        action = 'openNode';
        payload = _payload({'uuid': effect.text});
      case 'close-node':
        action = 'closeNode';
      case 'select-sidebar-page':
        action = 'selectPage';
        payload = effect.text;
      case 'clear-selected-page':
        action = 'clearSelectedPage';
      case 'load-older-journals':
        action = 'loadOlderJournals';
      case 'set-page-favorite':
        action = 'setPageFavorite';
        payload = _payload({
          'pageUuid': effect.text,
          'favorite': effect.value == 1,
          'operationId': newUuid(),
          'now': nowMilliseconds(),
        });
      case 'delete-page':
        action = 'deletePage';
        payload = _payload({
          'pageUuid': effect.text,
          'operationId': newUuid(),
          'now': nowMilliseconds(),
        });
      case 'load-flashcards':
        action = 'loadFlashcards';
        payload = nowMilliseconds().toString();
      case 'review-flashcard':
        action = 'reviewFlashcard';
        payload = _payload({
          'uuid': _requiredUuid(effect),
          'rating': effect.text,
          'now': nowMilliseconds(),
          'operationId': newUuid(),
        });
      case 'refresh-graphs':
        action = 'refresh';
      case 'tap-outliner-block':
        return _outlinerRequest({'type': 'tapBlock', 'uuid': effect.text});
      case 'toggle-outliner-collapsed':
        return _outlinerRequest({
          'type': 'toggleCollapsed',
          'uuid': effect.text,
        });
      case 'long-press-outliner-block':
        return _outlinerRequest({
          'type': 'longPressBlock',
          'uuid': effect.text,
        });
      case 'add-root-block':
        return _outlinerRequest({'type': 'addRootBlock', 'uuid': effect.text});
      case 'drop-outliner-blocks':
        final placement = effect.metadata;
        if (placement == null) {
          throw const FormatException(
            'The outliner drop effect is missing its placement',
          );
        }
        return _outlinerRequest({
          'type': 'dropBlocks',
          'targetUuid': effect.text,
          'placement': placement,
        });
      case 'set-outliner-task-status':
        final status = _metadataObject(effect, 'task status');
        return _outlinerRequest({
          'type': 'setTaskStatus',
          'uuid': effect.text,
          'statusIdent': status['ident'],
          'statusUuid': status['uuid'],
        });
      case 'outliner-toolbar':
        return _outlinerRequest({'type': 'toolbar', 'action': effect.text});
      case 'choose-outliner-autocomplete':
        return _outlinerRequest({
          'type': 'chooseAutocomplete',
          'value': effect.text,
        });
      case 'save-outliner-editing':
        return _outlinerRequest({'type': 'saveEditing'});
      case 'cancel-outliner-editing':
        return _outlinerRequest({'type': 'cancelEditing'});
      case 'change-outliner-text':
        return _outlinerRequest({
          'type': 'textChanged',
          'uuid': _requiredUuid(effect),
          'title': effect.text,
          'caretUTF16Offset': _requiredValue(effect),
        });
      case 'return-outliner-editor':
        return _outlinerRequest({
          'type': 'returnPressed',
          'uuid': _requiredUuid(effect),
          'title': effect.text,
          'caretUTF16Offset': _requiredValue(effect),
        });
      case 'backspace-outliner-editor':
        return _outlinerRequest({
          'type': 'backspacePressed',
          'uuid': _requiredUuid(effect),
          'title': effect.text,
          'selectionLength': _requiredValue(effect),
        });
      case 'move-outliner-caret':
        return _outlinerRequest({
          'type': 'caretMoved',
          'uuid': _requiredUuid(effect),
          'caretUTF16Offset': _requiredValue(effect),
        });
      default:
        return null;
    }
    return _rpcRequest(action: action, payload: payload);
  }

  Map<String, Object?> _outlinerRequest(Map<String, Object?> event) =>
      _rpcRequest(action: 'outlinerEvent', payload: _payload(event));

  Map<String, Object?> _rpcRequest({required String action, String? payload}) {
    final params = <String, Object?>{'action': action};
    if (payload != null) params['payload'] = payload;
    return {'apiVersion': 1, 'method': 'dispatch', 'params': params};
  }

  Map<String, Object?> _metadataObject(NativeEffect effect, String label) {
    final metadata = effect.metadata;
    if (metadata == null) {
      throw FormatException('The ${effect.kind} effect is missing its $label');
    }
    final decoded = jsonDecode(metadata);
    if (decoded is! Map<String, Object?>) {
      throw FormatException('The ${effect.kind} $label must be an object');
    }
    return decoded;
  }

  String _requiredUuid(NativeEffect effect) {
    final uuid = effect.uuid;
    if (uuid == null) {
      throw FormatException('The ${effect.kind} effect is missing its UUID');
    }
    return uuid;
  }

  int _requiredValue(NativeEffect effect) {
    final value = effect.value;
    if (value == null) {
      throw FormatException(
        'The ${effect.kind} effect is missing its integer value',
      );
    }
    return value;
  }

  NativeEffectResolution _resolution(String response) {
    final decoded = jsonDecode(response);
    if (decoded is! Map<String, Object?>) {
      throw const FormatException('The native core response must be an object');
    }
    if (decoded['ok'] == true) {
      return NativeEffectResolution.coreResponse(response);
    }
    final error = decoded['error'];
    final code = error is Map<String, Object?> && error['code'] is String
        ? error['code']! as String
        : 'core_error';
    final message = error is Map<String, Object?> && error['message'] is String
        ? error['message']! as String
        : 'The OCaml core rejected the effect';
    return NativeEffectResolution.discard(
      succeeded: false,
      message: '$code\n$message',
    );
  }
}

String _payload(Map<String, Object?> value) => jsonEncode(value);

String newCoreUuid() {
  final timestamp = DateTime.now().microsecondsSinceEpoch.toRadixString(16);
  return '$timestamp-${timestamp.padLeft(32, '0').substring(0, 32)}';
}
