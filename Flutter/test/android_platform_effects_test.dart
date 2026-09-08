import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logseq_chat_flutter/android_platform_effects.dart';
import 'package:logseq_chat_flutter/native_effect_drain.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('resolves relative assets after Android storage is loaded', () async {
    const channel = MethodChannel('test/storage-state');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'loadStorageState');
      return <String, Object?>{
        'databasePath': '/data/user/0/com.logseq.chat/files/logseq-chat.sqlite',
        'graphsDirectory': '/data/user/0/com.logseq.chat/files/graphs',
        'baseUrl': 'http://127.0.0.1:8787',
        'selectedGraphId': '',
        'localGraphIds': <String>[],
        'composerDraft': 'Persisted draft',
        'settings': <String, Object?>{
          'appearance': 'dark',
          'language': 'zh-Hans',
          'spellCheck': false,
          'autoCorrection': false,
          'sidebarTabs': <String>['journals', 'graphs'],
          'baseURL': 'https://example.test',
          'version': '1.2.3',
          'revision': '42',
        },
      };
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    final services = MethodChannelAndroidPlatformServices(channel: channel);

    expect(services.resolveAssetPath('Assets/photo.png'), 'Assets/photo.png');
    final state = await services.loadStorageState();

    expect(
      services.resolveAssetPath('Assets/photo.png'),
      '/data/user/0/com.logseq.chat/files/Assets/photo.png',
    );
    expect(
      services.resolveAssetPath('/data/user/0/com.logseq.chat/cache/photo.png'),
      '/data/user/0/com.logseq.chat/cache/photo.png',
    );
    expect(state.composerDraft, 'Persisted draft');
    expect(state.settings.appearance, 'dark');
    expect(state.settings.language, 'zh-Hans');
    expect(state.settings.spellCheck, isFalse);
    expect(state.settings.autoCorrection, isFalse);
    expect(state.settings.sidebarTabs, ['journals', 'graphs']);
    expect(state.settings.baseUrl, 'https://example.test');
    expect(state.settings.version, '1.2.3');
    expect(state.settings.revision, '42');
    expect(state.settings.hostPayload, {
      'appearance': 'dark',
      'language': 'zh-Hans',
      'spellCheck': false,
      'autoCorrection': false,
      'sidebarTabs': ['journals', 'graphs'],
      'baseURL': 'https://example.test',
      'version': '1.2.3',
      'revision': '42',
    });
    expect(
      state.startupHostUpdates
          .map((update) => (update.kind, update.payload))
          .toList(),
      [
        ('graph-loading', 'true'),
        (
          'settings',
          '{"appearance":"dark","language":"zh-Hans","spellCheck":false,'
              '"autoCorrection":false,"sidebarTabs":["journals","graphs"],'
              '"baseURL":"https://example.test","version":"1.2.3",'
              '"revision":"42"}',
        ),
        ('composer-draft', '"Persisted draft"'),
      ],
    );
  });

  test('restores signed-in state only when a non-empty token exists', () async {
    final signedInAuthentication = _FakeAuthentication(
      restoredToken: 'access-token',
    );
    final signedIn = AndroidPlatformEffects(
      authentication: signedInAuthentication,
    );
    final signedOut = AndroidPlatformEffects(
      authentication: _FakeAuthentication(restoredToken: ''),
    );

    expect(await signedIn.initialAuthenticationCode(), 3);
    expect(await signedOut.initialAuthenticationCode(), 1);
    expect(signedInAuthentication.restoreCalls, 0);
  });

  test('treats stored-session inspection failure as signed out', () async {
    final effects = AndroidPlatformEffects(
      authentication: _FakeAuthentication(
        storedSessionError: StateError('keystore unavailable'),
      ),
    );

    expect(await effects.initialAuthenticationCode(), 1);
  });

  test('surfaces background access-token refresh failures', () async {
    final effects = AndroidPlatformEffects(
      authentication: _FakeAuthentication(restoreError: StateError('expired')),
    );

    expect(effects.restoreAccessToken(), throwsStateError);
  });

  test(
    'sign-in succeeds only when native authentication returns a token',
    () async {
      final authentication = _FakeAuthentication(signInToken: 'new-token');
      final effects = AndroidPlatformEffects(authentication: authentication);

      final result = await effects.execute(
        const NativeEffect(id: 1, kind: 'sign-in', text: ''),
      );

      expect(authentication.signInCalls, 1);
      expect(result.succeeded, isTrue);
      expect(result.output, NativeEffectOutputKind.discard);
    },
  );

  test('empty sign-in token is returned to LG as a failure', () async {
    final effects = AndroidPlatformEffects(
      authentication: _FakeAuthentication(signInToken: ''),
    );

    final result = await effects.execute(
      const NativeEffect(id: 2, kind: 'sign-in', text: ''),
    );

    expect(result.succeeded, isFalse);
    expect(result.message, 'Hosted sign-in did not return an access token');
  });

  test('native sign-in errors are returned to LG', () async {
    final effects = AndroidPlatformEffects(
      authentication: _FakeAuthentication(
        signInError: StateError('custom tab closed'),
      ),
    );

    final result = await effects.execute(
      const NativeEffect(id: 3, kind: 'sign-in', text: ''),
    );

    expect(result.succeeded, isFalse);
    expect(result.message, contains('custom tab closed'));
  });

  test(
    'sign-out clears native authentication and resolves successfully',
    () async {
      final authentication = _FakeAuthentication();
      final effects = AndroidPlatformEffects(authentication: authentication);

      final result = await effects.execute(
        const NativeEffect(id: 4, kind: 'sign-out', text: ''),
      );

      expect(authentication.signOutCalls, 1);
      expect(result.succeeded, isTrue);
      expect(result.output, NativeEffectOutputKind.discard);
    },
  );

  test('unsupported platform effects fail explicitly', () async {
    final effects = AndroidPlatformEffects(
      authentication: _FakeAuthentication(),
    );

    final result = await effects.execute(
      const NativeEffect(id: 5, kind: 'unknown-effect', text: ''),
    );

    expect(result.succeeded, isFalse);
    expect(
      result.message,
      'Unsupported Android platform effect: unknown-effect',
    );
  });

  test(
    'routes persisted state and Android intents through platform services',
    () async {
      final platform = _FakePlatformServices();
      final effects = AndroidPlatformEffects(
        authentication: _FakeAuthentication(),
        platform: platform,
      );

      await effects.execute(
        const NativeEffect(
          id: 6,
          kind: 'persist-composer-draft',
          text: 'Draft',
        ),
      );
      await effects.execute(
        const NativeEffect(
          id: 7,
          kind: 'save-settings',
          text: '{"appearance":"dark"}',
        ),
      );
      final opened = await effects.execute(
        const NativeEffect(
          id: 8,
          kind: 'open-external-url',
          text: 'https://logseq.com',
        ),
      );
      await effects.execute(
        const NativeEffect(
          id: 9,
          kind: 'copy-runtime-log',
          text:
              '[{"timestamp":"12:00","level":"INFO","source":"ui",'
              '"message":"Ready"}]',
        ),
      );

      expect(platform.persistedDraft, 'Draft');
      expect(platform.savedSettings, '{"appearance":"dark"}');
      expect(platform.openedUrl, 'https://logseq.com');
      expect(platform.copiedText, '12:00 INFO ui Ready');
      expect(opened.succeeded, isTrue);
    },
  );

  test('publishes Android runtime log records as a host update', () async {
    final platform = _FakePlatformServices(runtimeLog: '[{"id":"1"}]');
    final effects = AndroidPlatformEffects(
      authentication: _FakeAuthentication(),
      platform: platform,
    );

    final result = await effects.execute(
      const NativeEffect(
        id: 10,
        kind: 'refresh-runtime-log',
        text: 'ui',
        value: 3,
      ),
    );

    expect(platform.runtimeLogSource, 'ui');
    expect(platform.runtimeLogFlags, 3);
    expect(result.output, NativeEffectOutputKind.hostUpdate);
    expect(result.hostUpdateKind, 'runtime-log');
    expect(result.message, '[{"id":"1"}]');
  });
}

