import 'package:chatmcp/utils/platform.dart';
import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';
import 'dart:io';
import 'package:path/path.dart' as path;
import 'package:flutter/widgets.dart';

// Define color codes
const ansiReset = '\x1B[0m';
const ansiRed = '\x1B[31m';
const ansiGreen = '\x1B[32m';
const ansiYellow = '\x1B[33m';
const ansiBlue = '\x1B[34m';
const ansiMagenta = '\x1B[35m';
const ansiGray = '\x1B[37m';

// Get color for log level
String getLevelColor(Level level) {
  switch (level.name) {
    case 'SEVERE':
      return ansiRed;
    case 'WARNING':
      return ansiYellow;
    case 'INFO':
      return ansiBlue;
    case 'CONFIG':
      return ansiMagenta;
    case 'FINE':
    case 'FINER':
    case 'FINEST':
      return ansiGreen;
    default:
      return ansiGray;
  }
}

class FileLogger {
  static File? _logFile;
  static IOSink? _logSink;

  static Future<void> initLogFile() async {
    try {
      final Directory appDir = await getAppDir('ChatMcp');
      final logDir = Directory(path.join(appDir.path, 'logs'));

      // Ensure log directory exists
      if (!await logDir.exists()) {
        await logDir.create(recursive: true);
      }

      // Use date as log filename
      final now = DateTime.now();
      final fileName = 'app_${now.year}-${now.month}-${now.day}.log';
      _logFile = File(path.join(logDir.path, fileName));

      // Open file in append mode
      _logSink = _logFile?.openWrite(mode: FileMode.append);
    } catch (e) {
      debugPrint('Failed to initialize log file: $e');
    }
  }

  static void closeLogFile() {
    _logSink?.flush();
    _logSink?.close();
  }

  static void writeToFile(String message) {
    _logSink?.writeln('${DateTime.now()} $message');
  }
}

void initializeLogger() async {
  // Initialize file logger
  if (!kIsWeb) {
    await FileLogger.initLogFile();
  }

  Logger.root.level = Level.ALL;
  Logger.root.onRecord.listen((record) {
    // Get caller location info
    String? caller;

    // Use StackTrace.current to ensure stack trace is always available
    final stackTrace = record.stackTrace ?? StackTrace.current;
    final frames = stackTrace.toString().split('\n');

    if (frames.length > 1) {
      // Parse the first matching stack frame
      final callerFrame = frames.firstWhere(
        (frame) =>
            !frame.contains('log.dart') &&
            !frame.contains('logger.dart') &&
            !frame.contains('logger_mixin.dart') &&
            !frame.contains('main.dart') &&
            !frame.contains('dart:async') &&
            !frame.contains('dart:io') &&
            frame.contains('package:chatmcp/'),
        orElse: () => frames.firstWhere(
          (frame) => frame.contains('package:chatmcp/'),
          orElse: () => frames[0],
        ),
      );

      // Extract filename and line number
      final match = RegExp(r'\((.+?):(\d+)(?::\d+)\)').firstMatch(callerFrame);
      if (match != null) {
        final file = match.group(1);
        final line = match.group(2);
        caller = '$file:$line';
      } else {
        final flutterMatch = RegExp(r'#\d+\s+.*\s+\((.+?):(\d+)(?::\d+)?\)')
            .firstMatch(callerFrame);
        if (flutterMatch != null) {
          final file = flutterMatch.group(1);
          final line = flutterMatch.group(2);
          caller = '$file:$line';
        }
      }
    }

    final levelColor = getLevelColor(record.level);
    final logMessage =
        '${record.level.name}: ${caller ?? 'unknown'}: ${record.message}';

    // In development mode, print colored logs to console
    assert(() {
      debugPrint('$levelColor$logMessage$ansiReset');
      return true;
    }());

    if (!kIsWeb) {
      // In release mode, write to file
      FileLogger.writeToFile(logMessage);
    }
  });
}
