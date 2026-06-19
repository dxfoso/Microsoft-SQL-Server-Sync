import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/widgets.dart';

import 'app.dart';
import 'startup_log.dart';

void main() {
  runZonedGuarded(
    () {
      WidgetsFlutterBinding.ensureInitialized();
      logStartupEvent(
        'Process starting. executable=${Platform.resolvedExecutable} cwd=${Directory.current.path}',
      );

      FlutterError.onError = (details) {
        logStartupEvent(
          'FlutterError: ${details.exceptionAsString()}\n${details.stack}',
        );
        FlutterError.presentError(details);
      };

      PlatformDispatcher.instance.onError = (error, stack) {
        logStartupEvent('PlatformDispatcher error: $error\n$stack');
        return false;
      };

      logStartupEvent('Entering runApp');
      runApp(const SyncWindowsAgentApp());
    },
    (error, stack) {
      logStartupEvent('Uncaught zone error: $error\n$stack');
    },
  );
}
