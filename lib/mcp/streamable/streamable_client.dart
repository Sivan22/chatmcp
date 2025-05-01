import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';
import '../models/json_rpc_message.dart';
import '../models/server.dart';
import '../client/mcp_client_interface.dart';

/// 自定义错误类，用于Streamable HTTP连接错误
class StreamableHTTPError extends Error {
  final int? code;
  final String message;

  StreamableHTTPError(this.code, this.message);

  @override
  String toString() => 'Streamable HTTP error: $message';
}

/// 未授权错误
class UnauthorizedError extends Error {
  final String message;

  UnauthorizedError([this.message = "Unauthorized"]);

  @override
  String toString() => 'Unauthorized error: $message';
}

/// 重连选项配置
class StreamableHTTPReconnectionOptions {
  /// 初始重连延迟（毫秒）
  final int initialReconnectionDelay;

  /// 最大重连延迟（毫秒）
  final int maxReconnectionDelay;

  /// 重连延迟增长因子
  final double reconnectionDelayGrowFactor;

  /// 最大重试次数
  final int maxRetries;

  const StreamableHTTPReconnectionOptions({
    this.initialReconnectionDelay = 1000,
    this.maxReconnectionDelay = 30000,
    this.reconnectionDelayGrowFactor = 1.5,
    this.maxRetries = 2,
  });
}

/// SSE连接选项
class StartSSEOptions {
  /// 恢复令牌，用于继续被中断的长时间运行的请求
  final String? resumptionToken;

  /// 当恢复令牌改变时调用的回调
  final Function(String)? onResumptionToken;

  /// 覆盖与重播消息关联的消息ID
  final String? replayMessageId;

  StartSSEOptions({
    this.resumptionToken,
    this.onResumptionToken,
    this.replayMessageId,
  });
}

/// Streamable HTTP客户端实现
class StreamableClient implements McpClient {
  @override
  final ServerConfig serverConfig;

  /// HTTP客户端
  final http.Client _httpClient = http.Client();

  /// 服务器URL
  late final String _url;

  /// 会话ID
  String? _sessionId;

  /// 用于中止请求的控制器
  StreamController<bool>? _abortController;

  /// 重连选项
  final StreamableHTTPReconnectionOptions _reconnectionOptions;

  /// 已尝试的重连次数
  int _reconnectionAttempts = 0;

  /// 消息处理回调
  Function(JSONRPCMessage)? onMessage;

  /// 错误处理回调
  Function(Object)? onError;

  /// 关闭连接回调
  Function()? onClose;

  StreamableClient({
    required this.serverConfig,
    StreamableHTTPReconnectionOptions? reconnectionOptions,
  }) : _reconnectionOptions =
            reconnectionOptions ?? const StreamableHTTPReconnectionOptions() {
    if (serverConfig.command.startsWith('http')) {
      _url = serverConfig.command;
    } else {
      throw ArgumentError('URL is required for StreamableClient');
    }
  }

  /// 获取通用HTTP头
  Future<Map<String, String>> _commonHeaders() async {
    final headers = <String, String>{
      'Accept': 'application/json',
      'Content-Type': 'application/json',
    };

    if (_sessionId != null) {
      headers['mcp-session-id'] = _sessionId!;
    }

    // 如果有授权信息，可以在这里添加

    return headers;
  }

  /// 启动或授权SSE连接
  Future<void> _startOrAuthSse(StartSSEOptions options) async {
    try {
      final headers = await _commonHeaders();

      // 添加Last-Event-ID头，如果有恢复令牌
      if (options.resumptionToken != null) {
        headers['Last-Event-ID'] = options.resumptionToken!;
      }

      // 设置接受SSE流
      headers['Accept'] = 'text/event-stream';

      final request = http.Request('GET', Uri.parse(_url));
      request.headers.addAll(headers);

      final response = await _httpClient.send(request);

      if (!response.statusCode.toString().startsWith('2')) {
        if (response.statusCode == 401) {
          // 授权失败处理
          throw UnauthorizedError();
        }

        throw StreamableHTTPError(
          response.statusCode,
          'Failed to connect to SSE stream: ${response.reasonPhrase}',
        );
      }

      // 处理会话ID
      final responseHeaders = response.headers;
      if (responseHeaders.containsKey('mcp-session-id')) {
        final sessionIdValue = responseHeaders['mcp-session-id'];
        if (sessionIdValue != null) {
          _sessionId = sessionIdValue;
        }
      }

      // 处理SSE流
      _handleSseStream(response.stream, options);
    } catch (error) {
      onError?.call(error);
      rethrow;
    }
  }

