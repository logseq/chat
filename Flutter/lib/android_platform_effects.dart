import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

import 'core_bootstrap.dart';
import 'android_imported_asset.dart';
import 'native_effect_drain.dart';

abstract interface class AndroidAuthentication {
  Future<bool> hasStoredSession();

  Future<String?> restoreAccessToken();

  Future<String> signIn();

  Future<void> signOut();
}

final class MethodChannelAndroidAuthentication
    implements AndroidAuthentication {
  const MethodChannelAndroidAuthentication({
    this._channel = const MethodChannel('com.logseq.chat/authentication'),
  });

  final MethodChannel _channel;

  @override
  Future<bool> hasStoredSession() async =>
      await _channel.invokeMethod<bool>('hasStoredSession') ?? false;

  @override
  Future<String?> restoreAccessToken() =>
      _channel.invokeMethod<String>('restoreAccessToken');

  @override
  Future<String> signIn() async =>
      (await _channel.invokeMethod<String>('signIn')) ?? '';

  @override
  Future<void> signOut() => _channel.invokeMethod<void>('signOut');
}

abstract class AndroidPlatformServices {
  Future<AndroidStorageState> loadStorageState() async =>
      const AndroidStorageState(
        databasePath: '',
        graphsDirectory: '',
        baseUrl: 'http://127.0.0.1:8787',
        selectedGraphId: '',
        localGraphIds: [],
        settings: AndroidHostSettings.defaults,
        composerDraft: '',
      );

  Future<void> persistComposerDraft(String draft) async {}

  Future<void> saveSettings(String settings) async {}

  Future<bool> openExternalUrl(String url) async => false;

  Future<void> copyText(String text) async {}

  Future<String> refreshRuntimeLog({
    required String source,
    required int flags,
  }) async => '[]';

  Future<void> appendRuntimeLog({
    required String level,
    required String source,
    required String message,
  }) async {}

  Future<bool> presentAttachment(String kind) async => false;

  Future<List<AndroidImportedAsset>> importAttachments(String kind) async =>
      const [];

  Future<bool> presentAsset(String metadata) async => false;

  Future<bool> presentPageShare({
    required String text,
    required String metadata,
  }) async => false;

  Future<bool> syncNow() async => false;

  Future<bool> deleteLocalGraph(String graphId) async => false;

  Future<bool> exportGraphDatabase() async => false;

  Future<AndroidDownloadedSnapshot> downloadGraphSnapshot({
    required String baseUrl,
    required String graphId,
    required String accessToken,
    required String workingDirectory,
  }) async => throw UnsupportedError('Graph snapshot download is unavailable');

  Future<void> persistSelectedGraphId(String graphId) async {}

  Future<void> deleteTemporaryFile(String path) async {}

  String resolveAssetPath(String path) => path;
}

