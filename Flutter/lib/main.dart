import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:lui_flutter_backend/lui_flutter_backend.dart';

import 'android_platform_effects.dart';
import 'android_imported_asset.dart';
import 'android_app_entry.dart';
import 'android_audio_recording.dart';
import 'android_outliner_commands.dart';
import 'android_graph_lifecycle.dart';
import 'core_bootstrap.dart';
import 'core_effect_executor.dart';
import 'flutter_patch_applier.dart';
import 'graph_catalog_auto_refresh.dart';
import 'graph_catalog_polling_policy.dart';
import 'logseq_chat_extensions.dart';
import 'logseq_chat_icons.dart';
import 'logseq_chat_app_frame.dart';
import 'logseq_chat_native_bridge.dart';
import 'logseq_chat_theme.dart';
import 'lui_dispatch.dart';
import 'native_effect_drain.dart';

final Stopwatch _startupClock = Stopwatch()..start();

void _traceStartup(String message) {
  debugPrint('[Startup] +${_startupClock.elapsedMilliseconds}ms $message');
}

void main() {
  _traceStartup('main entered');
  WidgetsFlutterBinding.ensureInitialized();
  _traceStartup('Flutter binding initialized');
  runApp(const LogseqChatFlutterApp());
  _traceStartup('runApp returned');
}

class LogseqChatFlutterApp extends StatefulWidget {
  const LogseqChatFlutterApp({super.key});

  @override
  State<LogseqChatFlutterApp> createState() => _LogseqChatFlutterAppState();
}

