import 'dart:io';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import '../mcp/mcp.dart';
import 'package:logging/logging.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;
import 'package:chatmcp/utils/platform.dart';
import '../mcp/client/mcp_client_interface.dart';

class McpServerProvider extends ChangeNotifier {
  static final McpServerProvider _instance = McpServerProvider._internal();
  factory McpServerProvider() => _instance;
  McpServerProvider._internal() {
    init();
  }

  static const _configFileName = 'mcp_server.json';
  static const _mcpServersKey = 'mcp_servers_config';

  Map<String, McpClient> _servers = {};

  Map<String, McpClient> get clients => _servers;

  // Check if current platform supports MCP Server
  bool get isSupported {
    return kIsWeb || (!Platform.isIOS && !Platform.isAndroid);
  }

  // Get configuration file path
  Future<String> get _configFilePath async {
    if (kIsWeb) {
      return _configFileName;
    }
    final directory = await getAppDir('ChatMcp');
    return '${directory.path}/$_configFileName';
  }

  // Initialize SharedPreferences with default configuration if needed
  Future<void> _initSharedPreferences() async {
    final prefs = await SharedPreferences.getInstance();

    // Check if configuration exists in SharedPreferences
    if (!prefs.containsKey(_mcpServersKey)) {
      // Load default configuration from assets
      final defaultConfig =
          await rootBundle.loadString('assets/mcp_server.json');

      // Save to SharedPreferences
      await prefs.setString(_mcpServersKey, defaultConfig);
      Logger.root
          .info('Default configuration initialized in SharedPreferences');
    }

    // Migration: If we're not on web and the file exists, migrate to SharedPreferences
    if (!kIsWeb) {
      try {
        final file = File(await _configFilePath);
        if (await file.exists()) {
          final String contents = await file.readAsString();
          await prefs.setString(_mcpServersKey, contents);
          Logger.root
              .info('Migrated configuration from file to SharedPreferences');
        }
      } catch (e) {
        Logger.root.warning('File migration skipped: $e');
      }
    }
  }

  // get installed servers count
  Future<int> get installedServersCount async {
    final allServerConfig = await loadServers();
    final serverConfig = allServerConfig['mcpServers'] as Map<String, dynamic>;
    return serverConfig.length;
  }

  // Read server configuration from SharedPreferences
  Future<Map<String, dynamic>> loadServers() async {
    try {
      await _initSharedPreferences();
      final prefs = await SharedPreferences.getInstance();

      // Get configuration from SharedPreferences
      final String? contents = prefs.getString(_mcpServersKey);

      if (contents == null) {
        Logger.root.warning('No configuration found in SharedPreferences');
        return {'mcpServers': <String, dynamic>{}};
      }

      final Map<String, dynamic> data = json.decode(contents);
      if (data['mcpServers'] == null) {
        data['mcpServers'] = <String, dynamic>{};
      }

      // Set all servers as installed
      for (var server in data['mcpServers'].entries) {
        server.value['installed'] = true;
      }

      return data;
    } catch (e, stackTrace) {
      Logger.root
          .severe('Failed to read configuration: $e, stackTrace: $stackTrace');
      return {'mcpServers': <String, dynamic>{}};
    }
  }

  // Save server configuration to SharedPreferences
  Future<void> saveServers(Map<String, dynamic> servers) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final prettyContents =
          const JsonEncoder.withIndent('  ').convert(servers);
      await prefs.setString(_mcpServersKey, prettyContents);

      // Also save to file for backward compatibility if not on web
      if (!kIsWeb) {
        try {
          final file = File(await _configFilePath);
          await file.writeAsString(prettyContents);
        } catch (e) {
          Logger.root.warning('Failed to write to backup file: $e');
        }
      }

