import 'dart:async';

import 'package:flutter/material.dart';

import 'browser_bridge.dart';
import 'clients_page.dart';
import 'dashboard_page.dart';
import 'live_sync_api.dart';
import 'models.dart';

const String _websiteSessionTokenKey = 'sync_admin_web.auth_token';
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

    final textTheme = _withFontFallback(
      ThemeData.light().textTheme.apply(bodyColor: ink, displayColor: ink),
    );

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
        textTheme: textTheme,
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
      return _AdminWorkspace(
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
          final tight = width < 480;
          final outerPadding = tight ? 12.0 : 18.0;
          final formPadding = tight ? 16.0 : 20.0;

          return Container(
            width: double.infinity,
            decoration: const BoxDecoration(color: Color(0xFFF6F7F9)),
            child: SafeArea(
              child: SingleChildScrollView(
                padding: EdgeInsets.all(outerPadding),
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 560),
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
                            'Website Login',
                            style: TextStyle(
                              fontSize: 26,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          const SizedBox(height: 6),
                          const Text(
                            'Sign in with an admin, server user, or client account.',
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
                            SelectionArea(
                              child: Container(
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
                            'The same account works in the web and Windows app.',
                            style: TextStyle(
                              color: Color(0xFF7A8790),
                              fontSize: 12.5,
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
}

class _AdminWorkspace extends StatefulWidget {
  const _AdminWorkspace({
    required this.authenticatedUser,
    required this.authToken,
    required this.onLogout,
  });

  final AuthenticatedUser authenticatedUser;
  final String authToken;
  final VoidCallback onLogout;

  @override
  State<_AdminWorkspace> createState() => _AdminWorkspaceState();
}

class _AdminWorkspaceState extends State<_AdminWorkspace> {
  int _selectedIndex = 0;

  @override
  void initState() {
    super.initState();
    _selectedIndex =
        Uri.base.pathSegments.isNotEmpty &&
                Uri.base.pathSegments.first == 'clients'
            ? 1
            : 0;
  }

  void _select(int index) {
    replaceBrowserUrl(
      Uri.base.replace(path: index == 1 ? '/clients' : '/dashboard').toString(),
    );
    setState(() => _selectedIndex = index);
    if (MediaQuery.sizeOf(context).width < 900) {
      Navigator.of(context).maybePop();
    }
  }

  Widget _page() {
    if (_selectedIndex == 1) {
      return ClientsPage(
        key: ValueKey('clients:${Uri.base.path}'),
        authToken: widget.authToken,
        onLogout: widget.onLogout,
      );
    }
    return AdminDashboardPage(
      authenticatedUser: widget.authenticatedUser,
      authToken: widget.authToken,
      onLogout: widget.onLogout,
    );
  }

  Widget _navigation({required bool compact}) {
    final foreground = Colors.white;
    final muted = const Color(0xFFB7C7C8);
    return Container(
      width: compact ? null : 228,
      color: const Color(0xFF183234),
      padding: EdgeInsets.fromLTRB(
        compact ? 12 : 16,
        18,
        compact ? 12 : 16,
        16,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: const Color(0xFF0F766E),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Icon(
                  Icons.sync_alt_rounded,
                  color: Colors.white,
                  size: 20,
                ),
              ),
              const SizedBox(width: 10),
              const Expanded(
                child: Text(
                  'SQL Sync',
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w800,
                    fontSize: 16,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),
          Text(
            'WORKSPACE',
            style: TextStyle(
              color: muted,
              fontSize: 10,
              fontWeight: FontWeight.w800,
              letterSpacing: 1.1,
            ),
          ),
          const SizedBox(height: 8),
          _navItem(0, Icons.dashboard_outlined, 'Dashboard', foreground, muted),
          _navItem(
            1,
            Icons.devices_other_outlined,
            'Clients',
            foreground,
            muted,
          ),
          const Spacer(),
          Text(
            widget.authenticatedUser.name.isEmpty
                ? widget.authenticatedUser.username
                : widget.authenticatedUser.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 3),
          Text(
            widget.authenticatedUser.role,
            style: TextStyle(color: muted, fontSize: 12),
          ),
          const SizedBox(height: 10),
          TextButton.icon(
            onPressed: widget.onLogout,
            icon: const Icon(Icons.logout_rounded, size: 16),
            label: const Text('Sign out'),
            style: TextButton.styleFrom(
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 4),
            ),
          ),
        ],
      ),
    );
  }

  Widget _navItem(
    int index,
    IconData icon,
    String label,
    Color foreground,
    Color muted,
  ) {
    final selected = _selectedIndex == index;
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Material(
        color: selected ? const Color(0xFF245153) : Colors.transparent,
        borderRadius: BorderRadius.circular(7),
        child: InkWell(
          onTap: () => _select(index),
          borderRadius: BorderRadius.circular(7),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
            child: Row(
              children: [
                Icon(icon, size: 19, color: selected ? foreground : muted),
                const SizedBox(width: 10),
                Text(
                  label,
                  style: TextStyle(
                    color: selected ? foreground : muted,
                    fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.sizeOf(context).width < 900;
    if (!compact) {
      return Scaffold(
        body: Row(
          children: [_navigation(compact: false), Expanded(child: _page())],
        ),
      );
    }
    return Scaffold(
      drawer: Drawer(child: SafeArea(child: _navigation(compact: true))),
      appBar: AppBar(
        title: Text(_selectedIndex == 0 ? 'Dashboard' : 'Clients'),
        leading: Builder(
          builder:
              (context) => IconButton(
                tooltip: 'Open navigation',
                onPressed: () => Scaffold.of(context).openDrawer(),
                icon: const Icon(Icons.menu_rounded),
              ),
        ),
      ),
      body: _page(),
    );
  }
}
