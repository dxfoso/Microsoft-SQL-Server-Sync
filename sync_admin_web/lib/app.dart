import 'dart:async';

import 'package:flutter/material.dart';

import 'browser_bridge.dart';
import 'dashboard_page.dart';
import 'live_sync_api.dart';
import 'models.dart';

const String _websiteSessionTokenKey = 'sync_admin_web.auth_token';

class SyncAdminApp extends StatelessWidget {
  const SyncAdminApp({super.key});

  @override
  Widget build(BuildContext context) {
    const sand = Color(0xFFF6F7F3);
    const ink = Color(0xFF18212B);
    const teal = Color(0xFF2B6F73);

    return MaterialApp(
      title: 'SQL Sync Control Plane',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        scaffoldBackgroundColor: sand,
        colorScheme: ColorScheme.fromSeed(
          seedColor: teal,
          brightness: Brightness.light,
          primary: const Color(0xFF20313C),
          secondary: teal,
          surface: Colors.white,
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.white,
          foregroundColor: ink,
          elevation: 0,
          scrolledUnderElevation: 0,
          centerTitle: false,
        ),
        cardTheme: CardThemeData(
          color: Colors.white,
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(24),
            side: const BorderSide(color: Color(0xFFE5E9E2)),
          ),
        ),
        textTheme: ThemeData.light().textTheme.apply(
          bodyColor: ink,
          displayColor: ink,
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: const Color(0xFFFAFBF8),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
            borderSide: const BorderSide(color: Color(0xFFE1E6DD)),
          ),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 18,
            vertical: 16,
          ),
        ),
      ),
      home: const _WebsiteShell(),
    );
  }
}

class _WebsiteShell extends StatefulWidget {
  const _WebsiteShell();

  @override
  State<_WebsiteShell> createState() => _WebsiteShellState();
}

class _WebsiteShellState extends State<_WebsiteShell> {
  final LiveSyncApiClient _api = LiveSyncApiClient();
  final TextEditingController _usernameController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();

  AuthenticatedUser? _activeUser;
  String? _authToken;
  String? _error;
  bool _restoringSession = true;
  bool _submitting = false;

  @override
  void initState() {
    super.initState();
    _restoreSession();
  }

  @override
  void dispose() {
    _api.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _restoreSession() async {
    final token = readBrowserStorage(_websiteSessionTokenKey)?.trim();
    if (token == null || token.isEmpty) {
      if (!mounted) {
        return;
      }
      setState(() {
        _restoringSession = false;
      });
      return;
    }

    _api.setAuthToken(token);
    try {
      final user = await _api.fetchCurrentUser();
      if (!mounted) {
        return;
      }
      setState(() {
        _authToken = token;
        _activeUser = user;
        _restoringSession = false;
        _error = null;
      });
    } catch (_) {
      removeBrowserStorage(_websiteSessionTokenKey);
      _api.setAuthToken(null);
      if (!mounted) {
        return;
      }
      setState(() {
        _authToken = null;
        _activeUser = null;
        _restoringSession = false;
      });
    }
  }

  Future<void> _handleLogin() async {
    final username = _usernameController.text.trim();
    final password = _passwordController.text;
    if (username.isEmpty || password.isEmpty) {
      setState(() {
        _error = 'Username and password are required.';
      });
      return;
    }

    setState(() {
      _submitting = true;
      _error = null;
    });

    try {
      final result = await _api.loginWeb(
        username: username,
        password: password,
      );
      writeBrowserStorage(_websiteSessionTokenKey, result.token);
      if (!mounted) {
        return;
      }
      setState(() {
        _authToken = result.token;
        _activeUser = result.user;
        _error = null;
        _submitting = false;
        _passwordController.clear();
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _error = error.toString();
        _submitting = false;
      });
    }
  }

  void _handleLogout() {
    final token = _authToken;
    removeBrowserStorage(_websiteSessionTokenKey);
    _api.setAuthToken(null);
    setState(() {
      _authToken = null;
      _activeUser = null;
      _error = null;
      _passwordController.clear();
    });
    if (token != null && token.isNotEmpty) {
      _api.setAuthToken(token);
      unawaited(_api.logout().catchError((_) {}));
      _api.setAuthToken(null);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_restoringSession) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    if (_activeUser != null && _authToken != null) {
      return AdminDashboardPage(
        authenticatedUser: _activeUser!,
        authToken: _authToken!,
        onLogout: _handleLogout,
      );
    }

    return Scaffold(
      body: Container(
        width: double.infinity,
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [Color(0xFFF6F7F3), Color(0xFFE8F0EC), Color(0xFFF7E9CC)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1040),
              child: Wrap(
                spacing: 24,
                runSpacing: 24,
                alignment: WrapAlignment.center,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 520),
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
                            'SQL Sync Control Plane',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 32,
                              fontWeight: FontWeight.w800,
                              height: 1.05,
                            ),
                          ),
                          SizedBox(height: 14),
                          Text(
                            'Sign in to view table sync status, browse the latest backup rows, and upload or download table backup files.',
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
                    constraints: const BoxConstraints(maxWidth: 420),
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
                            'Website Login',
                            style: TextStyle(
                              fontSize: 24,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          const SizedBox(height: 8),
                          const Text(
                            'Admin and owner accounts can sign in here. Client accounts work only in the Windows app.',
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
                              labelText: 'Username',
                              hintText: 'dxfoso',
                            ),
                          ),
                          const SizedBox(height: 14),
                          TextField(
                            controller: _passwordController,
                            obscureText: true,
                            onSubmitted: (_) => unawaited(_handleLogin()),
                            decoration: const InputDecoration(
                              labelText: 'Password',
                            ),
                          ),
                          if (_error != null) ...[
                            const SizedBox(height: 14),
                            Text(
                              _error!,
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
                                  _submitting
                                      ? null
                                      : () => unawaited(_handleLogin()),
                              child: Text(
                                _submitting ? 'Signing In...' : 'Sign In',
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
}
