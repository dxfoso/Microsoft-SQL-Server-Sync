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
        color: const Color(0xFFF3F5F7),
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1080),
              child: Wrap(
                spacing: 24,
                runSpacing: 24,
                alignment: WrapAlignment.center,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 560),
                    child: Container(
                      padding: const EdgeInsets.all(32),
                      decoration: BoxDecoration(
                        color: const Color(0xFF142630),
                        borderRadius: BorderRadius.circular(28),
                        border: Border.all(color: const Color(0xFF223A49)),
                      ),
                      child: const Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _AgentHeroTag(label: 'Windows SQL Agent'),
                          SizedBox(height: 22),
                          Text(
                            'Run a compact desktop sync console that keeps SQL credentials local and only ships snapshots through the control plane.',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 34,
                              fontWeight: FontWeight.w800,
                              height: 1.02,
                            ),
                          ),
                          SizedBox(height: 14),
                          Text(
                            'Client accounts sign in here, load local table metadata, and open current data or saved history snapshots from focused dialogs.',
                            style: TextStyle(
                              color: Color(0xFFB7C5CE),
                              fontSize: 14.5,
                              height: 1.5,
                            ),
                          ),
                          SizedBox(height: 22),
                          Wrap(
                            spacing: 10,
                            runSpacing: 10,
                            children: [
                              _AgentHeroPill(label: 'Flat compact UI'),
                              _AgentHeroPill(label: 'Local SQL only'),
                              _AgentHeroPill(label: 'History snapshot dialogs'),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 408),
                    child: Container(
                      padding: const EdgeInsets.all(26),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(30),
                        border: Border.all(color: const Color(0xFFD8E0E5)),
                        boxShadow: const [
                          BoxShadow(
                            color: Color(0x0F14212B),
                            blurRadius: 30,
                            offset: Offset(0, 12),
                          ),
                        ],
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
                            'Owner and admin accounts are blocked here and stay on the website.',
                            style: TextStyle(
                              color: Color(0xFF62717C),
                              fontSize: 14,
                              height: 1.5,
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
                                borderRadius: BorderRadius.circular(14),
                                border: Border.all(
                                  color: const Color(0xFFF2C5BE),
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
  }

  @override
  Widget build(BuildContext context) {
    const shell = Color(0xFFF3F5F7);
    const ink = Color(0xFF14212B);
    const teal = Color(0xFF1E6674);
    const accent = Color(0xFFEEA63A);
    final appTitle =
        _clientName == 'Local Agent' ? 'SQL Sync Agent' : _clientName;

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
          primary: teal,
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
            backgroundColor: teal,
            foregroundColor: Colors.white,
            minimumSize: const Size(0, 44),
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
            ),
          ),
        ),
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(
            foregroundColor: ink,
            minimumSize: const Size(0, 40),
            side: const BorderSide(color: Color(0xFFD9E0E5)),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
            ),
          ),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: Colors.white,
          isDense: true,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: const BorderSide(color: Color(0xFFD7DEE3)),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: const BorderSide(color: Color(0xFFD7DEE3)),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: const BorderSide(color: teal, width: 1.2),
          ),
          labelStyle: const TextStyle(color: Color(0xFF74818A)),
          hintStyle: const TextStyle(color: Color(0xFF94A1AA)),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 14,
            vertical: 14,
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

class _AgentHeroTag extends StatelessWidget {
  const _AgentHeroTag({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        color: const Color(0xFF213643),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: const Color(0xFF314855)),
      ),
      child: Text(
        label,
        style: const TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.2,
        ),
      ),
    );
  }
}

class _AgentHeroPill extends StatelessWidget {
  const _AgentHeroPill({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFF1E313D),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: const Color(0xFF304853)),
      ),
      child: Text(
        label,
        style: const TextStyle(
          color: Color(0xFFD5E0E6),
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}