final class MethodChannelAndroidPlatformServices
    extends AndroidPlatformServices {
  MethodChannelAndroidPlatformServices({
    this.channel = const MethodChannel('com.logseq.chat/platform'),
  });

  final MethodChannel channel;
  String? _filesDirectory;

  @override
  Future<AndroidStorageState> loadStorageState() async {
    final value = await channel.invokeMapMethod<String, Object?>(
      'loadStorageState',
    );
    if (value == null) {
      throw PlatformException(
        code: 'storage_state_missing',
        message: 'Android did not return storage state',
      );
    }
    final localGraphIds = value['localGraphIds'];
    final encodedSettings = value['settings'];
    final databasePath = value['databasePath']! as String;
    _filesDirectory = File(databasePath).parent.path;
    return AndroidStorageState(
      databasePath: databasePath,
      graphsDirectory: value['graphsDirectory']! as String,
      baseUrl: value['baseUrl']! as String,
      selectedGraphId: value['selectedGraphId']! as String,
      localGraphIds: localGraphIds is List<Object?>
          ? localGraphIds.whereType<String>().toList(growable: false)
          : const [],
      settings: AndroidHostSettings.fromPlatformValue(encodedSettings),
      composerDraft: value['composerDraft'] as String? ?? '',
    );
  }

  @override
  Future<void> persistComposerDraft(String draft) =>
      channel.invokeMethod<void>('persistComposerDraft', {'draft': draft});

  @override
  Future<void> saveSettings(String settings) =>
      channel.invokeMethod<void>('saveSettings', {'settings': settings});

  @override
  Future<bool> openExternalUrl(String url) async =>
      await channel.invokeMethod<bool>('openExternalUrl', {'url': url}) ??
      false;

  @override
  Future<void> copyText(String text) =>
      channel.invokeMethod<void>('copyText', {'text': text});

  @override
  Future<String> refreshRuntimeLog({
    required String source,
    required int flags,
  }) async =>
      await channel.invokeMethod<String>('refreshRuntimeLog', {
        'source': source,
        'flags': flags,
      }) ??
      '[]';

  @override
  Future<void> appendRuntimeLog({
    required String level,
    required String source,
    required String message,
  }) => channel.invokeMethod<void>('appendRuntimeLog', {
    'level': level,
    'source': source,
    'message': message,
  });

  @override
  Future<bool> presentAttachment(String kind) async =>
      await channel.invokeMethod<bool>('presentAttachment', {'kind': kind}) ??
      false;

  @override
  Future<List<AndroidImportedAsset>> importAttachments(String kind) async {
    final values = await channel.invokeListMethod<Object?>(
      'importAttachments',
      {'kind': kind},
    );
    if (values == null) return const [];
    return values
        .whereType<Map<Object?, Object?>>()
        .map(
          (value) => AndroidImportedAsset.fromMap(
            value.map((key, value) => MapEntry(key.toString(), value)),
          ),
        )
        .toList(growable: false);
  }

  @override
  Future<bool> presentAsset(String metadata) async =>
      await channel.invokeMethod<bool>('presentAsset', {
        'metadata': metadata,
      }) ??
      false;

  @override
  Future<bool> presentPageShare({
    required String text,
    required String metadata,
  }) async =>
      await channel.invokeMethod<bool>('presentPageShare', {
        'text': text,
        'metadata': metadata,
      }) ??
      false;

  @override
  Future<bool> syncNow() async =>
      await channel.invokeMethod<bool>('syncNow') ?? false;

  @override
  Future<bool> deleteLocalGraph(String graphId) async =>
      await channel.invokeMethod<bool>('deleteLocalGraph', {
        'graphId': graphId,
      }) ??
      false;

  @override
  Future<bool> exportGraphDatabase() async =>
      await channel.invokeMethod<bool>('exportGraphDatabase') ?? false;

  @override
  Future<AndroidDownloadedSnapshot> downloadGraphSnapshot({
    required String baseUrl,
    required String graphId,
    required String accessToken,
    required String workingDirectory,
  }) async {
    final value = await channel.invokeMapMethod<String, Object?>(
      'downloadGraphSnapshot',
      {
        'baseUrl': baseUrl,
        'graphId': graphId,
        'accessToken': accessToken,
        'workingDirectory': workingDirectory,
      },
    );
    if (value == null) {
      throw const FormatException('Android did not return a graph snapshot');
    }
    return AndroidDownloadedSnapshot(
      metadataBody: value['metadataBody']! as String,
      filePath: value['filePath']! as String,
    );
  }

  @override
  Future<void> persistSelectedGraphId(String graphId) => channel
      .invokeMethod<void>('persistSelectedGraphId', {'graphId': graphId});

  @override
  Future<void> deleteTemporaryFile(String path) =>
      channel.invokeMethod<void>('deleteTemporaryFile', {'path': path});

  @override
  String resolveAssetPath(String path) {
    if (path.isEmpty || File(path).isAbsolute) return path;
    final filesDirectory = _filesDirectory;
    return filesDirectory == null
        ? path
        : File('$filesDirectory${Platform.pathSeparator}$path').path;
  }
}

final class AndroidPlatformEffects {
  AndroidPlatformEffects({
    required this.authentication,
    AndroidPlatformServices? platform,
  }) : platform = platform ?? MethodChannelAndroidPlatformServices();

  final AndroidAuthentication authentication;
  final AndroidPlatformServices platform;

  Future<int> initialAuthenticationCode() async {
    try {
      return await authentication.hasStoredSession() ? 3 : 1;
    } catch (_) {
      return 1;
    }
  }

  Future<String?> restoreAccessToken() => authentication.restoreAccessToken();

  Future<CoreStartupState> coreStartupState({
    required String accessToken,
    AndroidStorageState? storage,
  }) async {
    final resolvedStorage = storage ?? await platform.loadStorageState();
    return CoreStartupState(
      databasePath: resolvedStorage.databasePath,
      graphsDirectory: resolvedStorage.graphsDirectory,
      baseUrl: resolvedStorage.baseUrl,
      selectedGraphId: resolvedStorage.selectedGraphId,
      localGraphIds: resolvedStorage.localGraphIds,
      accessToken: accessToken,
    );
  }

