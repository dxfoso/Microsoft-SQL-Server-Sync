import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as path;

import 'agent_page.dart';
import 'live_sync_api.dart';
import 'sync_state.dart';
import 'startup_log.dart';
import 'window_settings.dart';

const String _shellAgentAppVersion = String.fromEnvironment(
  'APP_VERSION',
  defaultValue: '1.0.0+2',
);
const String _shellClientUpdateBaseUrlOverride = String.fromEnvironment(
  'CLIENT_UPDATE_BASE_URL',
  defaultValue: '',
);
const String _shellLiveClientUpdateBaseUrl =
    'https://sync.velvet-leaf.com/client';
const String _shellAgentBuildCommitHash = String.fromEnvironment(
  'BUILD_COMMIT_HASH',
  defaultValue: '',
);
const Duration _shellAutoUpdateRetryCooldown = Duration(minutes: 10);

const List<String> _uiFontFallback = <String>[
  'Segoe UI',
  'Tahoma',
  'Arial',
  'Noto Sans Arabic',
  'Noto Naskh Arabic',
  'sans-serif',
];

TextTheme _withFontFallback(TextTheme theme) {
  return theme.copyWith(
    displayLarge: theme.displayLarge?.copyWith(
      fontFamilyFallback: _uiFontFallback,
    ),
    displayMedium: theme.displayMedium?.copyWith(
      fontFamilyFallback: _uiFontFallback,
    ),
    displaySmall: theme.displaySmall?.copyWith(
      fontFamilyFallback: _uiFontFallback,
    ),
    headlineLarge: theme.headlineLarge?.copyWith(
      fontFamilyFallback: _uiFontFallback,
    ),
    headlineMedium: theme.headlineMedium?.copyWith(
      fontFamilyFallback: _uiFontFallback,
    ),
    headlineSmall: theme.headlineSmall?.copyWith(
      fontFamilyFallback: _uiFontFallback,
    ),
    titleLarge: theme.titleLarge?.copyWith(fontFamilyFallback: _uiFontFallback),
    titleMedium: theme.titleMedium?.copyWith(
      fontFamilyFallback: _uiFontFallback,
    ),
    titleSmall: theme.titleSmall?.copyWith(fontFamilyFallback: _uiFontFallback),
    bodyLarge: theme.bodyLarge?.copyWith(fontFamilyFallback: _uiFontFallback),
    bodyMedium: theme.bodyMedium?.copyWith(fontFamilyFallback: _uiFontFallback),
    bodySmall: theme.bodySmall?.copyWith(fontFamilyFallback: _uiFontFallback),
    labelLarge: theme.labelLarge?.copyWith(fontFamilyFallback: _uiFontFallback),
    labelMedium: theme.labelMedium?.copyWith(
      fontFamilyFallback: _uiFontFallback,
    ),
    labelSmall: theme.labelSmall?.copyWith(fontFamilyFallback: _uiFontFallback),
  );
}

class SyncWindowsAgentApp extends StatefulWidget {
  const SyncWindowsAgentApp({super.key, this.autoLoadOnStart = true});

  final bool autoLoadOnStart;

  @override
  State<SyncWindowsAgentApp> createState() => _SyncWindowsAgentAppState();
}

class _SyncWindowsAgentAppState extends State<SyncWindowsAgentApp> {
  String _clientName = 'Local Agent';
  Map<String, SyncClientState> _syncStatesByClient = {};
  Timer? _saveDebounce;
  final AgentControlPlaneClient _authClient = AgentControlPlaneClient();
  final TextEditingController _usernameController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  String? _authToken;
  String? _accountUsername;
  String? _accountEmail;
  String? _accountName;
  String? _rememberedLoginName;
  String? _rememberedLoginPassword;
  Map<String, String> _selectedDatabasesByUser = <String, String>{};
  String? _lastAutoUpdateTarget;
  String? _lastAutoUpdateAttemptedAt;
  String _serverName = 'localhost';
  String? _loginError;
  ClientUpdateInfo? _shellClientUpdateInfo;
  String? _shellClientUpdateError;
  bool _checkingShellClientUpdate = false;
  bool _applyingShellClientUpdate = false;
  bool _restoringSession = true;
  bool _submittingLogin = false;
  bool _showPassword = false;
  bool _hasOpenedOnce = false;
  bool _startMinimized = false;
  bool _startOnStartup = false;
  bool _didLogFirstBuild = false;
  String? _lastWindowTitle;
  Timer? _clientUpdateCheckTimer;

  static const SyncClientState _defaultClientState = SyncClientState(
    historyLimit: kDefaultHistoryLimit,
    autoSyncIntervalMinutes: kDefaultAutoSyncIntervalMinutes,
    tables: {},
  );

