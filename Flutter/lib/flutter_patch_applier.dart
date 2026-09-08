import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:lui_flutter_backend/lui_flutter_backend.dart';

final class FlutterPatchApplier extends ChangeNotifier {
  FlutterPatchApplier(this._backend);

  final LUIFlutterBackend _backend;
  Map<int, String> _nodeKinds = {};
  Set<String> _ignoredProperties = {};

  void applyJson(String patch) {
    final document = jsonDecode(patch) as Map<String, dynamic>;
    final operations = document['ops'] as List<dynamic>;
    final nextNodeKinds = Map<int, String>.of(_nodeKinds);
    final nextIgnoredProperties = Set<String>.of(_ignoredProperties);
    final compatibleOperations = <dynamic>[];
    var structureChanged = false;

    for (final value in operations) {
      final operation = value as Map<String, dynamic>;
      final name = operation['op'];
      if (name == 'insert-child' ||
          name == 'remove-child' ||
          name == 'move-child') {
        structureChanged = true;
      }
      final id = operation['id'];
      if (name == 'create-node' && id is int) {
        nextNodeKinds[id] = operation['kind'] as String;
      } else if (name == 'drop-node' && id is int) {
        nextNodeKinds.remove(id);
        nextIgnoredProperties.removeWhere(
          (property) => property.startsWith('$id:'),
        );
      } else if (name == 'set-prop' && id is int) {
        final property = operation['property'] as String;
        final key = _propertyKey(id, property);
        if (_isUnsupportedPresentationHint(
          kind: nextNodeKinds[id],
          property: property,
          value: operation['value'],
        )) {
          nextIgnoredProperties.add(key);
          continue;
        }
        nextIgnoredProperties.remove(key);
        if (property == 'size' &&
            operation['value'] == 'icon' &&
            const {'button', 'toggle-button'}.contains(nextNodeKinds[id])) {
          // Icon controls center their glyph inside the full touch target.
          // The Flutter backend otherwise inherits leading text alignment.
          compatibleOperations.add(operation);
          compatibleOperations.add({
            'op': 'set-prop',
            'id': id,
            'property': 'text-alignment',
            'value': 'center',
          });
          continue;
        }
      } else if (name == 'remove-prop' && id is int) {
        final property = operation['property'] as String;
        final key = _propertyKey(id, property);
        if (nextIgnoredProperties.remove(key)) continue;
      }
      compatibleOperations.add(operation);
    }

    _backend.applyJson(jsonEncode({...document, 'ops': compatibleOperations}));
    _nodeKinds = nextNodeKinds;
    _ignoredProperties = nextIgnoredProperties;
    if (structureChanged) {
      notifyListeners();
    }
  }

  static bool _isUnsupportedPresentationHint({
    required String? kind,
    required String property,
    required Object? value,
  }) => switch (property) {
    'container-relative-frame' || 'container-relative-frame-inset' => true,
    'selected' => kind == 'virtual-list',
    'padding-horizontal' || 'padding-vertical' => !const {
      'row',
      'column',
      'grid',
      'box',
    }.contains(kind),
    'style-class' => kind == 'dialog' || kind == 'sheet',
    'icon-placement' =>
      (kind != 'button' && kind != 'toggle-button') ||
          (value != 'leading' && value != 'trailing'),
    'role' =>
      value != 'treeitem' ||
          !const {
            'row',
            'column',
            'panel',
            'card',
            'box',
            'list-item',
          }.contains(kind),
    _ => false,
  };

  static String _propertyKey(int id, String property) => '$id:$property';
}
