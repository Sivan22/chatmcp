import 'package:chatmcp/mcp/stdio/stdio_client.dart';
import 'package:synchronized/synchronized.dart';

import '../client/mcp_client_interface.dart';
import '../models/json_rpc_message.dart';
import '../models/server.dart';
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';
import 'dart:convert';
import 'dart:async';
import 'dart:io';

class SSEClient implements McpClient {
  final ServerConfig _serverConfig;
  final _pendingRequests = <String, Completer<JSONRPCMessage>>{};
  final _processStateController = StreamController<ProcessState>.broadcast();
  Stream<ProcessState> get processStateStream => _processStateController.stream;

  HttpClient? _httpClient;
  HttpClientRequest? _request;
  HttpClientResponse? _response;
  StreamSubscription? _sseSubscription;
  final _writeLock = Lock();
  String? _messageEndpoint;
  final _buffer = StringBuffer();

  bool _isConnecting = false;
  bool _disposed = false;
  int _reconnectAttempts = 0;
  static const int _maxReconnectAttempts = 5;
  static const Duration _initialReconnectDelay = Duration(seconds: 1);
  Timer? _reconnectTimer;

  final Map<String, String> _headers = {
    'Content-Type': 'application/json; charset=utf-8',
    'Accept': 'application/json; charset=utf-8',
  };

  SSEClient({required ServerConfig serverConfig})
      : _serverConfig = serverConfig;

  @override
  ServerConfig get serverConfig => _serverConfig;

  void _handleMessage(JSONRPCMessage message) {
    if (message.id != null && _pendingRequests.containsKey(message.id)) {
      final completer = _pendingRequests.remove(message.id);
      completer?.complete(message);
    }
  }

  @override
  Future<void> initialize() async {
    _reconnectAttempts = 0;
    await _connect();
  }

  Future<void> _connect() async {
    if (_isConnecting || _disposed) return;

    _isConnecting = true;
    try {
      Logger.root.info('Starting SSE connection: ${serverConfig.command}');
      _processStateController.add(const ProcessState.starting());

      _httpClient = HttpClient();
      _request = await _httpClient!.getUrl(Uri.parse(serverConfig.command));
      _request!.headers.set('Accept', 'text/event-stream');
      _request!.headers.set('Cache-Control', 'no-cache');
      _request!.headers.set('Connection', 'keep-alive');

      _response = await _request!.close();

      if (_response!.statusCode != 200) {
        throw Exception('SSE connection failed: ${_response!.statusCode}');
      }

      _reconnectAttempts = 0;
      _buffer.clear();

      _sseSubscription = _response!.transform(utf8.decoder).listen(
        (String chunk) {
          Logger.root.fine('SSE chunk received: $chunk');
          _buffer.write(chunk);
          _processSSEBuffer();
        },
        onError: (error) {
          Logger.root.severe('SSE connection error: $error');
          _processStateController
              .add(ProcessState.error(error, StackTrace.current));
          _scheduleReconnect();
        },
        onDone: () {
          Logger.root.info('SSE connection closed');
          _processStateController.add(const ProcessState.exited(0));
          _scheduleReconnect();
        },
      );
    } catch (e, stack) {
      Logger.root.severe('SSE connection failed: $e\n$stack');
      _processStateController.add(ProcessState.error(e, stack));
      _scheduleReconnect();
    } finally {
      _isConnecting = false;
    }
  }

  void _processSSEBuffer() {
    final content = _buffer.toString();
    final lines = content.split('\n');

    String currentEvent = '';
    String? currentData;

    int processedIndex = 0;

    for (int i = 0; i < lines.length; i++) {
      final line = lines[i].trim();

      if (line.isEmpty) {
        // 空行表示事件结束
        if (currentEvent.isNotEmpty && currentData != null) {
          _handleSSEEvent(currentEvent, currentData);
          currentEvent = '';
          currentData = null;
        }
        processedIndex = i + 1;
        continue;
      }

      if (line.startsWith('event:')) {
        currentEvent = line.substring(6).trim();
        Logger.root.fine('SSE event: $currentEvent');
      } else if (line.startsWith('data:')) {
        currentData = line.substring(5).trim();
        Logger.root.fine('SSE data: $currentData');
      }
    }

    // 清理已处理的内容
    if (processedIndex > 0 && processedIndex < lines.length) {
      _buffer.clear();
      for (int i = processedIndex; i < lines.length; i++) {
        _buffer.writeln(lines[i]);
      }
    } else if (processedIndex >= lines.length) {
      _buffer.clear();
    }
  }

  void _handleSSEEvent(String event, String data) {
    Logger.root.fine('Handling SSE event: $event, data: $data');

    if (event == 'endpoint') {
      final uri = Uri.parse(serverConfig.command);
      final baseUrl = uri.origin;
      _messageEndpoint = data.startsWith("http")
          ? data
          : baseUrl + (data.startsWith("/") ? data : "/$data");
      Logger.root.info('Received message endpoint: $_messageEndpoint');
      _processStateController.add(const ProcessState.running());
    } else if (event == 'message') {
      try {
        final jsonData = jsonDecode(data);
        final message = JSONRPCMessage.fromJson(jsonData);
        _handleMessage(message);
      } catch (e, stack) {
        Logger.root.severe('Failed to parse server message: $e\n$stack');
      }
    }
  }