  SyncClientState _stateForClient(String clientName) {
    return _syncStatesByClient[clientName] ?? _defaultClientState;
  }

  String get _windowTitle {
    final name =
        _clientName.trim().isEmpty ? 'Local Agent' : _clientName.trim();
    return 'SQL Sync Agent - $name';
  }

  bool get _hasRememberedLoginCredentials {
    return (_rememberedLoginName?.trim().isNotEmpty ?? false) &&
        (_rememberedLoginPassword?.isNotEmpty ?? false);
  }

  void _applyWindowTitle() {
    final title = _windowTitle;
    if (_lastWindowTitle == title) {
      return;
    }
    _lastWindowTitle = title;
    unawaited(
      WindowsAgentWindowSettings.setWindowTitle(title).catchError((_) {}),
    );
  }

  @override
  void initState() {
    super.initState();
    logStartupEvent('SyncWindowsAgentApp initState');
    if (Platform.isWindows) {
      unawaited(
        WindowsAgentWindowSettings.ensureWatchdogInstalledAndRunning()
            .catchError((Object error, StackTrace _) {
              logStartupEvent('Watchdog ensure failed: $error');
            }),
      );
    }
    _clientUpdateCheckTimer = Timer.periodic(
      const Duration(minutes: 5),
      (_) => unawaited(_checkShellClientUpdate()),
    );
    _loadState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        unawaited(_checkShellClientUpdate());
      }
    });
  }

  void _loadState() {
    try {
      logStartupEvent('SyncWindowsAgentApp loading state');
      final store = SyncAppStateStore.loadSync();
      logStartupEvent('SyncWindowsAgentApp state loaded');
      _authToken = store.authToken?.trim();
      _accountUsername = store.accountUsername?.trim();
      _accountEmail = store.accountEmail?.trim();
      _accountName = store.accountName?.trim();
      _rememberedLoginName =
          store.rememberedLoginName?.trim().isNotEmpty == true
              ? store.rememberedLoginName!.trim()
              : null;
      _rememberedLoginPassword = store.rememberedLoginPassword ?? '';
      _selectedDatabasesByUser = store.selectedDatabasesByUser;
      _lastAutoUpdateTarget =
          store.lastAutoUpdateTarget?.trim().isNotEmpty == true
              ? store.lastAutoUpdateTarget!.trim()
              : null;
      _lastAutoUpdateAttemptedAt =
          store.lastAutoUpdateAttemptedAt?.trim().isNotEmpty == true
              ? store.lastAutoUpdateAttemptedAt!.trim()
              : null;
      _serverName =
          store.server.trim().isNotEmpty ? store.server.trim() : 'localhost';
      _hasOpenedOnce = store.hasOpenedOnce;
      _startMinimized = store.startMinimized;
      _startOnStartup =
          store.startOnStartup ||
          WindowsAgentWindowSettings.isStartOnStartupEnabledSync();
      _usernameController.text = _rememberedLoginName ?? '';
      _passwordController.text = _rememberedLoginPassword ?? '';
      _clientName =
          (_accountName != null && _accountName!.isNotEmpty)
              ? _accountName!
              : (_accountUsername != null && _accountUsername!.isNotEmpty)
              ? _accountUsername!
              : (store.lastClientName.trim().isEmpty
                  ? 'Local Agent'
                  : store.lastClientName.trim());
      _syncStatesByClient = store.clients.isEmpty ? {} : store.clients;
      if (_authToken != null && _authToken!.isNotEmpty) {
        _authClient.setAuthToken(_authToken);
        logStartupEvent('SyncWindowsAgentApp restoring session');
        unawaited(_restoreSession());
      } else if (_hasRememberedLoginCredentials) {
        logStartupEvent('SyncWindowsAgentApp auto login with remembered user');
        unawaited(_loginWithRememberedCredentials());
      } else {
        if (_startMinimized) {
          logStartupEvent(
            'SyncWindowsAgentApp ignoring saved startMinimized on launch to keep the window visible',
          );
        }
        _restoringSession = false;
      }
      if (!_hasOpenedOnce) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            _markFirstLaunchComplete();
          }
        });
      }
      if (_startOnStartup &&
          !WindowsAgentWindowSettings.isStartOnStartupEnabledSync()) {
        unawaited(
          WindowsAgentWindowSettings.setStartOnStartup(true).catchError((_) {}),
        );
      }
    } catch (error, stackTrace) {
      debugPrint('Failed to load Windows agent state: $error');
      _authToken = null;
      _accountUsername = null;
      _accountEmail = null;
      _accountName = null;
      _rememberedLoginName = null;
      _rememberedLoginPassword = '';
      _lastAutoUpdateTarget = null;
      _lastAutoUpdateAttemptedAt = null;
      _hasOpenedOnce = false;
      _startMinimized = false;
      _startOnStartup = false;
      _usernameController.text = '';
      _passwordController.text = '';
      _clientName = 'Local Agent';
      _syncStatesByClient = {};
      _selectedDatabasesByUser = <String, String>{};
      logStartupEvent(
        'SyncWindowsAgentApp load state failed: $error\n$stackTrace',
      );
      _restoringSession = false;
    }
  }

  void _scheduleSave() {
    _saveDebounce?.cancel();
    _saveDebounce = Timer(const Duration(milliseconds: 300), () {
      unawaited(
        _saveState().catchError((error, stackTrace) {
          debugPrint('Failed to save Windows agent state: $error');
        }),
      );
    });
  }

  Future<void> _saveState() async {
    final store = SyncAppStateStore(
      lastClientName: _clientName,
      clients: _syncStatesByClient,
      startMinimized: _startMinimized,
      startOnStartup: _startOnStartup,
      server: _serverName,
      selectedDatabasesByUser: _selectedDatabasesByUser,
      hasOpenedOnce: _hasOpenedOnce,
      authToken: _authToken,
      accountUsername: _accountUsername,
      accountEmail: _accountEmail,
      accountName: _accountName,
      rememberedLoginName: _rememberedLoginName,
      rememberedLoginPassword: _rememberedLoginPassword,
      lastAutoUpdateTarget: _lastAutoUpdateTarget,
      lastAutoUpdateAttemptedAt: _lastAutoUpdateAttemptedAt,
    );
    await store.save();
  }

  Future<void> _saveStateNow() async {
    _saveDebounce?.cancel();
    try {
      await _saveState();
    } catch (error) {
      debugPrint('Failed to save Windows agent state: $error');
    }
  }

  void _markFirstLaunchComplete() {
    if (_hasOpenedOnce) {
      return;
    }

    logStartupEvent('SyncWindowsAgentApp first launch complete');
    setState(() {
      _hasOpenedOnce = true;
    });
    _scheduleSave();
  }

  void _updateClientName(String value) {
    if (_accountUsername != null && _accountUsername!.isNotEmpty) {
      return;
    }
    final nextName = value.trim().isEmpty ? 'Local Agent' : value.trim();
    final previousName = _clientName;
    final currentState =
        _syncStatesByClient[previousName] ?? _defaultClientState;
    setState(() {
      if (previousName != nextName) {
        _syncStatesByClient.remove(previousName);
      }
      _syncStatesByClient[nextName] = currentState;
      _clientName = nextName;
    });
    _scheduleSave();
  }

  void _updateStartMinimized(bool value) {
    if (value == _startMinimized) {
      return;
    }
    setState(() {
      _startMinimized = value;
    });
    _scheduleSave();
  }

  Future<void> _updateStartOnStartup(bool value) async {
    await WindowsAgentWindowSettings.setStartOnStartup(value);
    if (!mounted) {
      return;
    }
    setState(() {
      _startOnStartup = value;
    });
    _scheduleSave();
  }

  void _updateServerName(String value) {
    final normalized = value.trim().isEmpty ? 'localhost' : value.trim();
    if (normalized == _serverName) {
      return;
    }
    setState(() {
      _serverName = normalized;
    });
    _scheduleSave();
  }

  String _databasePreferenceKey() {
    final candidates = <String?>[_accountUsername, _accountEmail, _accountName];
    for (final candidate in candidates) {
      final normalized = candidate?.trim().toLowerCase() ?? '';
      if (normalized.isNotEmpty) {
        return normalized;
      }
    }
    return 'local:${_clientName.trim().toLowerCase()}';
  }

  void _updateSelectedDatabase(String database) {
    final normalized = database.trim();
    final key = _databasePreferenceKey();
    if (normalized.isEmpty || key.isEmpty) {
      return;
    }
    if (_selectedDatabasesByUser[key] == normalized) {
      return;
    }
    setState(() {
      _selectedDatabasesByUser[key] = normalized;
    });
    _scheduleSave();
  }

  Future<void> _minimizeWindow() async {
    await WindowsAgentWindowSettings.minimizeWindow();
  }

  Future<void> _recordAutoUpdateAttempt(String target) async {
    final normalized = target.trim();
    if (normalized.isEmpty) {
      return;
    }
    setState(() {
      _lastAutoUpdateTarget = normalized;
      _lastAutoUpdateAttemptedAt = DateTime.now().toIso8601String();
    });
    await _saveStateNow();
  }

  void _updateSyncStateForClient(SyncClientState state) {
    setState(() {
      _syncStatesByClient[_clientName] = state;
    });
    _scheduleSave();
  }

  @override
  void dispose() {
    _saveDebounce?.cancel();
    _clientUpdateCheckTimer?.cancel();
    _authClient.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  String _shellClientUpdateManifestUrl() {
    final overrideBaseUrl =
        (Platform.environment['CLIENT_UPDATE_BASE_URL'] ??
                _shellClientUpdateBaseUrlOverride)
            .trim();
    if (overrideBaseUrl.isNotEmpty && !_isLocalHttpUrl(overrideBaseUrl)) {
      final normalizedBaseUrl =
          overrideBaseUrl.endsWith('/')
              ? overrideBaseUrl.substring(0, overrideBaseUrl.length - 1)
              : overrideBaseUrl;
      return '$normalizedBaseUrl/latest.json';
    }
    final manifestUrl = _authClient.baseUrl.replaceFirst(
      RegExp(r'/call/?$'),
      '/client/latest.json',
    );
    if (_isLocalHttpUrl(manifestUrl)) {
      return '$_shellLiveClientUpdateBaseUrl/latest.json';
    }
    return manifestUrl;
  }

  bool _isLocalHttpUrl(String value) {
    final uri = Uri.tryParse(value.trim());
    final host = uri?.host.toLowerCase() ?? '';
    return host == 'localhost' ||
        host == '127.0.0.1' ||
        host == '::1' ||
        host == '0.0.0.0' ||
        uri?.port == 6006;
  }

  String _shellClientUpdateScriptUrl(ClientUpdateInfo updateInfo) {
    final scriptUrl = updateInfo.updateScriptUrl.trim();
    if (scriptUrl.isNotEmpty) {
      return scriptUrl;
    }
    return _shellClientUpdateManifestUrl().replaceFirst(
      '/latest.json',
      '/update.ps1',
    );
  }

  String _shellClientUpdateTargetId(ClientUpdateInfo updateInfo) {
    final version = updateInfo.version.trim();
    final commit = updateInfo.commit.trim().toLowerCase();
    final hash = updateInfo.sha256.trim().toLowerCase();
    return [version, commit, hash].where((part) => part.isNotEmpty).join('@');
  }

  bool _hasRecentShellAutoUpdateAttempt(String targetId) {
    final lastTarget = _lastAutoUpdateTarget?.trim() ?? '';
    if (targetId.isEmpty || lastTarget != targetId) {
      return false;
    }

    final attemptedAtRaw = _lastAutoUpdateAttemptedAt?.trim() ?? '';
    if (attemptedAtRaw.isEmpty) {
      return false;
    }

    final attemptedAt = DateTime.tryParse(attemptedAtRaw);
    if (attemptedAt == null) {
      return false;
    }

    return DateTime.now().difference(attemptedAt.toLocal()) <
        _shellAutoUpdateRetryCooldown;
  }

  bool get _supportsShellAutomaticClientUpdate {
    if (!Platform.isWindows) {
      return false;
    }
    final executablePath =
        Platform.resolvedExecutable.replaceAll('/', r'\').toLowerCase();
    return !executablePath.contains(r'\build\windows\x64\runner\debug\');
  }

  bool get _shellHasClientUpdate {
    final updateInfo = _shellClientUpdateInfo;
    if (updateInfo == null) {
      return false;
    }
    final currentVersion = _shellAgentAppVersion.trim();
    final latestVersion = updateInfo.version.trim();
    final currentCommit = _shellAgentBuildCommitHash.trim().toLowerCase();
    final latestCommit = updateInfo.commit.trim().toLowerCase();
    if (latestVersion.isNotEmpty &&
        currentVersion.isNotEmpty &&
        latestVersion != currentVersion) {
      return true;
    }
    if (latestCommit.isNotEmpty && currentCommit.isNotEmpty) {
      return latestCommit != currentCommit;
    }
    return latestVersion.isNotEmpty && latestVersion != currentVersion;
  }

  String _powershellSingleQuoted(String value) => value.replaceAll("'", "''");

  String _shellClientUpdateInstallDir() =>
      File(Platform.resolvedExecutable).parent.path.replaceAll('/', r'\');

  String? _shellLocalClientUpdateScriptPath() {
    final updateScript = File(
      path.join(File(Platform.resolvedExecutable).parent.path, 'update.ps1'),
    );
    if (!updateScript.existsSync()) {
      return null;
    }
    return updateScript.path.replaceAll('/', r'\');
  }

  List<String> _shellClientUpdatePowerShellArgs(ClientUpdateInfo updateInfo) {
    final manifestUrl = _shellClientUpdateManifestUrl();
    final scriptUrl = _shellClientUpdateScriptUrl(updateInfo);
    final installDir = _shellClientUpdateInstallDir();
    final localScriptPath = _shellLocalClientUpdateScriptPath();
    if (scriptUrl.isNotEmpty) {
      return <String>[
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-WindowStyle',
        'Hidden',
        '-Command',
        "& ([scriptblock]::Create((Invoke-WebRequest -UseBasicParsing "
            "-Uri '${_powershellSingleQuoted(scriptUrl)}').Content)) "
            "-ManifestUrl '${_powershellSingleQuoted(manifestUrl)}' "
            "-InstallDir '${_powershellSingleQuoted(installDir)}'",
      ];
    }
    if (localScriptPath != null) {
      return <String>[
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-WindowStyle',
        'Hidden',
        '-File',
        localScriptPath,
        '-ManifestUrl',
        manifestUrl,
        '-InstallDir',
        installDir,
      ];
    }
    return <String>[
      '-NoProfile',
      '-ExecutionPolicy',
      'Bypass',
      '-WindowStyle',
      'Hidden',
      '-Command',
      "& ([scriptblock]::Create((Invoke-WebRequest -UseBasicParsing "
          "-Uri '${_powershellSingleQuoted(scriptUrl)}').Content)) "
          "-ManifestUrl '${_powershellSingleQuoted(manifestUrl)}' "
          "-InstallDir '${_powershellSingleQuoted(installDir)}'",
    ];
  }

  Future<void> _checkShellClientUpdate() async {
    if (!mounted ||
        _checkingShellClientUpdate ||
        _applyingShellClientUpdate) {
      return;
    }

    setState(() {
      _checkingShellClientUpdate = true;
      _shellClientUpdateError = null;
    });

    try {
      final manifestUrl = _shellClientUpdateManifestUrl();
      logStartupEvent('Checking shell client update manifest: $manifestUrl');
      final updateInfo = await _authClient.fetchClientUpdateInfo(
        manifestUrl: manifestUrl,
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _shellClientUpdateInfo = updateInfo;
        _checkingShellClientUpdate = false;
      });
      if (updateInfo != null) {
        logStartupEvent(
          'Shell client update manifest loaded: version=${updateInfo.version} '
          'commit=${updateInfo.commit}',
        );
        unawaited(_maybeAutoApplyShellClientUpdate(updateInfo));
      } else {
        logStartupEvent('Shell client update manifest returned no payload.');
      }
    } catch (error) {
      logStartupEvent('Shell client update check failed: $error');
      if (!mounted) {
        return;
      }
      setState(() {
        _checkingShellClientUpdate = false;
        _shellClientUpdateError = error.toString();
      });
    }
  }

  Future<void> _maybeAutoApplyShellClientUpdate(
    ClientUpdateInfo updateInfo, {
    bool force = false,
  }) async {
    if (!mounted ||
        !_shellHasClientUpdate ||
        !_supportsShellAutomaticClientUpdate ||
        _applyingShellClientUpdate ||
        _submittingLogin) {
      return;
    }

    final targetId = _shellClientUpdateTargetId(updateInfo);
    if (targetId.isEmpty) {
      return;
    }
    if (!force && _hasRecentShellAutoUpdateAttempt(targetId)) {
      return;
    }

    final manifestUrl = _shellClientUpdateManifestUrl();
    final psArgs = _shellClientUpdatePowerShellArgs(updateInfo);

    try {
      setState(() {
        _applyingShellClientUpdate = true;
        _shellClientUpdateError = null;
      });
      await _recordAutoUpdateAttempt(targetId);
      logStartupEvent(
        'Applying shell client update automatically: $targetId from $manifestUrl force=$force',
      );
      // Launch PowerShell directly so a successful cmd.exe start cannot hide
      // a failed updater process from the client.
      await Process.start(
        'powershell.exe',
        psArgs,
        mode: ProcessStartMode.detached,
      );
      await Future<void>.delayed(const Duration(milliseconds: 750));
      if (mounted) {
        exit(0);
      }
    } catch (error) {
      logStartupEvent('Shell automatic client update failed: $error');
      if (!mounted) {
        return;
      }
      setState(() {
        _applyingShellClientUpdate = false;
        _shellClientUpdateError = error.toString();
      });
    }
  }

  void _migrateStoredClientState(String fromClientName, String toClientName) {
    final fromKey = fromClientName.trim();
    final toKey = toClientName.trim();
    if (fromKey.isEmpty || toKey.isEmpty || fromKey == toKey) {
      return;
    }

    final existing = _syncStatesByClient[fromKey];
    if (existing == null || _syncStatesByClient.containsKey(toKey)) {
      return;
    }

    _syncStatesByClient = {
      for (final entry in _syncStatesByClient.entries)
        if (entry.key != fromKey) entry.key: entry.value,
      toKey: existing,
    };
  }

  Future<void> _restoreSession() async {
    try {
      logStartupEvent('SyncWindowsAgentApp fetchCurrentUser start');
      final user = await _authClient.fetchCurrentUser().timeout(
        const Duration(seconds: 8),
      );
      if (!mounted) {
        return;
      }
      logStartupEvent('SyncWindowsAgentApp fetchCurrentUser success');
      setState(() {
        _migrateStoredClientState(_clientName, user.name);
        _authToken = user.token;
        _accountUsername = user.username;
        _accountEmail = user.email;
        _accountName = user.name;
        _clientName = user.name;
        _restoringSession = false;
        _loginError = null;
      });
      _scheduleSave();
    } on TimeoutException catch (_) {
      logStartupEvent('SyncWindowsAgentApp fetchCurrentUser timeout');
      if (!mounted) {
        return;
      }
      if (_hasRememberedLoginCredentials) {
        setState(() {
          _authToken = null;
          _accountUsername = null;
          _accountEmail = null;
          _accountName = null;
          _clientName = _rememberedLoginName!.trim();
          _restoringSession = true;
          _submittingLogin = true;
          _loginError = null;
        });
        _authClient.setAuthToken(null);
        unawaited(_loginWithRememberedCredentials());
        return;
      }
      setState(() {
        _authToken = null;
        _accountUsername = null;
        _accountEmail = null;
        _accountName = null;
        _clientName = 'Local Agent';
        _restoringSession = false;
      });
      _authClient.setAuthToken(null);
      _scheduleSave();
    } catch (_) {
      logStartupEvent('SyncWindowsAgentApp fetchCurrentUser failed');
      if (!mounted) {
        return;
      }
      if (_hasRememberedLoginCredentials) {
        setState(() {
          _authToken = null;
          _accountUsername = null;
          _accountEmail = null;
          _accountName = null;
          _clientName = _rememberedLoginName!.trim();
          _restoringSession = true;
          _submittingLogin = true;
          _loginError = null;
        });
        _authClient.setAuthToken(null);
        unawaited(_loginWithRememberedCredentials());
        return;
      }
      setState(() {
        _authToken = null;
        _accountUsername = null;
        _accountEmail = null;
        _accountName = null;
        _clientName = 'Local Agent';
        _restoringSession = false;
      });
      _authClient.setAuthToken(null);
      _scheduleSave();
    }
  }

  Future<void> _loginWithRememberedCredentials() async {
    final name = _rememberedLoginName?.trim();
    final password = _rememberedLoginPassword ?? '';
    if (name == null || name.isEmpty || password.isEmpty) {
      if (!mounted) {
        return;
      }
      setState(() {
        _restoringSession = false;
        _submittingLogin = false;
      });
      return;
    }

    _usernameController.text = name;
    _passwordController.text = password;
    if (mounted && !_submittingLogin) {
      setState(() {
        _submittingLogin = true;
        _loginError = null;
      });
    }

    try {
      logStartupEvent('SyncWindowsAgentApp remembered login start');
      final user = await _authClient.loginClient(
        name: name,
        password: password,
      );
      if (!mounted) {
        return;
      }
      logStartupEvent('SyncWindowsAgentApp remembered login success');
      setState(() {
        _migrateStoredClientState(_clientName, user.name);
        _authToken = user.token;
        _accountUsername = user.username;
        _accountEmail = user.email;
        _accountName = user.name;
        _rememberedLoginName = name;
        _rememberedLoginPassword = password;
        _clientName = user.name;
        _restoringSession = false;
        _submittingLogin = false;
        _loginError = null;
      });
      await _saveStateNow();
    } catch (error) {
      logStartupEvent('SyncWindowsAgentApp remembered login failed: $error');
      if (!mounted) {
        return;
      }
      _authClient.setAuthToken(null);
      setState(() {
        _authToken = null;
        _accountUsername = null;
        _accountEmail = null;
        _accountName = null;
        _clientName = 'Local Agent';
        _restoringSession = false;
        _submittingLogin = false;
        _loginError = 'Automatic login failed. Please sign in again.';
        _usernameController.text = name;
        _passwordController.text = password;
      });
      _scheduleSave();
    }
  }

  Future<void> _handleLogin() async {
    final name = _usernameController.text.trim();
    final password = _passwordController.text;
    if (name.isEmpty || password.isEmpty) {
      setState(() {
        _loginError = 'Name and password are required.';
      });
      return;
    }

    setState(() {
      _submittingLogin = true;
      _loginError = null;
    });

    try {
      final user = await _authClient.loginClient(
        name: name,
        password: password,
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _migrateStoredClientState(_clientName, user.name);
        _authToken = user.token;
        _accountUsername = user.username;
        _accountEmail = user.email;
        _accountName = user.name;
        _rememberedLoginName = name;
        _rememberedLoginPassword = password;
        _clientName = user.name;
        _submittingLogin = false;
        _loginError = null;
      });
      await _saveStateNow();
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _submittingLogin = false;
        _loginError = error.toString();
      });
    }
  }

  void _handleLogout() {
    unawaited(_authClient.logout().catchError((_) {}));
    _authClient.setAuthToken(null);
    setState(() {
      _authToken = null;
      _accountUsername = null;
      _accountEmail = null;
      _accountName = null;
      _clientName = 'Local Agent';
      _loginError = null;
      _usernameController.text = _rememberedLoginName ?? '';
      _passwordController.text = _rememberedLoginPassword ?? '';
    });
    _scheduleSave();
    unawaited(_checkShellClientUpdate());
  }

  Widget _buildLoginShell() {
    return Scaffold(
      body: LayoutBuilder(
        builder: (context, constraints) {
          final width =
              constraints.maxWidth.isFinite
                  ? constraints.maxWidth
                  : MediaQuery.sizeOf(context).width;
          final tight = width < 480;
          final outerPadding = tight ? 16.0 : 24.0;
          final formPadding = tight ? 20.0 : 26.0;

          return Container(
            width: double.infinity,
            color: const Color(0xFFF6F7F9),
            child: SafeArea(
              child: SingleChildScrollView(
                padding: EdgeInsets.all(outerPadding),
                child: Center(
                  child: ConstrainedBox(
                    constraints: BoxConstraints(maxWidth: tight ? width : 408),
                    child: Container(
                      padding: EdgeInsets.all(formPadding),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: const Color(0xFFDDE3EA)),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Client Login',
                            style: TextStyle(
                              fontSize: 26,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          const SizedBox(height: 8),
                          const Text(
                            'Client accounts only.',
                            style: TextStyle(
                              color: Color(0xFF667085),
                              fontSize: 14,
                              height: 1.35,
                            ),
                          ),
                          if (_applyingShellClientUpdate) ...[
                            const SizedBox(height: 12),
                            Container(
                              width: double.infinity,
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: const Color(0xFFECFDF3),
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(
                                  color: const Color(0xFFA6F4C5),
                                ),
                              ),
                              child: const Text(
                                'Installing the latest client update. The agent will restart automatically.',
                                style: TextStyle(
                                  color: Color(0xFF067647),
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                          ] else if (_shellHasClientUpdate &&
                              _shellClientUpdateInfo != null) ...[
                            const SizedBox(height: 12),
                            Container(
                              width: double.infinity,
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: const Color(0xFFFFFAEB),
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(
                                  color: const Color(0xFFFEC84B),
                                ),
                              ),
                              child: Text(
                                'Client update v${_shellClientUpdateInfo!.version} is available. The agent will install it automatically.',
                                style: const TextStyle(
                                  color: Color(0xFFB54708),
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                          ] else if (_shellClientUpdateError != null) ...[
                            const SizedBox(height: 12),
                            Text(
                              'Update check failed: $_shellClientUpdateError',
                              style: const TextStyle(
                                color: Color(0xFFB42318),
                                fontSize: 12,
                              ),
                            ),
                          ],
                          const SizedBox(height: 22),
                          TextField(
                            controller: _usernameController,
                            textInputAction: TextInputAction.next,
                            decoration: const InputDecoration(
                              labelText: 'Name',
                              hintText: 'client-name',
                            ),
                          ),
                          const SizedBox(height: 12),
                          TextField(
                            controller: _passwordController,
                            obscureText: !_showPassword,
                            enableSuggestions: false,
                            autocorrect: false,
                            onSubmitted: (_) => unawaited(_handleLogin()),
                            decoration: InputDecoration(
                              labelText: 'Password',
                              suffixIcon: IconButton(
                                tooltip:
                                    _showPassword
                                        ? 'Hide password'
                                        : 'Show password',
                                onPressed: () {
                                  setState(() {
                                    _showPassword = !_showPassword;
                                  });
                                },
                                icon: Icon(
                                  _showPassword
                                      ? Icons.visibility_off_outlined
                                      : Icons.visibility_outlined,
                                ),
                              ),
                            ),
                          ),
                          if (_loginError != null) ...[
                            const SizedBox(height: 12),
                            Container(
                              width: double.infinity,
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: const Color(0xFFFFF0EE),
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(
                                  color: const Color(0xFFF7C9C4),
                                ),
                              ),
                              child: Text(
                                _loginError!,
                                style: const TextStyle(
                                  color: Color(0xFFB5422A),
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                          ],
                          const SizedBox(height: 18),
                          SizedBox(
                            width: double.infinity,
                            child: FilledButton(
                              onPressed:
                                  _submittingLogin
                                      ? null
                                      : () => unawaited(_handleLogin()),
                              child: Text(
                                _submittingLogin
                                    ? 'Signing In...'
                                    : 'Open Agent',
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!_didLogFirstBuild) {
      _didLogFirstBuild = true;
      logStartupEvent(
        'SyncWindowsAgentApp build: restoringSession=$_restoringSession auth=${_authToken != null && _authToken!.isNotEmpty} hasOpenedOnce=$_hasOpenedOnce startMinimized=$_startMinimized',
      );
    }
    _applyWindowTitle();

    const shell = Color(0xFFF6F7F9);
    const ink = Color(0xFF101828);
    const primary = Color(0xFF0F766E);
    const accent = Color(0xFFE0A32A);
    const border = Color(0xFFDDE3EA);
    final appTitle = _windowTitle;

    final textTheme = _withFontFallback(
      ThemeData.light().textTheme.apply(bodyColor: ink, displayColor: ink),
    );

    return MaterialApp(
      title: appTitle,
      debugShowCheckedModeBanner: false,
      builder: (context, child) {
        return Title(
          title: appTitle,
          color: shell,
          child: child ?? const SizedBox.shrink(),
        );
      },
      theme: ThemeData(
        useMaterial3: true,
        scaffoldBackgroundColor: shell,
        colorScheme: const ColorScheme.light(
          primary: primary,
          secondary: accent,
          surface: Colors.white,
          onSurface: ink,
        ),
        textTheme: textTheme,
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            backgroundColor: primary,
            foregroundColor: Colors.white,
            minimumSize: const Size(0, 40),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
          ),
        ),
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(
            foregroundColor: ink,
            minimumSize: const Size(0, 38),
            side: const BorderSide(color: border),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
          ),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: Colors.white,
          isDense: true,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: const BorderSide(color: border),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: const BorderSide(color: border),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: const BorderSide(color: primary, width: 1.2),
          ),
          labelStyle: const TextStyle(color: Color(0xFF667085)),
          hintStyle: const TextStyle(color: Color(0xFF98A2B3)),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 12,
            vertical: 12,
          ),
        ),
        dividerTheme: const DividerThemeData(
          color: Color(0xFFE4E7EC),
          thickness: 1,
        ),
      ),
      home:
          _restoringSession
              ? const Scaffold(body: Center(child: CircularProgressIndicator()))
              : (_authToken == null ||
                  _authToken!.isEmpty ||
                  _accountUsername == null ||
                  _accountUsername!.isEmpty)
              ? _buildLoginShell()
              : AgentDashboardPage(
                authToken: _authToken!,
                authenticatedAccountUsername: _accountUsername,
                authenticatedAccountEmail: _accountEmail,
                authenticatedAccountName: _accountName,
                onLogout: _handleLogout,
                clientNameLocked: true,
                autoLoadOnStart: widget.autoLoadOnStart,
                clientName: _clientName,
                onClientNameChanged: _updateClientName,
                initialSyncState: _stateForClient(_clientName),
                onSyncStateChanged: _updateSyncStateForClient,
                startMinimized: _startMinimized,
                startOnStartup: _startOnStartup,
                onStartMinimizedChanged: _updateStartMinimized,
                onStartOnStartupChanged: _updateStartOnStartup,
                onMinimizeWindow: _minimizeWindow,
                initialServer: _serverName,
                onServerChanged: _updateServerName,
                initialDatabase:
                    _selectedDatabasesByUser[_databasePreferenceKey()],
                onDatabaseChanged: _updateSelectedDatabase,
                lastAutoUpdateTarget: _lastAutoUpdateTarget,
                lastAutoUpdateAttemptedAt: _lastAutoUpdateAttemptedAt,
                onAutoUpdateAttempted: _recordAutoUpdateAttempt,
              ),
    );
  }
}
