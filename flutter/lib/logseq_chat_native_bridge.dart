import 'dart:ffi';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';

import 'lui_dispatch.dart';
import 'native_effect_drain.dart';
import 'native_runtime_scheduler.dart';

typedef _NativeInitialize = Pointer<Utf8> Function(Int32, Int32, Int32);
typedef _DartInitialize = Pointer<Utf8> Function(int, int, int);
typedef _NativeNodeEvent = Pointer<Utf8> Function(Int64);
typedef _DartNodeEvent = Pointer<Utf8> Function(int);
typedef _NativeTextEvent = Pointer<Utf8> Function(Int64, Pointer<Utf8>);
typedef _DartTextEvent = Pointer<Utf8> Function(int, Pointer<Utf8>);
typedef _NativeToggleEvent = Pointer<Utf8> Function(Int64, Int32);
typedef _DartToggleEvent = Pointer<Utf8> Function(int, int);
typedef _NativeValueEvent = Pointer<Utf8> Function(Int64, Double);
typedef _DartValueEvent = Pointer<Utf8> Function(int, double);
typedef _NativeExtensionEvent = Pointer<Utf8> Function(
  Int64,
  Pointer<Utf8>,
  Pointer<Utf8>,
  Pointer<Utf8>,
  Int64,
);
typedef _DartExtensionEvent = Pointer<Utf8> Function(
  int,
  Pointer<Utf8>,
  Pointer<Utf8>,
  Pointer<Utf8>,
  int,
);
typedef _NativeRootNode = Int64 Function();
typedef _DartRootNode = int Function();
typedef _NativeNoArgument = Pointer<Utf8> Function();
typedef _DartNoArgument = Pointer<Utf8> Function();
typedef _NativeResolveEffect = Pointer<Utf8> Function(
  Int64,
  Int32,
  Pointer<Utf8>,
);
typedef _DartResolveEffect = Pointer<Utf8> Function(int, int, Pointer<Utf8>);
typedef _NativeStringArgument = Pointer<Utf8> Function(Pointer<Utf8>);
typedef _DartStringArgument = Pointer<Utf8> Function(Pointer<Utf8>);
typedef _NativeTwoStringArguments = Pointer<Utf8> Function(
  Pointer<Utf8>,
  Pointer<Utf8>,
);
typedef _DartTwoStringArguments = Pointer<Utf8> Function(
  Pointer<Utf8>,
  Pointer<Utf8>,
);
typedef _NativeCoreCall = Pointer<Utf8> Function(Pointer<Utf8>);
typedef _DartCoreCall = Pointer<Utf8> Function(Pointer<Utf8>);