  void _scheduleReconnect() {
    if (_disposed || _isConnecting || _reconnectTimer != null) return;

    _reconnectAttempts++;
    if (_reconnectAttempts > _maxReconnectAttempts) {
      Logger.root.severe('达到最大重连尝试次数 ($_maxReconnectAttempts)，停止重连');
      return;
    }

    final delay = _initialReconnectDelay * (1 << (_reconnectAttempts - 1));
    Logger.root.info('计划在 ${delay.inSeconds} 秒后进行第 $_reconnectAttempts 次重连尝试');

    _reconnectTimer = Timer(delay, () {
      _reconnectTimer = null;
      _connect();
    });
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;

    // 尝试关闭底层的HTTP连接
    try {
      _sseSubscription?.cancel();

      // 尝试分离并关闭socket
      if (_response != null) {
        await _response!.detachSocket().then((socket) {
          socket.destroy();
        });
      }

      // 中止请求
      _request?.abort();

      // 关闭HTTP客户端
      _httpClient?.close(force: true);
    } catch (e) {
      Logger.root.info('关闭SSE连接时发生错误: $e');
    }

    await _processStateController.close();
    _messageEndpoint = null;
    _buffer.clear();
  }

  Future<void> _sendHttpPost(Map<String, dynamic> data) async {
    if (_messageEndpoint == null) {
      throw StateError('Message endpoint not initialized ${jsonEncode(data)}');
    }

    await _writeLock.synchronized(() async {
      try {
        Logger.root.info('发送HTTP请求到 $_messageEndpoint: ${jsonEncode(data)}');

        final response = await http.post(
          Uri.parse(_messageEndpoint!),
          headers: _headers,
          body: jsonEncode(data),
        );

        Logger.root.info('HTTP响应状态码: ${response.statusCode}');

        if (response.statusCode >= 400) {
          Logger.root
              .severe('HTTP POST失败: ${response.statusCode} - ${response.body}');
          throw Exception(
              'HTTP POST failed: ${response.statusCode} - ${response.body}');
        } else {
          // 记录成功响应
          if (response.body.isNotEmpty) {
            Logger.root.info('HTTP响应内容: ${response.body}');
          }
        }
      } catch (e, stack) {
        Logger.root.severe('发送HTTP POST失败: $e\n$stack');
        rethrow;
      }
    });
  }

  @override
  Future<JSONRPCMessage> sendMessage(JSONRPCMessage message) async {
    if (message.id == null) {
      throw ArgumentError('Message must have an ID');
    }

    final completer = Completer<JSONRPCMessage>();
    _pendingRequests[message.id!] = completer;

    try {
      await _sendHttpPost(message.toJson());
      return await completer.future.timeout(
        const Duration(seconds: 30),
        onTimeout: () {
          _pendingRequests.remove(message.id);
          throw TimeoutException('Request timed out: ${message.id}');
        },
      );
    } catch (e) {
      _pendingRequests.remove(message.id);
      rethrow;
    }
  }

  @override
  Future<JSONRPCMessage> sendInitialize() async {
    // 确保连接已经建立
    if (_messageEndpoint == null) {
      Logger.root.warning('尝试初始化但消息端点尚未建立，等待端点建立...');
      // 等待一段时间以确保SSE连接已建立并获取到端点
      for (int i = 0; i < 10; i++) {
        await Future.delayed(const Duration(milliseconds: 500));
        if (_messageEndpoint != null) break;
      }

      if (_messageEndpoint == null) {
        throw StateError('消息端点在等待后仍未建立，无法完成初始化');
      }
    }

    Logger.root.info('开始发送初始化请求到 $_messageEndpoint');

    // 发送初始化请求
    final initMessage =
        JSONRPCMessage(id: 'init-1', method: 'initialize', params: {
      'protocolVersion': '2024-11-05',
      'capabilities': {
        'roots': {'listChanged': true},
        'sampling': {}
      },
      'clientInfo': {'name': 'DartMCPClient', 'version': '1.0.0'}
    });

    Logger.root.info('初始化请求内容: ${jsonEncode(initMessage.toJson())}');

    try {
      final initResponse = await sendMessage(initMessage);
      Logger.root.info('初始化响应: $initResponse');

      // 等待一小段时间确保服务器已处理初始化请求
      await Future.delayed(const Duration(milliseconds: 100));

      // 发送初始化完成通知
      Logger.root.info('发送初始化完成通知');
      await _sendNotification('notifications/initialized', {});

      return initResponse;
    } catch (e, stack) {
      Logger.root.severe('初始化失败: $e\n$stack');
      rethrow;
    }
  }

  @override
  Future<JSONRPCMessage> sendPing() async {
    final message = JSONRPCMessage(id: 'ping-1', method: 'ping');
    return sendMessage(message);
  }

  @override
  Future<JSONRPCMessage> sendToolList() async {
    final message = JSONRPCMessage(id: 'tool-list-1', method: 'tools/list');
    return sendMessage(message);
  }

  @override
  Future<JSONRPCMessage> sendToolCall({
    required String name,
    required Map<String, dynamic> arguments,
    String? id,
  }) async {
    final message = JSONRPCMessage(
      method: 'tools/call',
      params: {
        'name': name,
        'arguments': arguments,
        '_meta': {'progressToken': 0},
      },
      id: id ?? 'tool-call-${DateTime.now().millisecondsSinceEpoch}',
    );

    return sendMessage(message);
  }

  // 添加一个实用方法来发送符合格式的通知
  Future<void> _sendNotification(
      String method, Map<String, dynamic> params) async {
    final notification = JSONRPCMessage(
      method: method,
      params: params,
    );

    await _sendHttpPost(notification.toJson());
  }
}