  Future<NativeEffectResolution> execute(NativeEffect effect) async {
    try {
      switch (effect.kind) {
        case 'persist-composer-draft':
          await platform.persistComposerDraft(effect.text);
          return const NativeEffectResolution.discard();
        case 'save-settings':
          await platform.saveSettings(effect.text);
          return const NativeEffectResolution.discard();
        case 'open-external-url':
          return NativeEffectResolution.discard(
            succeeded: await platform.openExternalUrl(effect.text),
            message: '',
          );
        case 'copy-runtime-log':
          await platform.copyText(_runtimeLogText(effect.text));
          return const NativeEffectResolution.discard();
        case 'refresh-runtime-log':
          final records = await platform.refreshRuntimeLog(
            source: effect.text,
            flags: effect.value ?? 0,
          );
          return NativeEffectResolution.hostUpdate(
            kind: 'runtime-log',
            payload: records,
          );
        case 'present-attachment':
          return NativeEffectResolution.discard(
            succeeded: await platform.presentAttachment(effect.text),
            message: '',
          );
        case 'present-asset':
          return NativeEffectResolution.discard(
            succeeded: await platform.presentAsset(effect.metadata ?? ''),
            message: '',
          );
        case 'present-page-share':
          return NativeEffectResolution.discard(
            succeeded: await platform.presentPageShare(
              text: effect.text,
              metadata: effect.metadata ?? '[]',
            ),
            message: '',
          );
        case 'sync-now':
          final succeeded = await platform.syncNow();
          return NativeEffectResolution.discard(
            succeeded: succeeded,
            message: succeeded ? '' : 'Sync is unavailable while the WebSocket transport is being migrated',
          );
        case 'delete-local-graph':
          return NativeEffectResolution.discard(
            succeeded: await platform.deleteLocalGraph(effect.text),
            message: '',
          );
        case 'export-graph-database':
          return NativeEffectResolution.discard(
            succeeded: await platform.exportGraphDatabase(),
            message: '',
          );
        case 'sign-in':
          final token = await authentication.signIn();
          if (token.trim().isEmpty) {
            return const NativeEffectResolution.discard(
              succeeded: false,
              message: 'Hosted sign-in did not return an access token',
            );
          }
          return const NativeEffectResolution.discard();
        case 'sign-out':
          await authentication.signOut();
          return const NativeEffectResolution.discard();
        default:
          return NativeEffectResolution.discard(
            succeeded: false,
            message: 'Unsupported Android platform effect: ${effect.kind}',
          );
      }
    } catch (error) {
      return NativeEffectResolution.discard(
        succeeded: false,
        message: error.toString(),
      );
    }
  }
}

final class AndroidStorageState {
  const AndroidStorageState({
    required this.databasePath,
    required this.graphsDirectory,
    required this.baseUrl,
    required this.selectedGraphId,
    required this.localGraphIds,
    this.settings = AndroidHostSettings.defaults,
    this.composerDraft = '',
  });

  final String databasePath;
  final String graphsDirectory;
  final String baseUrl;
  final String selectedGraphId;
  final List<String> localGraphIds;
  final AndroidHostSettings settings;
  final String composerDraft;

  List<AndroidHostUpdate> get startupHostUpdates => [
    const AndroidHostUpdate(kind: 'graph-loading', payload: 'true'),
    AndroidHostUpdate(
      kind: 'settings',
      payload: jsonEncode(settings.hostPayload),
    ),
    AndroidHostUpdate(
      kind: 'composer-draft',
      payload: jsonEncode(composerDraft),
    ),
  ];
}

final class AndroidHostUpdate {
  const AndroidHostUpdate({required this.kind, required this.payload});

  final String kind;
  final String payload;
}

final class AndroidHostSettings {
  const AndroidHostSettings({
    required this.appearance,
    required this.language,
    required this.spellCheck,
    required this.autoCorrection,
    required this.sidebarTabs,
    required this.baseUrl,
    required this.version,
    required this.revision,
  });

  static const defaults = AndroidHostSettings(
    appearance: 'system',
    language: 'system',
    spellCheck: true,
    autoCorrection: true,
    sidebarTabs: [],
    baseUrl: 'http://127.0.0.1:8787',
    version: 'Development',
    revision: 'Development',
  );

  factory AndroidHostSettings.fromPlatformValue(Object? value) {
    if (value is! Map<Object?, Object?>) return defaults;
    final tabs = value['sidebarTabs'];
    return AndroidHostSettings(
      appearance: value['appearance'] as String? ?? defaults.appearance,
      language: value['language'] as String? ?? defaults.language,
      spellCheck: value['spellCheck'] as bool? ?? defaults.spellCheck,
      autoCorrection:
          value['autoCorrection'] as bool? ?? defaults.autoCorrection,
      sidebarTabs: tabs is List<Object?>
          ? tabs.whereType<String>().toList(growable: false)
          : defaults.sidebarTabs,
      baseUrl: value['baseURL'] as String? ?? defaults.baseUrl,
      version: value['version'] as String? ?? defaults.version,
      revision: value['revision'] as String? ?? defaults.revision,
    );
  }

  final String appearance;
  final String language;
  final bool spellCheck;
  final bool autoCorrection;
  final List<String> sidebarTabs;
  final String baseUrl;
  final String version;
  final String revision;

  Map<String, Object?> get hostPayload => {
    'appearance': appearance,
    'language': language,
    'spellCheck': spellCheck,
    'autoCorrection': autoCorrection,
    'sidebarTabs': sidebarTabs,
    'baseURL': baseUrl,
    'version': version,
    'revision': revision,
  };
}

final class AndroidDownloadedSnapshot {
  const AndroidDownloadedSnapshot({
    required this.metadataBody,
    required this.filePath,
  });

  final String metadataBody;
  final String filePath;
}

String _runtimeLogText(String encoded) {
  final decoded = jsonDecode(encoded);
  if (decoded is! List<Object?>) {
    throw const FormatException('Runtime log records must be a list');
  }
  return decoded
      .map((entry) {
        if (entry is! Map<String, Object?>) {
          throw const FormatException('Runtime log record must be an object');
        }
        return [
          entry['timestamp'],
          entry['level'],
          entry['source'],
          entry['message'],
        ].whereType<String>().join(' ');
      })
      .join('\n');
}