class _LogseqChatFlutterAppState extends State<LogseqChatFlutterApp>
    with WidgetsBindingObserver {
  final _navigatorKey = GlobalKey<NavigatorState>();
  late final LUIFlutterBackend _backend;
  late final FlutterPatchApplier _patchApplier;
  LogseqChatNativeBridge? _bridge;
  NativeEffectDrain? _effectDrain;
  CoreEffectExecutor? _coreEffects;
  GraphCatalogAutoRefresh? _graphCatalogAutoRefresh;
  Future<void>? _activeBootstrap;
  var _activeBootstrapHasStoredSession = false;
  var _hasAuthenticatedSession = false;
  var _hasOpenGraph = false;
  var _appIsForeground = true;
  late final AndroidPlatformEffects _platformEffects;
  late final AndroidAppEntryCoordinator _appEntries;
  final _audioRecording = const MethodChannelAndroidAudioRecordingBackend();
  late final OutlinerPlatformCommandDispatcher _outlinerCommands;
  int? _rootNode;
  Object? _startupError;
  ThemeMode _themeMode = ThemeMode.system;

  @override
  void initState() {
    super.initState();
    _traceStartup('app state init started');
    WidgetsBinding.instance.addObserver(this);
    _platformEffects = AndroidPlatformEffects(
      authentication: MethodChannelAndroidAuthentication(),
    );
    _appEntries = AndroidAppEntryCoordinator(
      entries: const EventChannelAndroidAppEntrySource().entries,
      handle: _handleAppEntry,
      onError: _reportEffectError,
    )..start();
    _logRuntime(
      level: 'info',
      source: 'ui',
      message: 'Flutter host initialized',
    );
    _backend = LUIFlutterBackend(
      onEvent: _dispatch,
      extensionRegistry: logseqChatExtensionRegistry(
        resolveAssetPath: _platformEffects.platform.resolveAssetPath,
      ),
      appIcons: logseqChatAppIcons,
    );
    _patchApplier = FlutterPatchApplier(_backend);
    final commandHandler = AndroidOutlinerPlatformCommandHandler(
      navigatorKey: _navigatorKey,
      platform: _platformEffects.platform,
      sendOutlinerEvent: _sendOutlinerEvent,
      presentAttachment: _presentAttachment,
      presentAudioRecording: _presentAudioRecording,
    );
    _outlinerCommands = OutlinerPlatformCommandDispatcher(
      commandHandler.handle,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _traceStartup('first Flutter frame completed');
    });
    _traceStartup('app state init completed; starting host bootstrap');
    unawaited(_start());
  }

  Future<void> _start() async {
    try {
      _traceStartup('platform startup state requested');
      final authenticationFuture = _platformEffects.initialAuthenticationCode();
      final storageFuture = _platformEffects.platform.loadStorageState();
      final authenticationCode = await authenticationFuture;
      final storage = await storageFuture;
      _traceStartup('platform startup state loaded');
      if (!mounted) return;
      _themeMode = logseqChatThemeMode(storage.settings.appearance);
      _traceStartup('native bridge loading started');
      final bridge = LogseqChatNativeBridge(onPatch: _applyPatch);
      _traceStartup('native bridge loaded');
      _bridge = bridge;
      final graphLifecycle = AndroidGraphLifecycle(
        callCore: bridge.callCore,
        platform: _platformEffects.platform,
        accessTokenProvider: _platformEffects.restoreAccessToken,
        trace: _traceGraphLifecycle,
      );
      _coreEffects = CoreEffectExecutor(
        callCore: bridge.callCore,
        executePlatformEffect: _platformEffects.execute,
        executeGraphEffect: graphLifecycle.execute,
      );
      _graphCatalogAutoRefresh = GraphCatalogAutoRefresh(
        callCore: bridge.callCore,
        applyCoreResponse: _applyCoreResponse,
        trace: (message) => _traceGraphCatalogRefresh('automatic $message'),
      );
      final effectDrain = NativeEffectDrain(
        runtime: bridge,
        execute: _executeEffect,
        applyPatch: _applyPatch,
        afterCoreResponseApplied: _outlinerCommands.deliver,
        onError: _reportEffectError,
        trace: _traceNativeEffect,
      );
      _effectDrain = effectDrain;
      bridge.onCoreIdle = () {
        final drain = _effectDrain;
        if (drain != null) unawaited(drain.drain());
      };
      _traceStartup('LUI initialization started');
      final rootNode = bridge.initialize(
        authenticationCode: authenticationCode,
      );
      _traceStartup('LUI initialization completed');
      for (final update in storage.startupHostUpdates) {
        _applyPatch(
          bridge.applyHostUpdate(kind: update.kind, payload: update.payload),
        );
      }
      setState(() => _rootNode = rootNode);
      _traceStartup('LUI root mounted');
      unawaited(effectDrain.drain());
      unawaited(
        _restoreCore(
          hasStoredSession: authenticationCode == 3,
          storage: storage,
        ),
      );
    } catch (error, stack) {
      if (mounted) setState(() => _startupError = error);
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stack,
          library: 'Logseq Chat Flutter host',
          context: ErrorDescription('while starting the native LG runtime'),
        ),
      );
    }
  }

  void _dispatch(LUIEvent event) {
    final bridge = _bridge;
    if (bridge == null) return;
    switch (event) {
      case LUIPressEvent(:final node):
        debugPrint('[LUIEvent] press node=$node');
      case LUISubmitEvent(:final node):
        debugPrint('[LUIEvent] submit node=$node');
      case LUIToggleChangedEvent(:final node, :final checked):
        debugPrint('[LUIEvent] toggle node=$node checked=$checked');
      case LUIDismissEvent(:final node):
        debugPrint('[LUIEvent] dismiss node=$node');
      case LUIExtensionComponentEvent(
        :final node,
        :final identifier,
        :final name,
      ):
        debugPrint(
          '[LUIEvent] extension node=$node component=$identifier name=$name',
        );
      default:
        break;
    }
    dispatchLUIEvent(event, bridge);
    final effectDrain = _effectDrain;
    if (effectDrain != null) unawaited(effectDrain.drain());
  }

  Future<NativeEffectResolution> _executeEffect(NativeEffect effect) async {
    if (effect.kind == 'present-attachment') {
      try {
        if (effect.text == 'audio') {
          await _presentAudioRecording(null);
        } else {
          await _presentAttachment(effect.text, null);
        }
        return const NativeEffectResolution.discard();
      } catch (error, stack) {
        _reportEffectError(error, stack);
        return NativeEffectResolution.discard(
          succeeded: false,
          message: error.toString(),
        );
      }
    }
    final coreEffects = _coreEffects;
    if (coreEffects == null) {
      return const NativeEffectResolution.discard(
        succeeded: false,
        message: 'The native core effect executor is unavailable',
      );
    }
    final resolution = await coreEffects.execute(effect);
    if (effect.kind == 'save-settings' && resolution.succeeded) {
      final settings = jsonDecode(effect.text);
      if (settings is Map<String, Object?>) {
        final nextThemeMode = logseqChatThemeMode(
          settings['appearance'] as String? ?? 'system',
        );
        if (mounted && nextThemeMode != _themeMode) {
          setState(() => _themeMode = nextThemeMode);
        }
      }
    }
    if (effect.kind == 'sign-in' && resolution.succeeded) {
      await _restoreCore(hasStoredSession: true);
    }
    if (effect.kind == 'sign-out' && resolution.succeeded) {
      _hasAuthenticatedSession = false;
      _hasOpenGraph = false;
      _graphCatalogAutoRefresh?.stopPeriodic();
    }
    if (resolution.succeeded &&
        (effect.kind == 'open-graph' ||
            effect.kind == 'unlock-graph' ||
            effect.kind == 'create-graph')) {
      _hasOpenGraph = true;
      _graphCatalogAutoRefresh?.stopPeriodic();
    }
    return resolution;
  }

  Future<void> _restoreCore({
    required bool hasStoredSession,
    AndroidStorageState? storage,
  }) {
    final active = _activeBootstrap;
    if (active != null) {
      if (hasStoredSession && !_activeBootstrapHasStoredSession) {
        return active.then((_) => _restoreCore(hasStoredSession: true));
      }
      return active;
    }
    late final Future<void> operation;
    operation =
        _runCoreRestore(
          hasStoredSession: hasStoredSession,
          storage: storage,
        ).whenComplete(() {
          if (identical(_activeBootstrap, operation)) _activeBootstrap = null;
        });
    _activeBootstrap = operation;
    _activeBootstrapHasStoredSession = hasStoredSession;
    return operation;
  }

  Future<void> _runCoreRestore({
    required bool hasStoredSession,
    AndroidStorageState? storage,
  }) async {
    final bridge = _bridge;
    if (bridge == null) return;
    var accessToken = '';
    if (hasStoredSession) {
      try {
        accessToken = (await _platformEffects.restoreAccessToken()) ?? '';
        if (accessToken.trim().isEmpty) {
          throw StateError('The stored session did not return an access token');
        }
      } catch (error, stack) {
        _hasAuthenticatedSession = false;
        _applyPatch(
          bridge.applyHostUpdate(
            kind: 'authentication',
            payload: jsonEncode({
              'state': 'signedOut',
              'errorMessage': error.toString(),
            }),
          ),
        );
        _reportEffectError(error, stack);
      }
    }
    _hasAuthenticatedSession = accessToken.trim().isNotEmpty;
    try {
      _logRuntime(
        level: 'info',
        source: 'core',
        message: 'Restoring core state',
      );
      final state = await _platformEffects.coreStartupState(
        accessToken: accessToken,
        storage: storage,
      );
      final restored = await CoreBootstrap(
        callCore: bridge.callCore,
        trace: (message) => _traceGraphLifecycle('bootstrap $message'),
      ).restore(state);
      await _applyCoreResponse(restored.catalogResponse);
      _graphCatalogAutoRefresh?.rememberCatalog(restored.catalogResponse);
      _applyPatch(
        bridge.applyHostUpdate(
          kind: 'local-graph-ids',
          payload: jsonEncode(restored.localGraphIds),
        ),
      );
      final graphResponse = restored.graphResponse;
      _hasOpenGraph = graphResponse != null;
      if (graphResponse != null) {
        await _applyCoreResponse(graphResponse);
      }
      _applyPatch(
        bridge.applyHostUpdate(kind: 'graph-loading', payload: 'false'),
      );
      _logRuntime(
        level: 'info',
        source: 'core',
        message: 'Core state restored',
      );
      await _appEntries.markReady();
      if (shouldPollGraphCatalog(
        authenticated: _hasAuthenticatedSession,
        hasOpenGraph: _hasOpenGraph,
        foreground: _appIsForeground,
      )) {
        _graphCatalogAutoRefresh?.startPeriodic();
        unawaited(_refreshGraphCatalog(reason: 'restore'));
      } else {
        _graphCatalogAutoRefresh?.stopPeriodic();
      }
    } catch (error, stack) {
      _logRuntime(level: 'error', source: 'core', message: error.toString());
      _reportEffectError(error, stack);
      _applyPatch(
        bridge.applyHostUpdate(kind: 'graph-loading', payload: 'false'),
      );
    }
  }

  Future<void> _refreshGraphCatalog({required String reason}) async {
    final refresher = _graphCatalogAutoRefresh;
    if (refresher == null ||
        !shouldPollGraphCatalog(
          authenticated: _hasAuthenticatedSession,
          hasOpenGraph: _hasOpenGraph,
          foreground: _appIsForeground,
        )) {
      return;
    }
    try {
      _traceGraphCatalogRefresh('$reason requested');
      final refreshed = await refresher.refresh();
      if (!refreshed) {
        _traceGraphCatalogRefresh('$reason rejected');
      }
    } catch (error, stack) {
      _traceGraphCatalogRefresh('$reason failed error=$error');
      _reportEffectError(error, stack);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _appIsForeground = state == AppLifecycleState.resumed;
    if (shouldPollGraphCatalog(
      authenticated: _hasAuthenticatedSession,
      hasOpenGraph: _hasOpenGraph,
      foreground: _appIsForeground,
    )) {
      _graphCatalogAutoRefresh?.startPeriodic();
      unawaited(_refreshGraphCatalog(reason: 'resume'));
    } else {
      _graphCatalogAutoRefresh?.stopPeriodic();
    }
  }

  void _applyPatch(String patch) {
    if (patch.isEmpty) return;
    try {
      _patchApplier.applyJson(patch);
    } catch (error, stack) {
      _reportEffectError(error, stack);
      if (mounted) setState(() => _startupError = error);
    }
  }

  Future<void> _applyCoreResponse(String response) async {
    final bridge = _bridge;
    if (bridge == null) return;
    _applyPatch(bridge.applySnapshot(response));
    await _outlinerCommands.deliver(response);
  }

  Future<void> _sendOutlinerEvent(Map<String, Object?> event) async {
    final bridge = _bridge;
    if (bridge == null) return;
    final response = await bridge.callCore(
      jsonEncode({
        'apiVersion': 1,
        'method': 'dispatch',
        'params': {'action': 'outlinerEvent', 'payload': jsonEncode(event)},
      }),
    );
    await _applyCoreResponse(response);
  }

  Future<void> _presentAudioRecording(String? targetBlockId) async {
    final context = _navigatorKey.currentContext;
    if (context == null) {
      throw StateError('Audio recording requires an active Android screen');
    }
    final recording = await showAndroidAudioRecordingSheet(
      context: context,
      backend: _audioRecording,
    );
    if (recording == null) return;
    final asset = recording.asset;
    final bridge = _bridge;
    if (bridge == null) {
      throw StateError('The native core is unavailable for recorded audio');
    }
    final response = await bridge.callCore(
      jsonEncode(asset.coreRequest(targetBlockId: targetBlockId)),
    );
    final decoded = jsonDecode(response);
    if (decoded is! Map<String, Object?> || decoded['ok'] != true) {
      throw StateError('The native core rejected the recorded audio asset');
    }
    await _applyCoreResponse(response);
    if (recording.transcriptionEnabled) {
      unawaited(_transcribeRecording(asset));
    }
  }

  Future<void> _transcribeRecording(RecordedAudioAsset asset) async {
    try {
      _logRuntime(
        level: 'info',
        source: 'ui',
        message: 'Audio transcription started',
      );
      final transcript = (await _audioRecording.transcribe(asset.localPath))
          .trim();
      if (transcript.isEmpty) return;
      final bridge = _bridge;
      if (bridge == null) return;
      final response = await bridge.callCore(
        jsonEncode(
          asset.transcriptCoreRequest(
            transcriptUuid: '${asset.uuid}-transcript',
            transcript: transcript,
          ),
        ),
      );
      await _applyCoreResponse(response);
      _logRuntime(
        level: 'info',
        source: 'ui',
        message: 'Audio transcription completed',
      );
    } catch (error, stack) {
      _reportEffectError(error, stack);
    }
  }

  Future<void> _presentAttachment(String kind, String? targetBlockId) async {
    debugPrint(
      '[AttachmentImport] requesting kind=$kind target=${targetBlockId ?? "composer"}',
    );
    _logRuntime(
      level: 'info',
      source: 'ui',
      message: 'Requesting $kind attachment',
    );
    final assets = await _platformEffects.platform.importAttachments(kind);
    debugPrint('[AttachmentImport] received count=${assets.length} kind=$kind');
    _logRuntime(
      level: 'info',
      source: 'ui',
      message: 'Imported ${assets.length} $kind attachment(s)',
    );
    for (final asset in assets) {
      await _addImportedAsset(asset, targetBlockId: targetBlockId);
    }
  }

  Future<void> _addImportedAsset(
    AndroidImportedAsset asset, {
    required String? targetBlockId,
  }) async {
    final bridge = _bridge;
    if (bridge == null) {
      throw StateError('The native core is unavailable for imported assets');
    }
    final response = await bridge.callCore(
      jsonEncode(asset.coreRequest(targetBlockId: targetBlockId)),
    );
    final decoded = jsonDecode(response);
    if (decoded is! Map<String, Object?> || decoded['ok'] != true) {
      throw StateError('The native core rejected ${asset.title}');
    }
    debugPrint(
      '[AttachmentImport] added title=${asset.title} '
      'target=${targetBlockId ?? "composer"} responseBytes=${response.length} '
      'containsAsset=${response.contains(asset.uuid)}',
    );
    _logRuntime(
      level: 'info',
      source: 'core',
      message: 'Added attachment ${asset.title}',
    );
    await _applyCoreResponse(response);
  }

  Future<void> _handleAppEntry(AndroidAppEntry entry) async {
    final bridge = _bridge;
    if (bridge == null) {
      throw StateError(
        'The native core is unavailable for an Android app entry',
      );
    }
    debugPrint('[AppEntry] handling kind=${entry.kind.name}');
    _logRuntime(
      level: 'info',
      source: 'ui',
      message: 'Handling Android app entry ${entry.kind.name}',
    );
    switch (entry.kind) {
      case AndroidAppEntryKind.openCapture:
        _applyPatch(
          bridge.applyHostUpdate(kind: 'open-capture', payload: '{}'),
        );
      case AndroidAppEntryKind.openJournal:
        await _applyAppEntryCoreRequest({
          'apiVersion': 1,
          'method': 'dispatch',
          'params': {'action': 'clearSelectedPage'},
        });
      case AndroidAppEntryKind.sharedText:
        await _applyAppEntryCoreRequest(
          entry.coreRequest(
            uuid: newCoreUuid(),
            nowMilliseconds: DateTime.now().millisecondsSinceEpoch,
          ),
        );
      case AndroidAppEntryKind.sharedAsset:
        await _addImportedAsset(entry.asset!, targetBlockId: null);
    }
    debugPrint('[AppEntry] completed kind=${entry.kind.name}');
  }

  Future<void> _applyAppEntryCoreRequest(Map<String, Object?> request) async {
    final bridge = _bridge;
    if (bridge == null) {
      throw StateError(
        'The native core is unavailable for an Android app entry',
      );
    }
    final response = await bridge.callCore(jsonEncode(request));
    final decoded = jsonDecode(response);
    if (decoded is! Map<String, Object?> || decoded['ok'] != true) {
      throw StateError('The native core rejected the Android app entry');
    }
    await _applyCoreResponse(response);
  }

  void _reportEffectError(Object error, StackTrace stack) {
    _logRuntime(level: 'error', source: 'ui', message: error.toString());
    FlutterError.reportError(
      FlutterErrorDetails(
        exception: error,
        stack: stack,
        library: 'Logseq Chat Flutter host',
        context: ErrorDescription('while executing a native LG effect'),
      ),
    );
  }

  void _traceNativeEffect(String message) {
    if (!message.contains('kind=open-graph') &&
        !message.contains('kind=create-graph') &&
        !message.contains('kind=unlock-graph') &&
        !message.contains('kind=refresh-graphs') &&
        !message.contains('kind=send-capture') &&
        !message.contains('kind=send-task') &&
        !message.contains('kind=search-nodes')) {
      return;
    }
    debugPrint('[NativeEffect] $message');
    _logRuntime(level: 'info', source: 'ui', message: message);
  }

  void _traceGraphLifecycle(String message) {
    debugPrint('[GraphLifecycle] $message');
    _logRuntime(level: 'info', source: 'core', message: message);
  }

  void _traceGraphCatalogRefresh(String message) {
    debugPrint('[GraphCatalog] $message');
    _logRuntime(level: 'info', source: 'core', message: message);
  }

  void _logRuntime({
    required String level,
    required String source,
    required String message,
  }) {
    unawaited(
      _platformEffects.platform.appendRuntimeLog(
        level: level,
        source: source,
        message: message,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: _navigatorKey,
      debugShowCheckedModeBanner: false,
      title: 'Logseq Chat',
      theme: LogseqChatTheme.light(),
      darkTheme: LogseqChatTheme.dark(),
      themeMode: _themeMode,
      home: LogseqChatAppFrame(child: _content()),
    );
  }

  Widget _content() {
    if (_startupError != null) {
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text('Could not start Logseq Chat: $_startupError'),
        ),
      );
    }
    final rootNode = _rootNode;
    if (rootNode != null && rootNode >= 0) {
      return ListenableBuilder(
        listenable: _patchApplier,
        builder: (context, child) =>
            SizedBox.expand(child: _backend.widget(node: rootNode)),
      );
    }
    return const SizedBox.expand();
  }

  @override
  void dispose() {
    _graphCatalogAutoRefresh?.stopPeriodic();
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_appEntries.dispose());
    _effectDrain?.dispose();
    _bridge?.onCoreIdle = null;
    _bridge?.close();
    _patchApplier.dispose();
    _backend.dispose();
    super.dispose();
  }
}
