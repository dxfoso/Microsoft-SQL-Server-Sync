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
    const shell = Color(0xFFF3F5F7);
    const surface = Color(0xFFFCFDFD);
    const ink = Color(0xFF14212B);
    const teal = Color(0xFF1E6674);
    const slate = Color(0xFF74818A);
    const accent = Color(0xFFEEA63A);

    return MaterialApp(
      title: 'SQL Sync Control Plane',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        scaffoldBackgroundColor: shell,
        colorScheme: const ColorScheme.light(
          primary: teal,
          secondary: accent,
          surface: surface,
          onSurface: ink,
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: shell,
          foregroundColor: ink,
          elevation: 0,
          scrolledUnderElevation: 0,
          centerTitle: false,
        ),
        cardTheme: CardThemeData(
          color: Colors.white,
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(22),
            side: const BorderSide(color: Color(0xFFD7DEE3)),
          ),
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
          labelStyle: const TextStyle(color: slate),
          hintStyle: const TextStyle(color: Color(0xFF94A1AA)),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 14,
            vertical: 14,
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
  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();

  AuthenticatedUser? _activeUser;
  String? _authToken;
  String? _error;
  bool _restoringSession = true;
  bool _submitting = false;
  bool _showPassword = false;

  @override
  void initState() {
    super.initState();
    _restoreSession();
  }

  @override
  void dispose() {
    _api.dispose();
    _nameController.dispose();
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
    final name = _nameController.text.trim();
    final password = _passwordController.text;
    if (name.isEmpty || password.isEmpty) {
      setState(() {
        _error = 'Name and password are required.';
      });
      return;
    }

    setState(() {
      _submitting = true;
      _error = null;
    });

    try {
      final result = await _api.loginWeb(name: name, password: password);
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
            decoration: const BoxDecoration(color: Color(0xFFF3F5F7)),
            child: SafeArea(
              child: SingleChildScrollView(
                padding: EdgeInsets.all(outerPadding),
                child: Center(
                  child: ConstrainedBox(
                    constraints: BoxConstraints(maxWidth: compact ? 560 : 1100),
                    child: Wrap(
                      spacing: 24,
                      runSpacing: 24,
                      alignment:
                          compact ? WrapAlignment.start : WrapAlignment.center,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        ConstrainedBox(
                          constraints: BoxConstraints(
                            maxWidth: compact ? 560 : 560,
                          ),
                          child: Container(
                            padding: EdgeInsets.all(heroPadding),
                            decoration: BoxDecoration(
                              color: const Color(0xFF152630),
                              borderRadius: BorderRadius.circular(
                                compact ? 22 : 28,
                              ),
                              border: Border.all(
                                color: const Color(0xFF243A48),
                              ),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const _HeroTag(label: 'Web Control Plane'),
                                const SizedBox(height: 22),
                                Text(
                                  'Monitor sync health, review compact history, and open saved table data only when you need it.',
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontSize: heroFontSize,
                                    fontWeight: FontWeight.w800,
                                    height: 1.02,
                                  ),
                                ),
                                const SizedBox(height: 14),
                                const Text(
                                  'Admin and owner accounts sign in here. Client data opens from the exact history event that produced the saved snapshot, not from a permanent inline data table.',
                                  style: TextStyle(
                                    color: Color(0xFFB7C5CE),
                                    fontSize: 14.5,
                                    height: 1.5,
                                  ),
                                ),
                                const SizedBox(height: 22),
                                const Wrap(
                                  spacing: 10,
                                  runSpacing: 10,
                                  children: [
                                    _HeroPill(label: 'Compact layout'),
                                    _HeroPill(label: 'Saved snapshot dialogs'),
                                    _HeroPill(label: 'Owner + admin access'),
                                  ],
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
                              borderRadius: BorderRadius.circular(
                                compact ? 24 : 30,
                              ),
                              border: Border.all(
                                color: const Color(0xFFD8E0E5),
                              ),
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
                                  'Website Login',
                                  style: TextStyle(
                                    fontSize: 26,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                                const SizedBox(height: 8),
                                const Text(
                                  'Use the owner or admin account name created in the control plane.',
                                  style: TextStyle(
                                    color: Color(0xFF62717C),
                                    fontSize: 14,
                                    height: 1.5,
                                  ),
                                ),
                                const SizedBox(height: 22),
                                TextField(
                                  controller: _nameController,
                                  textInputAction: TextInputAction.next,
                                  decoration: const InputDecoration(
                                    labelText: 'Name',
                                    hintText: 'owner-name',
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
                                if (_error != null) ...[
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
                                      _error!,
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
                                        _submitting
                                            ? null
                                            : () => unawaited(_handleLogin()),
                                    child: Text(
                                      _submitting
                                          ? 'Signing In...'
                                          : 'Open Dashboard',
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 12),
                                const Text(
                                  'Client accounts are restricted to the Windows app.',
                                  style: TextStyle(
                                    color: Color(0xFF7A8790),
                                    fontSize: 12.5,
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
}

class _HeroTag extends StatelessWidget {
  const _HeroTag({required this.label});

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

class _HeroPill extends StatelessWidget {
  const _HeroPill({required this.label});

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
