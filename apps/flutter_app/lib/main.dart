import 'dart:io';
import 'package:flutter/material.dart';
import 'ui/home_screen.dart';
import 'src/rust/frb_generated.dart';

/// Global flag indicating if Rust FFI is available
bool isRustAvailable = false;

/// Debug log file for troubleshooting
late File _debugLogFile;

void _log(String message) {
  final timestamp = DateTime.now().toIso8601String();
  final logLine = '[$timestamp] $message';
  debugPrint(logLine);
  try {
    _debugLogFile.writeAsStringSync('$logLine\n', mode: FileMode.append);
  } catch (_) {
    // Ignore file write errors
  }
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Set up debug logging
  final logDir = Directory('/tmp/syncmist_debug_logs');
  if (!logDir.existsSync()) {
    logDir.createSync(recursive: true);
  }
  final sessionId = DateTime.now().millisecondsSinceEpoch;
  _debugLogFile = File('${logDir.path}/session_$sessionId.log');
  _debugLogFile.writeAsStringSync('SyncMist Debug Log - Started\n');

  _log('App starting...');

  // Initialize Rust library with graceful fallback
  try {
    _log('Initializing Rust FFI...');
    await RustLib.init();
    isRustAvailable = true;
    _log('Rust FFI initialized successfully');
  } catch (e) {
    isRustAvailable = false;
    _log('Rust FFI initialization failed: $e');
    _log('App will run in mock mode without Rust crypto');
  }

  _log('Starting Flutter app...');
  runApp(const SyncMistApp());
}

/// SyncMist - Universal Clipboard Sync
class SyncMistApp extends StatelessWidget {
  const SyncMistApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SyncMist',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF6366F1), // Indigo
          brightness: Brightness.light,
        ),
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF6366F1),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      themeMode: ThemeMode.system,
      home: const HomeScreen(),
    );
  }
}
