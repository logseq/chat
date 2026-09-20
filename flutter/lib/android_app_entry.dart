import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:flutter/services.dart';

import 'android_imported_asset.dart';

enum AndroidAppEntryKind { openCapture, openJournal, sharedText, sharedAsset }

final class AndroidAppEntry {
  const AndroidAppEntry._({required this.kind, this.text, this.asset});

  factory AndroidAppEntry.fromMap(Map<String, Object?> value) {
    switch (value['kind']) {
      case 'open-capture':
        return const AndroidAppEntry._(kind: AndroidAppEntryKind.openCapture);
      case 'open-journal':
        return const AndroidAppEntry._(kind: AndroidAppEntryKind.openJournal);
      case 'shared-text':
        final text = value['text'];
        if (text is! String || text.trim().isEmpty) {
          throw const FormatException('A shared-text entry needs text');
        }
        return AndroidAppEntry._(
          kind: AndroidAppEntryKind.sharedText,
          text: text,
        );
      case 'shared-asset':
        final asset = value['asset'];
        if (asset is! Map<Object?, Object?>) {
          throw const FormatException('A shared-asset entry needs an asset');
        }
        return AndroidAppEntry._(
          kind: AndroidAppEntryKind.sharedAsset,
          asset: AndroidImportedAsset.fromMap(
            asset.map((key, value) => MapEntry(key.toString(), value)),
          ),
        );
      default:
        throw FormatException(
          'Unsupported Android app entry: ${value['kind']}',
        );
    }
  }

  final AndroidAppEntryKind kind;
  final String? text;
  final AndroidImportedAsset? asset;

  Map<String, Object?> coreRequest({
    required String uuid,
    required int nowMilliseconds,
  }) {
    if (kind != AndroidAppEntryKind.sharedText) {
      throw StateError('$kind is not a text capture');
    }
    return {
      'apiVersion': 1,
      'method': 'dispatch',
      'params': {
        'action': 'send',
        'payload': jsonEncode({
          'text': text,
          'uuid': uuid,
          'now': nowMilliseconds,
        }),
      },
    };
  }
}

abstract interface class AndroidAppEntrySource {
  Stream<Map<String, Object?>> get entries;
}

final class EventChannelAndroidAppEntrySource implements AndroidAppEntrySource {
  const EventChannelAndroidAppEntrySource({EventChannel? channel})
    : _channel = channel ?? const EventChannel(_channelName);

  final EventChannel _channel;

  @override
  Stream<Map<String, Object?>> get entries =>
      _channel.receiveBroadcastStream().map((value) {
        if (value is! Map<Object?, Object?>) {
          throw const FormatException('Android app entry must be a map');
        }
        return value.map((key, value) => MapEntry(key.toString(), value));
      });

  static const _channelName = 'com.logseq.chat/app-entry';
}

typedef AndroidAppEntryHandler = Future<void> Function(AndroidAppEntry entry);
typedef AndroidAppEntryErrorHandler = void Function(
  Object error,
  StackTrace stack,
);

final class AndroidAppEntryCoordinator {
  AndroidAppEntryCoordinator({
    required this.entries,
    required this.handle,
    this.onError,
  });

  final Stream<Map<String, Object?>> entries;
  final AndroidAppEntryHandler handle;
  final AndroidAppEntryErrorHandler? onError;
  final Queue<AndroidAppEntry> _pending = Queue();
  StreamSubscription<Map<String, Object?>>? _subscription;
  Future<void> _tail = Future.value();
  bool _ready = false;

  Future<void> get settled => _tail;

  void start() {
    if (_subscription != null) return;
    _subscription = entries.listen(
      (value) {
        try {
          _pending.add(AndroidAppEntry.fromMap(value));
          if (_ready) _scheduleDrain();
        } catch (error, stack) {
          onError?.call(error, stack);
        }
      },
      onError: (Object error, StackTrace stack) => onError?.call(error, stack),
    );
  }

  Future<void> markReady() {
    _ready = true;
    return _scheduleDrain();
  }

  Future<void> _scheduleDrain() {
    _tail = _tail.then((_) async {
      while (_ready && _pending.isNotEmpty) {
        final entry = _pending.removeFirst();
        try {
          await handle(entry);
        } catch (error, stack) {
          _pending.addFirst(entry);
          onError?.call(error, stack);
          break;
        }
      }
    });
    return _tail;
  }

  Future<void> dispose() async {
    await _subscription?.cancel();
    _subscription = null;
  }
}
