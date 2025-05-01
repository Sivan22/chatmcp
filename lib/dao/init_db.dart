import 'dart:async';
import 'package:chatmcp/utils/platform.dart';
import 'package:flutter/foundation.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqflite_common_ffi_web/sqflite_ffi_web.dart';
import 'package:path/path.dart';
import 'package:logging/logging.dart';
import 'package:sqflite/sqflite.dart' as sqflite;
import 'dart:io';

class DatabaseHelper {
  static final DatabaseHelper instance = DatabaseHelper._init();
  static Database? _database;
  static const List<String> requiredTables = ['chat', 'chat_message'];
  static const int currentVersion = 2;

  DatabaseHelper._init();

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDB();
    return _database!;
  }

  Future<Database> _initDB() async {
    if (kIsDesktop) {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    } else if (kIsMobile) {
      databaseFactory = sqflite.databaseFactory;
    } else if (kIsWeb) {
      databaseFactory = databaseFactoryFfiWeb;
    }
    String dbPath;

    if (kIsWeb) {
      dbPath = 'chatmcp.db';
    } else {
      final Directory appDataDir = await getAppDir('ChatMcp');
      dbPath = join(appDataDir.path, 'chatmcp.db');
    }
    Logger.root.fine('db path: $dbPath');
    Logger.root.fine('platform:  ${kIsWeb ? 'web' : Platform.operatingSystem}');

    final DatabaseSchemaManager schemaManager = DatabaseSchemaManager();

    try {
      final db = await databaseFactory.openDatabase(
        dbPath,
        options: OpenDatabaseOptions(
          version: currentVersion,
          onCreate: schemaManager.onCreate,
          onUpgrade: schemaManager.onUpgrade,
        ),
      );
      Logger.root.info('Database connection successful');
      return db;
    } catch (e, stackTrace) {
      Logger.root.severe(
          'Database initialization error: $e\nStack trace:\n$stackTrace');
      rethrow;
    }
  }
}

// Database Migration Class Definition
class DatabaseMigration {
  final int version;
  final List<String> sql;

  const DatabaseMigration({
    required this.version,
    required this.sql,
  });
}

Future<void> initDb() async {
  try {
    Logger.root.info('Starting database initialization...');
    final db = await DatabaseHelper.instance.database;
    // Verify if tables were actually created
    final tables = await db.query('sqlite_master', where: "type = 'table'");
    Logger.root.info(
        'Database initialization complete, existing tables: ${tables.map((t) => t['name']).join(', ')}');
  } catch (e, stackTrace) {
    Logger.root.severe('initDb failed: $e\nStack trace:\n$stackTrace');
    rethrow;
  }
}

/// Abstract command class that encapsulates SQL statements needed for each version upgrade
abstract class CommandScript {
  /// Utilize [Batch] to execute statements in bulk, avoiding multiple database calls
  Future<void> execute(Batch batch);
}

/// For example, table creation logic for v1
class CommandScriptV1 extends CommandScript {
  @override
  Future<void> execute(Batch batch) async {
    Logger.root.info('Starting table creation...');
    // Initial table creation scripts
    batch.execute('''
      CREATE TABLE IF NOT EXISTS chat(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        title TEXT,
        modelTEXT,
        createdAt datetime,
        updatedAt datetime
      )
    ''');
    batch.execute('''
      CREATE TABLE IF NOT EXISTS chat_message(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        chatId INTEGER,
        messageId TEXT,
        parentMessageId TEXT,
        body TEXT,
        createdAt datetime,
        updatedAt datetime,
        FOREIGN KEY (chatId) REFERENCES chat(id)
      )
    ''');
    Logger.root.info('Table creation complete');
  }
}

/// Management class to organize multiple version migration scripts
class DatabaseSchemaManager {
  /// Map versions to corresponding CommandScript
  final Map<int, CommandScript> _commands = {};

  DatabaseSchemaManager() {
    // Add commands for each version to the Map
    _commands[1] = CommandScriptV1();
    // Add more versions as needed
  }

  /// On database creation: create tables (version=1)
  Future<void> onCreate(Database db, int version) async {
    final batch = db.batch();
    // Execute from version=1 to the current version
    for (int v = 1; v <= version; v++) {
      final script = _commands[v];
      if (script != null) {
        await script.execute(batch);
      }
    }
    await batch.commit();
  }

  /// On database upgrade: execute scripts from oldVersion+1 to newVersion
  Future<void> onUpgrade(Database db, int oldVersion, int newVersion) async {
    final batch = db.batch();
    Logger.root
        .info('Starting database upgrade... from $oldVersion to $newVersion');
    for (int v = oldVersion + 1; v <= newVersion; v++) {
      final script = _commands[v];
      if (script != null) {
        await script.execute(batch);
      }
    }
    await batch.commit();
  }
}