      // Reinitialize clients after saving
      await _reinitializeClients();
    } catch (e, stackTrace) {
      Logger.root
          .severe('Failed to save configuration: $e, stackTrace: $stackTrace');
    }
  }

  // Reinitialize clients
  Future<void> _reinitializeClients() async {
    // _servers.clear();
    await init();
    notifyListeners();
  }

  void addClient(String key, McpClient client) {
    _servers[key] = client;
    notifyListeners();
  }

  void removeClient(String key) {
    _servers.remove(key);
    notifyListeners();
  }

  McpClient? getClient(String key) {
    return _servers[key];
  }

  final Map<String, List<Map<String, dynamic>>> _tools = {};
  Map<String, List<Map<String, dynamic>>> get tools {
    return _tools;
  }

  // 存储工具类别的启用状态
  final Map<String, bool> _toolCategoryEnabled = {};
  Map<String, bool> get toolCategoryEnabled => _toolCategoryEnabled;

  // 切换工具类别的启用状态
  void toggleToolCategory(String category, bool enabled) {
    _toolCategoryEnabled[category] = enabled;
    notifyListeners();
  }

  // 获取工具类别的启用状态，默认为启用
  bool isToolCategoryEnabled(String category) {
    return _toolCategoryEnabled[category] ?? false;
  }

  bool loadingServerTools = false;

  Future<List<Map<String, dynamic>>> getServerTools(
      String serverName, McpClient client) async {
    final tools = <Map<String, dynamic>>[];
    final response = await client.sendToolList();
    final toolsList = response.toJson()['result']['tools'] as List<dynamic>;
    tools.addAll(toolsList.cast<Map<String, dynamic>>());
    return tools;
  }

  Future<void> init() async {
    try {
      // Initialize SharedPreferences
      await _initSharedPreferences();

      // Get configuration path for logging purposes
      final configFilePath = await _configFilePath;
      Logger.root.info('mcp_server path (legacy): $configFilePath');

      // Log configuration content
      final prefs = await SharedPreferences.getInstance();
      final configContent = prefs.getString(_mcpServersKey);
      Logger.root.info('mcp_server config: $configContent');

      final ignoreServers = <String>[];
      for (var entry in clients.entries) {
        ignoreServers.add(entry.key);
      }

      Logger.root.info('mcp_server ignoreServers: $ignoreServers');

      // _servers = await initializeAllMcpServers(configFilePath, ignoreServers);
      // Logger.root.info('mcp_server count: ${_servers.length}');
      // for (var entry in _servers.entries) {
      //   addClient(entry.key, entry.value);
      // }

      notifyListeners();
    } catch (e, stackTrace) {
      Logger.root.severe(
          'Failed to initialize MCP servers: $e, stackTrace: $stackTrace');
      // Print more detailed error information
      if (e is TypeError) {
        try {
          final prefs = await SharedPreferences.getInstance();
          final content = prefs.getString(_mcpServersKey);
          Logger.root
              .severe('Configuration parsing error, current content: $content');
        } catch (e2) {
          Logger.root.severe('Failed to retrieve configuration: $e2');
        }
      }
    }
  }

  Future<int> get mcpServerCount async {
    final allServerConfig = await loadServers();
    final serverConfig = allServerConfig['mcpServers'] as Map<String, dynamic>;
    return serverConfig.length;
  }

  Future<List<String>> get mcpServers async {
    final allServerConfig = await loadServers();
    final serverConfig = allServerConfig['mcpServers'] as Map<String, dynamic>;
    return serverConfig.keys.toList();
  }

  bool mcpServerIsRunning(String serverName) {
    final client = clients[serverName];
    return client != null;
  }

  Future<void> stopMcpServer(String serverName) async {
    final client = clients[serverName];
    if (client != null) {
      await client.dispose();
      clients.remove(serverName);
      notifyListeners();
    }
  }

  Future<McpClient?> startMcpServer(String serverName) async {
    final allServerConfig = await loadServers();
    final serverConfig = allServerConfig['mcpServers'][serverName];
    final client = await initializeMcpServer(serverConfig);
    if (client != null) {
      clients[serverName] = client;
      loadingServerTools = true;
      notifyListeners();
      final tools = await getServerTools(serverName, client);
      _tools[serverName] = tools;
      loadingServerTools = false;
      notifyListeners();
    }
    return client;
  }

  Future<Map<String, McpClient>> initializeAllMcpServers(
      String configPath, List<String> ignoreServers) async {
    // Read configuration from SharedPreferences instead of file
    final prefs = await SharedPreferences.getInstance();
    final contents = prefs.getString(_mcpServersKey);

    if (contents == null) {
      Logger.root.warning(
          'No configuration found in SharedPreferences for initializeAllMcpServers');
      return {};
    }

    final Map<String, dynamic> config =
        json.decode(contents) as Map<String, dynamic>? ?? {};

    final mcpServers = config['mcpServers'] as Map<String, dynamic>? ?? {};

    final Map<String, McpClient> clients = {};

    for (var entry in mcpServers.entries) {
      if (ignoreServers.contains(entry.key)) {
        continue;
      }

      final serverName = entry.key;
      final serverConfig = entry.value as Map<String, dynamic>;

      try {
        // Create async task and add to list
        final client = await initializeMcpServer(serverConfig);
        if (client != null) {
          clients[serverName] = client;
          loadingServerTools = true;
          notifyListeners();
          final tools = await getServerTools(serverName, client);
          _tools[serverName] = tools;
          loadingServerTools = false;
          notifyListeners();
        }
      } catch (e, stackTrace) {
        Logger.root.severe(
            'Failed to initialize MCP server: $serverName, $e, stackTrace: $stackTrace');
      }
    }

    return clients;
  }

  String mcpServerMarket =
      "https://raw.githubusercontent.com/daodao97/chatmcp/refs/heads/main/assets/mcp_server_market.json";

  Future<Map<String, dynamic>> loadMarketServers() async {
    try {
      final response = await http.get(Uri.parse(mcpServerMarket));
      if (response.statusCode == 200) {
        Logger.root
            .info('Successfully loaded market servers: ${response.body}');
        final Map<String, dynamic> jsonData = json.decode(response.body);

        final Map<String, dynamic> servers =
            jsonData['mcpServers'] as Map<String, dynamic>;

        var sseServers = <String, dynamic>{};

        // For mobile platforms, only keep servers with commands starting with http
        if (Platform.isIOS || Platform.isAndroid) {
          for (var server in servers.entries) {
            if (server.value['command'] != null &&
                server.value['command'].toString().startsWith('http')) {
              sseServers[server.key] = server.value;
            }
          }
        } else {
          sseServers = servers;
        }

        // 获取本地已安装的mcp服务器
        final localInstalledServers = await loadServers();
        //遍历sseServers，如果本地已安装的mcp服务器中存在，则将sseServers中的该服务器设置为已安装
        for (var server in sseServers.entries) {
          if (localInstalledServers['mcpServers'][server.key] != null) {
            server.value['installed'] = true;
          } else {
            server.value['installed'] = false;
          }
        }

        return {
          'mcpServers': sseServers,
        };
      }
      throw Exception('Failed to load market servers: ${response.statusCode}');
    } catch (e, stackTrace) {
      Logger.root
          .severe('Failed to load market servers: $e, stackTrace: $stackTrace');
      throw Exception('Failed to load market servers: $e');
    }
  }
}
