import 'package:flutter/material.dart';

import 'agent_page.dart';

class SyncWindowsAgentApp extends StatefulWidget {
  const SyncWindowsAgentApp({super.key, this.autoLoadOnStart = true});

  final bool autoLoadOnStart;

  @override
  State<SyncWindowsAgentApp> createState() => _SyncWindowsAgentAppState();
}

class _SyncWindowsAgentAppState extends State<SyncWindowsAgentApp> {
  String _clientName = 'Local Agent';

  void _updateClientName(String value) {
    setState(() {
      _clientName = value.trim().isEmpty ? 'Local Agent' : value.trim();
    });
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
      ),
    );
  }
}
