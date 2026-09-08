import 'package:lui_flutter_backend/lui_flutter_backend.dart';

abstract interface class LogseqChatNativeDispatch {
  void appear(int node);
  void press(int node);
  void longPress(int node);
  void textChanged(int node, String text);
  void submit(int node);
  void toggleChanged(int node, bool checked);
  void change(int node);
  void valueChanged(int node, double value);
  void dismiss(int node);
  void doublePress(int node);
  void extensionEvent(
    int node,
    String identifier,
    String name,
    String text,
    int value,
  );
}

void dispatchLUIEvent(LUIEvent event, LogseqChatNativeDispatch native) {
  switch (event) {
    case LUIAppearEvent(:final node):
      native.appear(node);
    case LUIPressEvent(:final node):
      native.press(node);
    case LUILongPressEvent(:final node):
      native.longPress(node);
    case LUITextChangedEvent(:final node, :final text):
      native.textChanged(node, text);
    case LUISubmitEvent(:final node):
      native.submit(node);
    case LUIToggleChangedEvent(:final node, :final checked):
      native.toggleChanged(node, checked);
    case LUIChangeEvent(:final node):
      native.change(node);
    case LUIValueChangedEvent(:final node, :final value):
      native.valueChanged(node, value);
    case LUIDismissEvent(:final node):
      native.dismiss(node);
    case LUIDoublePressEvent(:final node):
      native.doublePress(node);
    case LUIExtensionComponentEvent(
      :final node,
      :final identifier,
      :final name,
      :final values,
    ):
      native.extensionEvent(
        node,
        identifier,
        name,
        _extensionText(values),
        _extensionValue(values),
      );
  }
}

String _extensionText(Map<String, Object> values) {
  for (final key in const ['uuid', 'title', 'query', 'value']) {
    final value = values[key];
    if (value is String) return value;
  }
  return '';
}

int _extensionValue(Map<String, Object> values) {
  for (final key in const ['caret-utf16-offset', 'selection-length', 'count']) {
    final value = values[key];
    if (value is int) return value;
  }
  return switch (values['placement']) {
    'before' => 0,
    'inside' => 1,
    'after' => 2,
    _ => 0,
  };
}
