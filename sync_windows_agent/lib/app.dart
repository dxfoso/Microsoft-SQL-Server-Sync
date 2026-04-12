import 'dart:async';

import 'package:flutter/material.dart';

import 'agent_page.dart';
import 'sample_data.dart';
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

  SyncClientState _defaultClientState() {
    return SyncClientState(
      tables: {
        for (final table in discoveredTables)
          table.name: SyncTableState(
            enabled: table.syncEnabled,
            status: table.syncStatus,
            lastSync: table.lastSync,
            history: [
              SyncHistoryEntry(
                timestamp: table.lastSync,
                table: table.name,
                status: table.syncStatus,
                success: table.syncStatus != 'Failed',
                message: 'Seeded from sample data.',
              ),
            ],
          ),
      },
    );
  }

  SyncClientState _stateForClient(String clientName) {
    return _syncStatesByClient[clientName] ?? _defaultClientState();
  }

  @override
  void initState() {
    super.initState();
    _loadState();
  }

  void _loadState() {
    final store = SyncAppStateStore.loadSync();
    _clientName =
        store.lastClientName.trim().isEmpty
            ? 'Local Agent'
            : store.lastClientName.trim();
    _syncStatesByClient = store.clients.isEmpty ? {} : store.clients;
  }

  void _scheduleSave() {
    _saveDebounce?.cancel();
    _saveDebounce = Timer(const Duration(milliseconds: 300), _saveState);
  }

  Future<void> _saveState() async {
    final store = SyncAppStateStore(
      lastClientName: _clientName,
      clients: _syncStatesByClient,
    );
    await store.save();
  }

  void _updateClientName(String value) {
    final nextName = value.trim().isEmpty ? 'Local Agent' : value.trim();
    final previousName = _clientName;
    final currentState = _syncStatesByClient[previousName] ?? _defaultClientState();
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
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const mist = Color(0xFFF2F1ED);
    const ink = Color(0xFF17313A);
    const teal = Color(0xFF1E6674);
    final appTitle =
        _clientName == 'Local Agent'
            ? 'SQL Sync Agent'
            : 'SQL Sync Agent - $_clientName';

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
      home: AgentDashboardPage(
        autoLoadOnStart: widget.autoLoadOnStart,
        clientName: _clientName,
        onClientNameChanged: _updateClientName,
        initialSyncState: _stateForClient(_clientName),
        onSyncStateChanged: _updateSyncStateForClient,
      ),
    );
  }
}
