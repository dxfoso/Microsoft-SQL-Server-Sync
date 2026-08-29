import 'dart:async';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'browser_bridge.dart';
import 'client_update_manifest.dart';
import 'clients_page.dart';
import 'dashboard_page.dart';
import 'live_sync_api.dart';
import 'models.dart';
import 'theme.dart';

const String _websiteSessionTokenKey = 'sync_admin_web.auth_token';
const String _themeModeKey = 'sync_admin_web.theme_mode';

ThemeMode _themeModeFromName(String? name) {
  switch (name) {
    case 'light':
      return ThemeMode.light;
    case 'dark':
      return ThemeMode.dark;
    default:
      return ThemeMode.system;
  }
}

class SyncAdminApp extends StatefulWidget {
  const SyncAdminApp({super.key});

  @override
  State<SyncAdminApp> createState() => _SyncAdminAppState();
}

class _SyncAdminAppState extends State<SyncAdminApp> {
  @override
  void initState() {
    super.initState();
    themeModeNotifier.value =
        _themeModeFromName(readBrowserStorage(_themeModeKey));
    themeModeNotifier.addListener(_persistThemeMode);
  }

  @override
  void dispose() {
    themeModeNotifier.removeListener(_persistThemeMode);
    super.dispose();
  }

  void _persistThemeMode() {
    writeBrowserStorage(_themeModeKey, themeModeNotifier.value.name);
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: themeModeNotifier,
      builder: (context, mode, _) {
        return MaterialApp(
          title: 'SQL Sync Control Plane',
          debugShowCheckedModeBanner: false,
          theme: buildAppTheme(Brightness.light),
          darkTheme: buildAppTheme(Brightness.dark),
          themeMode: mode,
          home: const _WebsiteShell(),
        );
      },
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
          final formPadding = tight ? 16.0 : 24.0;
          final t = AppTokens.of(context);

          return Container(
            width: double.infinity,
            decoration: BoxDecoration(color: t.ground),
            child: SafeArea(
              child: SingleChildScrollView(
                padding: EdgeInsets.all(outerPadding),
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 460),
                    child: Container(
                      padding: EdgeInsets.all(formPadding),
                      decoration: BoxDecoration(
                        color: t.surface,
                        borderRadius: BorderRadius.circular(7),
                        border: Border.all(color: t.hairline),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Container(
                                width: 32,
                                height: 32,
                                decoration: BoxDecoration(
                                  gradient: LinearGradient(
                                    begin: Alignment.topLeft,
                                    end: Alignment.bottomRight,
                                    colors: [t.accent, const Color(0xFF0A4F48)],
                                  ),
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: const Icon(
                                  Icons.sync_alt_rounded,
                                  color: Colors.white,
                                  size: 18,
                                ),
                              ),
                              const SizedBox(width: 12),
                              const Expanded(
                                child: Text(
                                  'SQL Sync Control Plane',
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 17,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 18),
                          Text(
                            'Sign in',
                            style: TextStyle(
                              fontSize: 22,
                              fontWeight: FontWeight.w600,
                              color: t.ink,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            'Use an admin, server user, or client account.',
                            style: TextStyle(
                              color: t.muted,
                              fontSize: 13.5,
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
                                  color: t.critWash,
                                  borderRadius: BorderRadius.circular(6),
                                  border: Border.all(
                                    color: t.crit.withValues(alpha: 0.35),
                                  ),
                                ),
                                child: Text(
                                  _error!,
                                  style: TextStyle(
                                    color: t.crit,
                                    fontWeight: FontWeight.w600,
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
                                    ? 'Signing in…'
                                    : 'Open dashboard',
                              ),
                            ),
                          ),
                          const SizedBox(height: 10),
                          Text(
                            'The same account works in the web and Windows app.',
                            style: TextStyle(color: t.muted, fontSize: 12.5),
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
  static const _windowsClientDownloadPath = '/client/download';
  int _selectedIndex = 0;
  String _latestWindowsClientVersion = '';

  void _downloadWindowsClient() {
    final releaseNonce = DateTime.now().millisecondsSinceEpoch;
    openBrowserTab('$_windowsClientDownloadPath?release=$releaseNonce');
  }

  @override
  void initState() {
    super.initState();
    _selectedIndex =
        Uri.base.pathSegments.isNotEmpty &&
                Uri.base.pathSegments.first == 'clients'
            ? 1
            : 0;
    unawaited(_loadLatestWindowsClientVersion());
  }

  Future<void> _loadLatestWindowsClientVersion() async {
    try {
      final nonce = DateTime.now().millisecondsSinceEpoch;
      final response = await http.get(
        Uri.base.resolve('/client/latest.json?release=$nonce'),
      );
      if (response.statusCode != 200) return;
      final version = parseLatestWindowsClientVersion(response.body);
      if (mounted && version.isNotEmpty) {
        setState(() => _latestWindowsClientVersion = version);
      }
    } catch (_) {
      // Keep download usable if the optional version label is unavailable.
    }
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
        authenticatedUser: widget.authenticatedUser,
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
    final t = AppTokens.of(context);
    return Container(
      width: compact ? null : 216,
      color: t.rail,
      padding: EdgeInsets.fromLTRB(compact ? 12 : 12, 16, compact ? 12 : 12, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 6, top: 4),
            child: Row(
              children: [
                Container(
                  width: 30,
                  height: 30,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [t.accent, const Color(0xFF0A4F48)],
                    ),
                    borderRadius: BorderRadius.circular(5),
                  ),
                  child: const Icon(
                    Icons.sync_alt_rounded,
                    color: Colors.white,
                    size: 17,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'SQL Sync',
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w600,
                          fontSize: 14,
                        ),
                      ),
                      Text(
                        'Control plane',
                        style: TextStyle(color: t.railMuted, fontSize: 11),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 22),
          Padding(
            padding: const EdgeInsets.only(left: 8, bottom: 7),
            child: Text(
              'WORKSPACE',
              style: TextStyle(
                color: t.railMuted,
                fontSize: 10,
                fontWeight: FontWeight.w600,
                letterSpacing: 1.3,
              ),
            ),
          ),
          _navItem(0, Icons.dashboard_outlined, 'Dashboard'),
          _navItem(1, Icons.devices_other_outlined, 'Clients'),
          const Spacer(),
          Container(
            padding: const EdgeInsets.only(top: 14),
            decoration: BoxDecoration(
              border: Border(top: BorderSide(color: t.railLine)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.authenticatedUser.name.isEmpty
                      ? widget.authenticatedUser.username
                      : widget.authenticatedUser.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  widget.authenticatedUser.role,
                  style: TextStyle(color: t.railMuted, fontSize: 11),
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: widget.onLogout,
                  icon: const Icon(Icons.logout_rounded, size: 15),
                  label: const Text('Sign out'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: t.railMuted,
                    side: BorderSide(color: t.railLine),
                    padding:
                        const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
                    minimumSize: const Size(0, 30),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _navItem(int index, IconData icon, String label) {
    final t = AppTokens.of(context);
    final selected = _selectedIndex == index;
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Material(
        color: selected ? t.rail2 : Colors.transparent,
        borderRadius: BorderRadius.circular(5),
        child: InkWell(
          onTap: () => _select(index),
          borderRadius: BorderRadius.circular(5),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(5),
              border: Border.all(
                color: selected ? t.railLine : Colors.transparent,
              ),
            ),
            child: Row(
              children: [
                Icon(
                  icon,
                  size: 16,
                  color: selected ? t.accentInk : t.railMuted,
                ),
                const SizedBox(width: 10),
                Text(
                  label,
                  style: TextStyle(
                    color: selected ? Colors.white : t.railMuted,
                    fontWeight: FontWeight.w500,
                    fontSize: 13,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _themeToggleButton() {
    final mode = themeModeNotifier.value;
    final isDark = mode == ThemeMode.dark ||
        (mode == ThemeMode.system &&
            MediaQuery.platformBrightnessOf(context) == Brightness.dark);
    return IconButton(
      tooltip: isDark ? 'Switch to light theme' : 'Switch to dark theme',
      onPressed: () {
        themeModeNotifier.value = isDark ? ThemeMode.light : ThemeMode.dark;
      },
      icon: Icon(
        isDark ? Icons.light_mode_outlined : Icons.dark_mode_outlined,
        size: 18,
      ),
    );
  }

  Widget _downloadWindowsClientButton({required bool compact}) {
    final t = AppTokens.of(context);
    final version = _latestWindowsClientVersion;
    if (compact) {
      return TextButton.icon(
        key: const ValueKey('download-windows-client-compact'),
        style: TextButton.styleFrom(foregroundColor: t.accentInk),
        onPressed: _downloadWindowsClient,
        icon: const Icon(Icons.download_for_offline_outlined, size: 18),
        label: Text(version.isEmpty ? 'Download' : 'v$version'),
      );
    }
    return OutlinedButton.icon(
      key: const ValueKey('download-windows-client'),
      onPressed: _downloadWindowsClient,
      icon: const Icon(Icons.download_for_offline_outlined, size: 16),
      label: Text(
        version.isEmpty
            ? 'Windows client'
            : 'Windows client · v$version',
      ),
      style: OutlinedButton.styleFrom(
        foregroundColor: t.ink,
        side: BorderSide(color: t.hairline),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      ),
    );
  }

  Widget _workspaceHeader() {
    final t = AppTokens.of(context);
    return Container(
      height: 54,
      padding: const EdgeInsets.symmetric(horizontal: 20),
      decoration: BoxDecoration(
        color: t.surface,
        border: Border(bottom: BorderSide(color: t.hairline)),
      ),
      child: Row(
        children: [
          Text(
            _selectedIndex == 0 ? 'Dashboard' : 'Clients',
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
          ),
          const Spacer(),
          _themeToggleButton(),
          const SizedBox(width: 4),
          _downloadWindowsClientButton(compact: false),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.sizeOf(context).width < 900;
    if (!compact) {
      return Scaffold(
        body: Row(
          children: [
            _navigation(compact: false),
            Expanded(
              child: Column(
                children: [_workspaceHeader(), Expanded(child: _page())],
              ),
            ),
          ],
        ),
      );
    }
    return Scaffold(
      drawer: Drawer(child: SafeArea(child: _navigation(compact: true))),
      appBar: AppBar(
        title: Text(_selectedIndex == 0 ? 'Dashboard' : 'Clients'),
        actions: [
          _downloadWindowsClientButton(compact: true),
          const SizedBox(width: 4),
        ],
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