final class _FakeAuthentication implements AndroidAuthentication {
  _FakeAuthentication({
    this.restoredToken,
    this.restoreError,
    this.storedSessionError,
    this.signInToken = 'access-token',
    this.signInError,
  });

  final String? restoredToken;
  final Object? restoreError;
  final Object? storedSessionError;
  final String signInToken;
  final Object? signInError;
  int signInCalls = 0;
  int signOutCalls = 0;
  int restoreCalls = 0;

  @override
  Future<bool> hasStoredSession() async {
    if (storedSessionError case final error?) throw error;
    return restoredToken != null && restoredToken!.isNotEmpty;
  }

  @override
  Future<String?> restoreAccessToken() async {
    restoreCalls += 1;
    if (restoreError case final error?) throw error;
    return restoredToken;
  }

  @override
  Future<String> signIn() async {
    signInCalls += 1;
    if (signInError case final error?) throw error;
    return signInToken;
  }

  @override
  Future<void> signOut() async {
    signOutCalls += 1;
  }
}

final class _FakePlatformServices extends AndroidPlatformServices {
  _FakePlatformServices({this.runtimeLog = '[]'});

  final String runtimeLog;
  String? persistedDraft;
  String? savedSettings;
  String? openedUrl;
  String? copiedText;
  String? runtimeLogSource;
  int? runtimeLogFlags;

  @override
  Future<void> copyText(String text) async => copiedText = text;

  @override
  Future<bool> openExternalUrl(String url) async {
    openedUrl = url;
    return true;
  }

  @override
  Future<void> persistComposerDraft(String draft) async {
    persistedDraft = draft;
  }

  @override
  Future<String> refreshRuntimeLog({
    required String source,
    required int flags,
  }) async {
    runtimeLogSource = source;
    runtimeLogFlags = flags;
    return runtimeLog;
  }

  @override
  Future<void> saveSettings(String settings) async {
    savedSettings = settings;
  }
}
