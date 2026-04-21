import 'dart:async';

import 'package:flutter/material.dart';

import 'agent_page.dart';
import 'live_sync_api.dart';
import 'sync_state.dart';

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
  String? _loginError;
  bool _restoringSession = true;
  bool _submittingLogin = false;
  bool _showPassword = false;

  static const SyncClientState _defaultClientState = SyncClientState(
    isMaster: true,
    historyLimit: kDefaultHistoryLimit,
    tables: {},
  );

  SyncClientState _stateForClient(String clientName) {
    return _syncStatesByClient[clientName] ?? _defaultClientState;
  }

  @override
  void initState() {
    super.initState();
    _loadState();
  }

  void _loadState() {
    final store = SyncAppStateStore.loadSync();
    _authToken = store.authToken?.trim();
    _accountUsername = store.accountUsername?.trim();
    _accountEmail = store.accountEmail?.trim();
    _accountName = store.accountName?.trim();
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
      unawaited(_restoreSession());
    } else {
      _restoringSession = false;
    }
  }

  void _scheduleSave() {
    _saveDebounce?.cancel();
    _saveDebounce = Timer(const Duration(milliseconds: 300), _saveState);
  }

  Future<void> _saveState() async {
    final store = SyncAppStateStore(
      lastClientName: _clientName,
      clients: _syncStatesByClient,
      authToken: _authToken,
      accountUsername: _accountUsername,
      accountEmail: _accountEmail,
      accountName: _accountName,
    );
    await store.save();
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
      final user = await _authClient.fetchCurrentUser();
      if (!mounted) {
        return;
      }
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
    } catch (_) {
      if (!mounted) {
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
        _clientName = user.name;
        _submittingLogin = false;
        _loginError = null;
        _passwordController.clear();
      });
      _scheduleSave();
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
      _passwordController.clear();
    });
    _scheduleSave();
  }

  Widget _buildLoginShell() {
    return Scaffold(
      body: Container(
        width: double.infinity,
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [Color(0xFFF2F1ED), Color(0xFFE2ECE9), Color(0xFFF5E3BE)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 960),
              child: Wrap(
                spacing: 24,
                runSpacing: 24,
                alignment: WrapAlignment.center,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 480),
                    child: Container(
                      padding: const EdgeInsets.all(28),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(30),
                        gradient: const LinearGradient(
                          colors: [
                            Color(0xFF143842),
                            Color(0xFF1E6674),
                            Color(0xFFD8A23A),
                          ],
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                        ),
                      ),
                      child: const Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'SQL Sync Windows Agent',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 30,
                              fontWeight: FontWeight.w800,
                              height: 1.05,
                            ),
                          ),
                          SizedBox(height: 14),
                          Text(
                            'Sign in with a client account. Owner and admin accounts are blocked here and work only on the website.',
                            style: TextStyle(
                              color: Colors.white70,
                              fontSize: 15,
                              height: 1.5,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 400),
                    child: Container(
                      padding: const EdgeInsets.all(28),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(28),
                        boxShadow: const [
                          BoxShadow(
                            color: Color(0x12000000),
                            blurRadius: 28,
                            offset: Offset(0, 16),
                          ),
                        ],
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Client Login',
                            style: TextStyle(
                              fontSize: 24,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          const SizedBox(height: 8),
                          const Text(
                            'Use a client account created on the website by dxfoso or by your owner account.',
                            style: TextStyle(
                              color: Color(0xFF58656B),
                              height: 1.45,
                            ),
                          ),
                          const SizedBox(height: 20),
                          TextField(
                            controller: _usernameController,
                            textInputAction: TextInputAction.next,
                            decoration: const InputDecoration(
                              labelText: 'Name',
                            ),
                          ),
                          const SizedBox(height: 14),
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
                            const SizedBox(height: 14),
                            Text(
                              _loginError!,
                              style: const TextStyle(
                                color: Color(0xFFC53030),
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ],
                          const SizedBox(height: 20),
                          SizedBox(
                            width: double.infinity,
                            child: FilledButton(
                              onPressed:
                                  _submittingLogin
                                      ? null
                                      : () => unawaited(_handleLogin()),
                              child: Text(
                                _submittingLogin ? 'Signing In...' : 'Sign In',
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
  }

  @override
  Widget build(BuildContext context) {
    const mist = Color(0xFFF2F1ED);
    const ink = Color(0xFF17313A);
    const teal = Color(0xFF1E6674);
    final appTitle =
        _clientName == 'Local Agent' ? 'SQL Sync Agent' : _clientName;

    return MaterialApp(
      title: appTitle,
      debugShowCheckedModeBanner: false,
      builder: (context, child) {
        return Title(
          title: appTitle,
          color: mist,
          child: child ?? const SizedBox.shrink(),
        );
      },
      theme: ThemeData(
        useMaterial3: true,
        scaffoldBackgroundColor: mist,
        colorScheme: ColorScheme.fromSeed(
          seedColor: teal,
          brightness: Brightness.light,
          primary: teal,
          secondary: const Color(0xFFD8A23A),
          surface: Colors.white,
        ),
        textTheme: ThemeData.light().textTheme.apply(
          bodyColor: ink,
          displayColor: ink,
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: Colors.white,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(18),
            borderSide: BorderSide.none,
          ),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 18,
            vertical: 16,
          ),
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
              ),
    );
  }
}