final class LogseqChatNativeBridge
    implements LogseqChatNativeDispatch, NativeEffectRuntime {
  LogseqChatNativeBridge({required this.onPatch, DynamicLibrary? library})
    : _library = library ?? DynamicLibrary.open('liblogseq_chat_core.so'),
      _runtimeScheduler = NativeRuntimeScheduler() {
    _initialize = _library.lookupFunction<_NativeInitialize, _DartInitialize>(
      'logseq_chat_lui_initialize',
    );
    _rootNode = _library.lookupFunction<_NativeRootNode, _DartRootNode>(
      'logseq_chat_lui_root_node',
    );
    _appear = _nodeEvent('logseq_chat_lui_appear');
    _press = _nodeEvent('logseq_chat_lui_press');
    _longPress = _nodeEvent('logseq_chat_lui_long_press');
    _textChanged = _library.lookupFunction<_NativeTextEvent, _DartTextEvent>(
      'logseq_chat_lui_text_changed',
    );
    _submit = _nodeEvent('logseq_chat_lui_submit');
    _toggleChanged = _library
        .lookupFunction<_NativeToggleEvent, _DartToggleEvent>(
          'logseq_chat_lui_toggle_changed',
        );
    _change = _nodeEvent('logseq_chat_lui_change');
    _valueChanged = _library.lookupFunction<_NativeValueEvent, _DartValueEvent>(
      'logseq_chat_lui_value_changed',
    );
    _dismiss = _nodeEvent('logseq_chat_lui_dismiss');
    _doublePress = _nodeEvent('logseq_chat_lui_double_press');
    _extensionEvent = _library
        .lookupFunction<_NativeExtensionEvent, _DartExtensionEvent>(
          'logseq_chat_lui_extension_event',
        );
    _dispose = _library.lookupFunction<_NativeNoArgument, _DartNoArgument>(
      'logseq_chat_lui_dispose',
    );
    _takeEffect = _library.lookupFunction<_NativeNoArgument, _DartNoArgument>(
      'logseq_chat_lui_take_effect',
    );
    _resolveEffect = _library
        .lookupFunction<_NativeResolveEffect, _DartResolveEffect>(
          'logseq_chat_lui_resolve_effect',
        );
    _applySnapshot = _library
        .lookupFunction<_NativeStringArgument, _DartStringArgument>(
          'logseq_chat_lui_apply_snapshot',
        );
    _applyHostUpdate = _library
        .lookupFunction<_NativeTwoStringArguments, _DartTwoStringArguments>(
          'logseq_chat_lui_apply_host_update',
        );
  }

  final void Function(String json) onPatch;
  final DynamicLibrary _library;
  final NativeRuntimeScheduler _runtimeScheduler;
  late final _DartInitialize _initialize;
  late final _DartRootNode _rootNode;
  late final _DartNodeEvent _appear;
  late final _DartNodeEvent _press;
  late final _DartNodeEvent _longPress;
  late final _DartTextEvent _textChanged;
  late final _DartNodeEvent _submit;
  late final _DartToggleEvent _toggleChanged;
  late final _DartNodeEvent _change;
  late final _DartValueEvent _valueChanged;
  late final _DartNodeEvent _dismiss;
  late final _DartNodeEvent _doublePress;
  late final _DartExtensionEvent _extensionEvent;
  late final _DartNoArgument _dispose;
  late final _DartNoArgument _takeEffect;
  late final _DartResolveEffect _resolveEffect;
  late final _DartStringArgument _applySnapshot;
  late final _DartTwoStringArguments _applyHostUpdate;

  set onCoreIdle(void Function()? callback) {
    _runtimeScheduler.onIdle = callback;
  }

  _DartNodeEvent _nodeEvent(String symbol) =>
      _library.lookupFunction<_NativeNodeEvent, _DartNodeEvent>(symbol);

  int initialize({int authenticationCode = 1}) {
    _apply(_initialize(3, 3, authenticationCode));
    return _rootNode();
  }

  @override
  void appear(int node) => _runtimeScheduler.runUi(() => _apply(_appear(node)));

  @override
  void press(int node) => _runtimeScheduler.runUi(() => _apply(_press(node)));

  @override
  void longPress(int node) =>
      _runtimeScheduler.runUi(() => _apply(_longPress(node)));

  @override
  void textChanged(int node, String text) {
    _runtimeScheduler.runUi(() {
      final nativeText = text.toNativeUtf8();
      try {
        _apply(_textChanged(node, nativeText));
      } finally {
        malloc.free(nativeText);
      }
    });
  }

  @override
  void submit(int node) => _runtimeScheduler.runUi(() => _apply(_submit(node)));

  @override
  void toggleChanged(int node, bool checked) => _runtimeScheduler.runUi(
    () => _apply(_toggleChanged(node, checked ? 1 : 0)),
  );

  @override
  void change(int node) => _runtimeScheduler.runUi(() => _apply(_change(node)));

  @override
  void valueChanged(int node, double value) =>
      _runtimeScheduler.runUi(() => _apply(_valueChanged(node, value)));

  @override
  void dismiss(int node) =>
      _runtimeScheduler.runUi(() => _apply(_dismiss(node)));

  @override
  void doublePress(int node) =>
      _runtimeScheduler.runUi(() => _apply(_doublePress(node)));

  @override
  void extensionEvent(
    int node,
    String identifier,
    String name,
    String text,
    int value,
  ) {
    _runtimeScheduler.runUi(() {
      final nativeIdentifier = identifier.toNativeUtf8();
      final nativeName = name.toNativeUtf8();
      final nativeText = text.toNativeUtf8();
      try {
        _apply(
          _extensionEvent(
            node,
            nativeIdentifier,
            nativeName,
            nativeText,
            value,
          ),
        );
      } finally {
        malloc.free(nativeIdentifier);
        malloc.free(nativeName);
        malloc.free(nativeText);
      }
    });
  }

  void close() => _runtimeScheduler.runUi(() => _apply(_dispose()));

  @override
  String takeEffect() =>
      _runtimeScheduler.isCoreBusy ? '' : _read(_takeEffect());

  @override
  String resolveEffect({
    required int id,
    required bool succeeded,
    required String message,
  }) {
    if (_runtimeScheduler.isCoreBusy) {
      debugPrint('[NativeBridge] resolveEffect id=$id queued (core busy)');
      _runtimeScheduler.runUi(
        () => _apply(
          _resolveEffectWithMessage(
            id: id,
            succeeded: succeeded,
            message: message,
          ),
        ),
      );
      return '';
    }
    debugPrint('[NativeBridge] resolveEffect id=$id call');
    final result = _read(
      _resolveEffectWithMessage(id: id, succeeded: succeeded, message: message),
    );
    debugPrint(
      '[NativeBridge] resolveEffect id=$id returned chars=${result.length}',
    );
    return result;
  }

  Pointer<Utf8> _resolveEffectWithMessage({
    required int id,
    required bool succeeded,
    required String message,
  }) {
    final nativeMessage = message.toNativeUtf8();
    try {
      return _resolveEffect(id, succeeded ? 1 : 0, nativeMessage);
    } finally {
      malloc.free(nativeMessage);
    }
  }

  @override
  String applySnapshot(String response) {
    if (_runtimeScheduler.isCoreBusy) {
      debugPrint(
        '[NativeBridge] applySnapshot queued (core busy) '
        'chars=${response.length}',
      );
      _runtimeScheduler.runUi(
        () => _apply(_applySnapshotWithResponse(response)),
      );
      return '';
    }
    debugPrint('[NativeBridge] applySnapshot call chars=${response.length}');
    final result = _read(_applySnapshotWithResponse(response));
    debugPrint(
      '[NativeBridge] applySnapshot returned chars=${result.length}',
    );
    return result;
  }

  Pointer<Utf8> _applySnapshotWithResponse(String response) {
    final nativeResponse = response.toNativeUtf8();
    try {
      return _applySnapshot(nativeResponse);
    } finally {
      malloc.free(nativeResponse);
    }
  }

  @override
  String applyHostUpdate({required String kind, required String payload}) {
    if (_runtimeScheduler.isCoreBusy) {
      debugPrint('[NativeBridge] applyHostUpdate kind=$kind queued (core busy)');
      _runtimeScheduler.runUi(
        () => _apply(_applyHostUpdateWithPayload(kind, payload)),
      );
      return '';
    }
    debugPrint('[NativeBridge] applyHostUpdate kind=$kind call');
    final result = _read(_applyHostUpdateWithPayload(kind, payload));
    debugPrint(
      '[NativeBridge] applyHostUpdate kind=$kind returned '
      'chars=${result.length}',
    );
    return result;
  }

  Pointer<Utf8> _applyHostUpdateWithPayload(String kind, String payload) {
    final nativeKind = kind.toNativeUtf8();
    final nativePayload = payload.toNativeUtf8();
    try {
      return _applyHostUpdate(nativeKind, nativePayload);
    } finally {
      malloc.free(nativeKind);
      malloc.free(nativePayload);
    }
  }

  Future<String> callCore(String request) => _runtimeScheduler.runCore(
    () => Isolate.run(() => _callCoreInWorker(request)),
  );

  void _apply(Pointer<Utf8> pointer) {
    final patch = _read(pointer);
    if (patch.isNotEmpty) onPatch(patch);
  }

  String _read(Pointer<Utf8> pointer) =>
      pointer == nullptr ? '' : pointer.toDartString();
}

String _callCoreInWorker(String request) {
  final library = DynamicLibrary.open('liblogseq_chat_core.so');
  final call = library.lookupFunction<_NativeCoreCall, _DartCoreCall>(
    'logseq_chat_call',
  );
  final nativeRequest = request.toNativeUtf8();
  try {
    final response = call(nativeRequest);
    return response == nullptr ? '' : response.toDartString();
  } finally {
    malloc.free(nativeRequest);
  }
}
