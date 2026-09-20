import 'dart:async';
import 'dart:collection';

typedef NativeRuntimeIdleCallback = void Function();

final class NativeRuntimeScheduler {
  NativeRuntimeScheduler({this.onIdle});

  NativeRuntimeIdleCallback? onIdle;

  final Queue<void Function()> _deferredUiCalls = Queue();
  Future<void> _coreTail = Future<void>.value();
  var _pendingCoreCalls = 0;

  bool get isCoreBusy => _pendingCoreCalls > 0;

  Future<T> runCore<T>(Future<T> Function() operation) {
    final result = Completer<T>();
    _pendingCoreCalls += 1;
    _coreTail = _coreTail.then((_) async {
      try {
        result.complete(await operation());
      } catch (error, stackTrace) {
        result.completeError(error, stackTrace);
      } finally {
        _pendingCoreCalls -= 1;
        if (_pendingCoreCalls == 0) {
          _flushUiCalls();
          onIdle?.call();
        }
      }
    });
    return result.future;
  }

  void runUi(void Function() operation) {
    if (isCoreBusy) {
      _deferredUiCalls.addLast(operation);
      return;
    }
    operation();
  }

  void _flushUiCalls() {
    while (_deferredUiCalls.isNotEmpty) {
      _deferredUiCalls.removeFirst()();
    }
  }
}