  /// 计划重连
  void _scheduleReconnection(StartSSEOptions options, int attemptIndex) {
    if (attemptIndex >= _reconnectionOptions.maxRetries) {
      onError?.call(Exception('Maximum reconnection attempts reached'));
      return;
    }

    final delay = _calculateReconnectionDelay(attemptIndex);

    Future.delayed(Duration(milliseconds: delay), () {
      if (_abortController == null || _abortController!.isClosed) {
        return; // 已关闭，不再重连
      }

      // 尝试重连
      _startOrAuthSse(options).catchError((error) {
        _reconnectionAttempts++;
        _scheduleReconnection(options, attemptIndex + 1);
      });
    });
  }

  /// 计算重连延迟
  int _calculateReconnectionDelay(int attemptIndex) {
    final delay = _reconnectionOptions.initialReconnectionDelay *
        _reconnectionOptions.reconnectionDelayGrowFactor.pow(attemptIndex);

    return delay
        .clamp(
          _reconnectionOptions.initialReconnectionDelay.toDouble(),
          _reconnectionOptions.maxReconnectionDelay.toDouble(),
        )
        .toInt();
  }

  /// 处理SSE流
  void _handleSseStream(Stream<List<int>> stream, StartSSEOptions options) {
    final onResumptionToken = options.onResumptionToken;
    final replayMessageId = options.replayMessageId;
    String? lastEventId;

    // 解码UTF-8并拆分为行
    final lineStream =
        stream.transform(utf8.decoder).transform(const LineSplitter());

    // SSE处理变量
    String? eventName;
    String data = '';
    String id = '';

    // 订阅处理
    final subscription = lineStream.listen(
      (line) {
        if (line.isEmpty) {
          // 空行表示事件结束
          if (data.isNotEmpty) {
            // 处理事件
            if (id.isNotEmpty) {
              lastEventId = id;
              onResumptionToken?.call(id);
            }

            if (eventName == null || eventName == 'message') {
              try {
                final parsed = jsonDecode(data);
                final message = JSONRPCMessage.fromJson(parsed);

                // 如果需要替换消息ID
                if (replayMessageId != null && message.id != null) {
                  // 由于无法直接访问私有字段，我们创建一个新的消息对象
                  final newMessage = JSONRPCMessage(
                    id: replayMessageId,
                    method: message.method,
                    params: message.params,
                    result: message.result,
                    error: message.error,
                  );
                  onMessage?.call(newMessage);
                } else {
                  onMessage?.call(message);
                }
              } catch (error) {
                onError?.call(error);
              }
            }
          }

          // 重置事件数据
          eventName = null;
          data = '';
          id = '';
        } else if (line.startsWith('event:')) {
          eventName = line.substring(6).trim();
        } else if (line.startsWith('data:')) {
          data += line.substring(5).trim();
        } else if (line.startsWith('id:')) {
          id = line.substring(3).trim();
        }
      },
      onError: (error) {
        onError?.call(error);

        // 尝试重连
        if (_abortController != null && !_abortController!.isClosed) {
          if (lastEventId != null) {
            try {
              _scheduleReconnection(
                StartSSEOptions(
                  resumptionToken: lastEventId,
                  onResumptionToken: onResumptionToken,
                  replayMessageId: replayMessageId,
                ),
                0,
              );
            } catch (reconnectError) {
              onError?.call(Exception('Failed to reconnect: $reconnectError'));
            }
          }
        }
      },
      onDone: () {
        // 如果流正常关闭，也尝试重连
        if (_abortController != null && !_abortController!.isClosed) {
          if (lastEventId != null) {
            try {
              _scheduleReconnection(
                StartSSEOptions(
                  resumptionToken: lastEventId,
                  onResumptionToken: onResumptionToken,
                  replayMessageId: replayMessageId,
                ),
                0,
              );
            } catch (reconnectError) {
              onError?.call(Exception('Failed to reconnect: $reconnectError'));
            }
          }
        }
      },
      cancelOnError: false,
    );

    // 当中止控制器关闭时，取消订阅
    _abortController?.stream.listen((_) {
      subscription.cancel();
    });
  }

  /// 启动客户端连接
  @override
  Future<void> initialize() async {
    if (_abortController != null) {
      throw Exception('StreamableClient already started!');
    }

    _abortController = StreamController<bool>();
  }

