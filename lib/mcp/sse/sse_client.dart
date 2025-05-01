import 'package:chatmcp/mcp/stdio/stdio_client.dart';
import 'package:synchronized/synchronized.dart';

import 'package:flutter_client_sse/constants/sse_request_type_enum.dart';
import 'package:flutter_client_sse/flutter_client_sse.dart'
    as flutter_client_sse;

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

  StreamSubscription? _sseSubscription;
  final _writeLock = Lock();
  String? _messageEndpoint;

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

  final Map<String, String> _sseHeaders = {
    'Accept': 'text/event-stream',
    'Cache-Control': 'no-cache',
    'Connection': 'keep-alive',
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

      _sseSubscription?.cancel();

      // Check if we need to update the session ID in the SSE connection URL
      String connectionUrl = serverConfig.command;

      // If previously connected and have a message endpoint that contains a session ID, try to update the connection URL
      if (_messageEndpoint != null) {
        try {
          final messageUri = Uri.parse(_messageEndpoint!);
          if (messageUri.queryParameters.containsKey('session_id')) {
            final sessionId = messageUri.queryParameters['session_id'];
            if (sessionId != null && sessionId.isNotEmpty) {
              Logger.root.info(
                  'Using current session ID for SSE connection: $sessionId');

              final originalUri = Uri.parse(connectionUrl);
              final Map<String, String> queryParams =
                  Map.from(originalUri.queryParameters);
              queryParams['session_id'] = sessionId;

              final updatedUri = Uri(
                scheme: originalUri.scheme,
                host: originalUri.host,
                path: originalUri.path,
                queryParameters: queryParams,
              );

              connectionUrl = updatedUri.toString();
              Logger.root.info('Updated SSE connection URL: $connectionUrl');
            }
          }
        } catch (e) {
          Logger.root
              .warning('Error attempting to update SSE connection URL: $e');
        }
      }

      Logger.root.info('Establishing SSE connection to: $connectionUrl');

      // Use flutter_client_sse library to establish SSE connection
      _sseSubscription = flutter_client_sse.SSEClient.subscribeToSSE(
        method: SSERequestType.GET,
        url: connectionUrl,
        header: _sseHeaders,
      ).listen(
        (event) {
          Logger.root.fine(
              'Received SSE event: ${event.event}, ID: ${event.id}, Data length: ${event.data?.length ?? 0}bytes');
          _handleSSEEvent(event);
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

      Logger.root.info(
          'SSE connection established successfully, waiting for events...');
      _reconnectAttempts = 0;
    } catch (e, stack) {
      Logger.root.severe('SSE connection failed: $e\n$stack');
      _processStateController.add(ProcessState.error(e, stack));
      _scheduleReconnect();
    } finally {
      _isConnecting = false;
    }
  }

  void _handleSSEEvent(flutter_client_sse.SSEModel event) {
    final eventType = event.event;
    final data = event.data;

    Logger.root.info('event: $eventType, data: $data');

    if (eventType == 'endpoint' && data != null) {
      final uri = Uri.parse(serverConfig.command);
      final baseUrl = uri.origin;
      // Process and normalize message endpoint URL, ensure no extra spaces
      String rawEndpoint;
      if (data.startsWith("http")) {
        rawEndpoint = data.trim();
      } else {
        final path = data.trim();
        rawEndpoint = baseUrl + (path.startsWith("/") ? path : "/$path");
      }

      try {
        // Validate that the message endpoint URL is valid
        final parsedUri = Uri.parse(rawEndpoint);
        if (!parsedUri.hasScheme || !parsedUri.hasAuthority) {
          Logger.root
              .severe('Received invalid message endpoint URL: $rawEndpoint');
          return;
        }

        _messageEndpoint = rawEndpoint;
        Logger.root
            .info('Successfully set message endpoint: $_messageEndpoint');
        _processStateController.add(const ProcessState.running());
      } catch (e) {
        Logger.root.severe(
            'Failed to parse message endpoint URL: $rawEndpoint, Error: $e');
      }
    } else if (eventType == 'message' && data != null) {
      try {
        final jsonData = jsonDecode(data);
        final message = JSONRPCMessage.fromJson(jsonData);
        _handleMessage(message);
      } catch (e, stack) {
        Logger.root.severe('Failed to parse server message: $e\n$stack');
      }
    } else {
      Logger.root.info('Received unhandled SSE event type: $eventType');
    }
  }

  void _scheduleReconnect() {
    if (_disposed || _isConnecting || _reconnectTimer != null) return;

    _reconnectAttempts++;
    if (_reconnectAttempts > _maxReconnectAttempts) {
      Logger.root.severe(
          'Reached maximum reconnection attempts ($_maxReconnectAttempts), stopping reconnection');
      return;
    }

    final delay = _initialReconnectDelay * (1 << (_reconnectAttempts - 1));
    Logger.root.info(
        'Planning to make reconnection attempt $_reconnectAttempts in ${delay.inSeconds} seconds');

    // Try to refresh the session ID before reconnecting
    _reconnectTimer = Timer(delay, () async {
      _reconnectTimer = null;

      // If message endpoint is established, try to refresh the session ID
      if (_messageEndpoint != null) {
        try {
          final refreshed = await _refreshSessionId();
          if (refreshed) {
            Logger.root
                .info('Successfully refreshed session ID before reconnection');
          } else {
            Logger.root.warning(
                'Failed to refresh session ID before reconnection, continuing with original session ID');
          }
        } catch (e) {
          Logger.root.warning(
              'Error occurred while refreshing session ID before reconnection: $e');
        }
      }

      _connect();
    });
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;

    // Cancel SSE subscription
    await _sseSubscription?.cancel();
    _sseSubscription = null;

    await _processStateController.close();
    _messageEndpoint = null;
  }

  Future<void> _sendHttpPost(Map<String, dynamic> data) async {
    if (_messageEndpoint == null) {
      throw StateError('Message endpoint not initialized ${jsonEncode(data)}');
    }

    await _writeLock.synchronized(() async {
      try {
        // Build URL and ensure it's valid
        final String cleanEndpoint = _messageEndpoint!.trim();
        Logger.root.info('Building HTTP request URL: $cleanEndpoint');

        // Parse URL to check and handle potential issues
        final uri = Uri.parse(cleanEndpoint);

        // Check if session_id exists in URL query parameters
        if (uri.queryParameters.containsKey('session_id')) {
          final sessionId = uri.queryParameters['session_id'];
          Logger.root.info('Detected session ID: $sessionId');

          // Validate if the session ID is valid (typically non-empty and a UUID of certain length)
          if (sessionId == null || sessionId.isEmpty || sessionId.length < 10) {
            Logger.root.warning(
                'Potentially invalid session ID: $sessionId, trying to get a new session ID');
            // Logic to get a new session ID can be added here
          }
        } else {
          Logger.root.warning('No session ID parameter detected in URL');
        }

        Logger.root.info(
            'Sending HTTP request to $cleanEndpoint: ${jsonEncode(data)}');

        final response = await http.post(
          Uri.parse(cleanEndpoint),
          headers: _headers,
          body: jsonEncode(data),
        );

        Logger.root.info('HTTP response status code: ${response.statusCode}');

        if (response.statusCode >= 400) {
          final errorBody = response.body;
          Logger.root
              .severe('HTTP POST failed: ${response.statusCode} - $errorBody');
          throw Exception(
              'MCP HTTP POST ERROR: ${response.statusCode} - $errorBody');
        } else {
          // Log successful response
          if (response.body.isNotEmpty) {
            Logger.root.info('HTTP response content: ${response.body}');
          }
        }
      } catch (e, stack) {
        Logger.root.severe('Failed to send HTTP POST: $e\n$stack');
        rethrow;
      }
    });
  }

  Future<bool> _refreshSessionId() async {
    // If there's no message endpoint, cannot refresh the session ID
    if (_messageEndpoint == null) {
      Logger.root.severe(
          'Attempted to refresh session ID but message endpoint is not yet established');
      return false;
    }

    try {
      Logger.root.info('Attempting to refresh session ID');

      // Extract the basic part of the original URL (excluding query parameters)
      final Uri originalUri = Uri.parse(_messageEndpoint!);
      final String baseUrl =
          '${originalUri.scheme}://${originalUri.host}${originalUri.path}';

      // Build URL to get a new session ID (needs to be adjusted based on actual API)
      final String sessionUrl = '$baseUrl?action=new_session';

      Logger.root.info('Requesting new session ID: $sessionUrl');

      // Send request to get a new session ID
      final response = await http.get(Uri.parse(sessionUrl));

      if (response.statusCode == 200) {
        try {
          final Map<String, dynamic> responseData = jsonDecode(response.body);
          final String? newSessionId = responseData['session_id'];

          if (newSessionId != null && newSessionId.isNotEmpty) {
            // Update the session ID in the message endpoint
            final Map<String, String> queryParams =
                Map.from(originalUri.queryParameters);
            queryParams['session_id'] = newSessionId;

            final Uri newUri = Uri(
              scheme: originalUri.scheme,
              host: originalUri.host,
              path: originalUri.path,
              queryParameters: queryParams,
            );

            _messageEndpoint = newUri.toString();
            Logger.root.info(
                'Successfully refreshed session ID, new message endpoint: $_messageEndpoint');
            return true;
          } else {
            Logger.root.severe(
                'Failed to get new session ID: No valid session ID in the response');
          }
        } catch (e) {
          Logger.root.severe('Error parsing session ID response: $e');
        }
      } else {
        Logger.root.severe(
            'Failed to get new session ID, status code: ${response.statusCode}, response: ${response.body}');
      }
    } catch (e, stack) {
      Logger.root
          .severe('Exception occurred while refreshing session ID: $e\n$stack');
    }

    return false;
  }

  @override
  Future<JSONRPCMessage> sendMessage(JSONRPCMessage message) async {
    if (message.id == null) {
      throw ArgumentError('Message must have an ID');
    }

    final completer = Completer<JSONRPCMessage>();
    _pendingRequests[message.id!] = completer;

    try {
      Logger.root
          .info('Preparing to send message: ${message.id} - ${message.method}');
      bool retried = false;

      // Try to send the request, if the session ID is invalid try to refresh it
      while (true) {
        try {
          await _sendHttpPost(message.toJson());
          break; // If successfully sent, exit the loop
        } catch (e) {
          // Check if this is an invalid session ID error
          if (!retried && e.toString().contains('Invalid session id')) {
            Logger.root.warning(
                'Detected invalid session ID, attempting to refresh session ID');
            retried = true;

            // Try to refresh the session ID
            bool refreshed = await _refreshSessionId();
            if (refreshed) {
              Logger.root
                  .info('Session ID has been refreshed, retrying message send');
              continue; // Retry sending the request
            }
          }
          // Other errors or session ID refresh failure, throw exception directly
          rethrow;
        }
      }

      return await completer.future.timeout(
        const Duration(seconds: 60 * 60),
        onTimeout: () {
          _pendingRequests.remove(message.id);
          throw TimeoutException('Request timeout: ${message.id}');
        },
      );
    } catch (e) {
      _pendingRequests.remove(message.id);
      rethrow;
    }
  }

  @override
  Future<JSONRPCMessage> sendInitialize() async {
    // Ensure connection is established
    if (_messageEndpoint == null) {
      Logger.root.warning(
          'Attempting to initialize but message endpoint not yet established, waiting for endpoint...');
      // Wait for a period to ensure SSE connection is established and endpoint is obtained
      int attempts = 0;
      const maxAttempts = 30; // Increased to 30 attempts
      const delay = Duration(milliseconds: 500);

      while (_messageEndpoint == null && attempts < maxAttempts) {
        await Future.delayed(delay);
        attempts++;
        Logger.root.info(
            'Waiting for message endpoint to be established: attempt $attempts/$maxAttempts');

        // If connection is closed or has errors, try to reconnect
        if (_disposed || _sseSubscription == null) {
          Logger.root
              .warning('SSE connection may be closed, attempting to reconnect');
          await _connect();
        }
      }

      if (_messageEndpoint == null) {
        Logger.root.severe(
            'Message endpoint still not established after ${maxAttempts * delay.inMilliseconds / 1000} seconds');
        throw StateError(
            'Message endpoint still not established after waiting, unable to complete initialization');
      }
    }

    Logger.root
        .info('Starting to send initialization request to $_messageEndpoint');

    // Send initialization request
    final initMessage =
        JSONRPCMessage(id: 'init-1', method: 'initialize', params: {
      'protocolVersion': '2024-11-05',
      'capabilities': {
        'roots': {'listChanged': true},
        'sampling': {}
      },
      'clientInfo': {'name': 'DartMCPClient', 'version': '1.0.0'}
    });

    Logger.root.info(
        'Initialization request content: ${jsonEncode(initMessage.toJson())}');

    try {
      final initResponse = await sendMessage(initMessage);
      Logger.root.info('Initialization response: $initResponse');

      // Wait a short period to ensure the server has processed the initialization request
      await Future.delayed(const Duration(milliseconds: 100));

      // Send initialization complete notification
      Logger.root.info('Sending initialization complete notification');
      await _sendNotification('notifications/initialized', {});

      return initResponse;
    } catch (e, stack) {
      Logger.root.severe('Initialization failed: $e\n$stack');
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

  // Add a utility method to send properly formatted notifications
  Future<void> _sendNotification(
      String method, Map<String, dynamic> params) async {
    final notification = JSONRPCMessage(
      method: method,
      params: params,
    );

    try {
      await _sendHttpPost(notification.toJson());
    } catch (e) {
      // If the error is about invalid session ID, try to refresh and retry once
      if (e.toString().contains('Invalid session id')) {
        Logger.root.warning(
            'Invalid session ID detected when sending notification, attempting to refresh session ID and retry');

        // Try to refresh the session ID
        bool refreshed = await _refreshSessionId();
        if (refreshed) {
          Logger.root.info(
              'Session ID has been refreshed, retrying notification send');
          await _sendHttpPost(notification.toJson());
        } else {
          Logger.root.severe(
              'Failed to refresh session ID, unable to send notification: $method');
          rethrow;
        }
      } else {
        // Throw other errors directly
        rethrow;
      }
    }
  }
}
