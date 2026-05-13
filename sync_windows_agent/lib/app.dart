import 'dart:async';

import 'package:flutter/material.dart';

import 'agent_page.dart';
import 'live_sync_api.dart';
import 'sync_state.dart';
import 'startup_log.dart';
import 'window_settings.dart';

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
  String _serverName = 'localhost';
  String? _loginError;
  bool _restoringSession = true;
  bool _submittingLogin = false;
  bool _showPassword = false;
  bool _hasOpenedOnce = false;
  bool _startMinimized = false;
  bool _startOnStartup = false;
  bool _didLogFirstBuild = false;
  String? _lastWindowTitle;

  static const SyncClientState _defaultClientState = SyncClientState(
    isMaster: true,
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
    _loadState();
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
      _hasOpenedOnce = false;
      _startMinimized = false;
      _startOnStartup = false;
      _usernameController.text = '';
      _passwordController.text = '';
      _clientName = 'Local Agent';
      _syncStatesByClient = {};
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
      hasOpenedOnce: _hasOpenedOnce,
      authToken: _authToken,
      accountUsername: _accountUsername,
      accountEmail: _accountEmail,
      accountName: _accountName,
      rememberedLoginName: _rememberedLoginName,
      rememberedLoginPassword: _rememberedLoginPassword,
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

  Future<void> _minimizeWindow() async {
    await WindowsAgentWindowSettings.minimizeWindow();
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
    _authClient.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    super.dispose();
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
        _accountUsername = user.name;
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
        _accountUsername = user.name;
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
        _accountUsername = user.name;
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
  }

  Widget _buildLoginShell() {
    return Scaffold(
      body: LayoutBuilder(
        builder: (context, constraints) {
          final width =
              constraints.maxWidth.isFinite
                  ? constraints.maxWidth
                  : MediaQuery.sizeOf(context).width;
          final compact = width < 760;
          final tight = width < 480;
          final heroFontSize = tight ? 24.0 : (compact ? 28.0 : 34.0);
          final outerPadding = tight ? 16.0 : 24.0;
          final heroPadding = tight ? 22.0 : 32.0;
          final formPadding = tight ? 20.0 : 26.0;

          return Container(
            width: double.infinity,
            color: const Color(0xFFF6F7F9),
            child: SafeArea(
              child: SingleChildScrollView(
                padding: EdgeInsets.all(outerPadding),
                child: Center(
                  child: ConstrainedBox(
                    constraints: BoxConstraints(maxWidth: compact ? 560 : 1080),
                    child: Wrap(
                      spacing: 24,
                      runSpacing: 24,
                      alignment:
                          compact ? WrapAlignment.start : WrapAlignment.center,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 560),
                          child: Container(
                            padding: EdgeInsets.all(heroPadding),
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(
                                color: const Color(0xFFDDE3EA),
                              ),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const _AgentHeroTag(label: 'Windows SQL Agent'),
                                const SizedBox(height: 22),
                                Text(
                                  'Run the local sync agent and open data only when needed.',
                                  style: TextStyle(
                                    color: const Color(0xFF101828),
                                    fontSize: heroFontSize,
                                    fontWeight: FontWeight.w800,
                                    height: 1.06,
                                  ),
                                ),
                                const SizedBox(height: 10),
                                const Text(
                                  'Client accounts only. Owner and admin accounts stay on the website.',
                                  style: TextStyle(
                                    color: Color(0xFF667085),
                                    fontSize: 14.5,
                                    height: 1.35,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                        ConstrainedBox(
                          constraints: BoxConstraints(
                            maxWidth: compact ? 560 : 408,
                          ),
                          child: Container(
                            padding: EdgeInsets.all(formPadding),
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(
                                color: const Color(0xFFDDE3EA),
                              ),
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
                      ],
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
        textTheme: ThemeData.light().textTheme.apply(
          bodyColor: ink,
          displayColor: ink,
        ),
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
              ),
    );
  }
}

class _AgentHeroTag extends StatelessWidget {
  const _AgentHeroTag({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        color: const Color(0xFFE6F4F1),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFB7DDD7)),
      ),
      child: Text(
        label,
        style: const TextStyle(
          color: Color(0xFF0F766E),
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}