  /// 关闭客户端连接
  @override
  Future<void> dispose() async {
    _abortController?.add(true);
    await _abortController?.close();
    _abortController = null;
    _httpClient.close();
    onClose?.call();
  }

  /// 发送消息到服务器
  @override
  Future<JSONRPCMessage> sendMessage(JSONRPCMessage message) async {
    try {
      final headers = await _commonHeaders();
      final completer = Completer<JSONRPCMessage>();

      final response = await _httpClient.post(
        Uri.parse(_url),
        headers: headers,
        body: jsonEncode(message.toJson()),
      );

      // 处理会话ID
      final sessionIdValue = response.headers['mcp-session-id'];
      if (sessionIdValue != null && sessionIdValue.isNotEmpty) {
        _sessionId = sessionIdValue;
      }

      if (!response.statusCode.toString().startsWith('2')) {
        if (response.statusCode == 401) {
          // 授权失败处理
          throw UnauthorizedError();
        }

        throw StreamableHTTPError(
          response.statusCode,
          'Error POSTing to endpoint (HTTP ${response.statusCode}): ${response.body}',
        );
      }

      // 如果响应是202 Accepted，没有主体需要处理
      if (response.statusCode == 202) {
        // 如果是initialized通知，我们启动SSE流
        if (message.method == 'notifications/initialized') {
          _startOrAuthSse(StartSSEOptions()).catchError((error) {
            onError?.call(error);
          });
        }

        // 创建一个默认的成功响应
        final successResponse = JSONRPCMessage(
          id: message.id,
          method: '', // 添加空字符串作为默认method值
          result: {'success': true},
        );

        return successResponse;
      }

      // 检查响应类型
      final contentType = response.headers['content-type'];

      if (message.id != null) {
        if (contentType?.contains('text/event-stream') == true) {
          // 为请求处理SSE流响应
          _handleSseStream(
            Stream.value(response.bodyBytes),
            StartSSEOptions(),
          );

          // 创建一个监听器等待响应
          onMessage = (responseMessage) {
            if (responseMessage.id == message.id && !completer.isCompleted) {
              completer.complete(responseMessage);
            }
          };

          // 设置超时
          return completer.future.timeout(
            const Duration(seconds: 30),
            onTimeout: () {
              throw TimeoutException('Request timed out: ${message.id}');
            },
          );
        } else if (contentType?.contains('application/json') == true) {
          // 对于非流式服务器，我们可能会得到直接的JSON响应
          final data = jsonDecode(response.body);

          if (data is List) {
            for (final item in data) {
              final msg = JSONRPCMessage.fromJson(item);
              if (msg.id == message.id) {
                return msg;
              }
            }
          } else {
            return JSONRPCMessage.fromJson(data);
          }
        }
      }

      throw StreamableHTTPError(
        -1,
        'Unexpected response or content type: $contentType',
      );
    } catch (error) {
      onError?.call(error);
      rethrow;
    }
  }

  @override
  Future<JSONRPCMessage> sendInitialize() async {
    // 发送初始化请求
    final initMessage = JSONRPCMessage(
      id: 'init-1',
      method: 'initialize',
      params: {
        'protocolVersion': '2024-11-05',
        'capabilities': {
          'roots': {'listChanged': true},
          'sampling': {}
        },
        'clientInfo': {
          'name': 'DartMCPStreamableClient',
          'version': '1.0.0',
        }
      },
    );

    final initResponse = await sendMessage(initMessage);
    Logger.root.info('Initialization request response: $initResponse');

    // 发送初始化完成通知
    final notifyMessage = JSONRPCMessage(
      method: 'notifications/initialized',
      params: {},
    );

    await sendMessage(notifyMessage);
    return initResponse;
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

  /// 终止当前会话
  Future<void> terminateSession() async {
    if (_sessionId == null) {
      return; // 没有会话需要终止
    }

    try {
      final headers = await _commonHeaders();

      final response = await _httpClient.delete(
        Uri.parse(_url),
        headers: headers,
      );

      // 我们特别处理405作为有效响应
      if (!response.statusCode.toString().startsWith('2') &&
          response.statusCode != 405) {
        throw StreamableHTTPError(
          response.statusCode,
          'Failed to terminate session: ${response.reasonPhrase}',
        );
      }

      _sessionId = null;
    } catch (error) {
      onError?.call(error);
      rethrow;
    }
  }
}

// 用于num类型的pow方法扩展
extension NumExtension on num {
  double pow(int exponent) {
    double result = 1.0;
    for (int i = 0; i < exponent; i++) {
      result *= this;
    }
    return result;
  }
}
