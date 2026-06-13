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
    const shell = Color(0xFFF6F7F9);
    const surface = Color(0xFFFFFFFF);
    const ink = Color(0xFF101828);
    const primary = Color(0xFF0F766E);
    const slate = Color(0xFF667085);
    const accent = Color(0xFFE0A32A);
    const border = Color(0xFFDDE3EA);

    return MaterialApp(
      title: 'SQL Sync Control Plane',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        scaffoldBackgroundColor: shell,
        colorScheme: const ColorScheme.light(
          primary: primary,
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
            borderRadius: BorderRadius.circular(8),
            side: const BorderSide(color: border),
          ),
        ),
        textTheme: ThemeData.light().textTheme.apply(
          bodyColor: ink,
          displayColor: ink,
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            backgroundColor: primary,
            foregroundColor: Colors.white,
            minimumSize: const Size(0, 36),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
          ),
        ),
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(
            foregroundColor: ink,
            minimumSize: const Size(0, 34),
            side: const BorderSide(color: border),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
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
          labelStyle: const TextStyle(color: slate),
          hintStyle: const TextStyle(color: Color(0xFF98A2B3)),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 12,
            vertical: 11,
          ),
        ),
        dividerTheme: const DividerThemeData(
          color: Color(0xFFE4E7EC),
          thickness: 1,
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
          final heroFontSize = tight ? 22.0 : (compact ? 26.0 : 30.0);
          final outerPadding = tight ? 12.0 : 18.0;
          final heroPadding = tight ? 18.0 : 24.0;
          final formPadding = tight ? 16.0 : 20.0;

          return Container(
            width: double.infinity,
            decoration: const BoxDecoration(color: Color(0xFFF6F7F9)),
            child: SafeArea(
              child: SingleChildScrollView(
                padding: EdgeInsets.all(outerPadding),
                child: Center(
                  child: ConstrainedBox(
                    constraints: BoxConstraints(maxWidth: compact ? 560 : 1100),
                    child: Wrap(
                      spacing: 16,
                      runSpacing: 16,
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
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(
                                color: const Color(0xFFDDE3EA),
                              ),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const _HeroTag(label: 'Web Control Plane'),
                                const SizedBox(height: 16),
                                Text(
                                  'Open sync status, history, and saved data.',
                                  style: TextStyle(
                                    color: const Color(0xFF101828),
                                    fontSize: heroFontSize,
                                    fontWeight: FontWeight.w800,
                                    height: 1.06,
                                  ),
                                ),
                                const SizedBox(height: 10),
                                const Text(
                                  'Server and admin accounts only.',
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
                                  'Website Login',
                                  style: TextStyle(
                                    fontSize: 26,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                                const SizedBox(height: 6),
                                const Text(
                                  'Server and admin accounts only.',
                                  style: TextStyle(
                                    color: Color(0xFF667085),
                                    fontSize: 14,
                                    height: 1.35,
                                  ),
                                ),
                                const SizedBox(height: 16),
                                TextField(
                                  controller: _nameController,
                                  textInputAction: TextInputAction.next,
                                  decoration: const InputDecoration(
                                    labelText: 'Name',
                                    hintText: 'server-name',
                                  ),
                                ),
                                const SizedBox(height: 10),
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
                                  const SizedBox(height: 10),
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
                                      _error!,
                                      style: const TextStyle(
                                        color: Color(0xFFB5422A),
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                  ),
                                ],
                                const SizedBox(height: 14),
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
                                const SizedBox(height: 10),
                                const Text(
                                  'Client accounts use the Windows app.',
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
