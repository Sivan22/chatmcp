import 'dart:async';
import 'dart:typed_data';
import 'package:chatmcp/llm/prompt.dart';
import 'package:chatmcp/utils/platform.dart';
import 'package:flutter/material.dart';
import 'package:chatmcp/llm/model.dart';
import 'package:chatmcp/llm/llm_factory.dart';
import 'package:chatmcp/llm/base_llm_client.dart';
import 'package:chatmcp/llm/function_calling.dart' as fc;
import 'package:flutter/rendering.dart';
import 'package:logging/logging.dart';
import 'package:file_picker/file_picker.dart';
import 'input_area.dart';
import 'package:chatmcp/provider/provider_manager.dart';
import 'package:chatmcp/dao/chat.dart';
import 'package:uuid/uuid.dart';
import 'chat_message_list.dart';
import 'package:chatmcp/utils/color.dart';
import 'package:chatmcp/widgets/widgets_to_image/utils.dart';
import 'chat_message_to_image.dart';
import 'package:chatmcp/utils/event_bus.dart';
import 'chat_code_preview.dart';
import 'package:chatmcp/generated/app_localizations.dart';
import 'dart:convert';

class ChatPage extends StatefulWidget {
  const ChatPage({super.key});

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  // 状态变量
  bool _showCodePreview = false;
  Chat? _chat;
  List<ChatMessage> _messages = [];
  bool _isComposing = false; // 是否正在输入
  BaseLLMClient? _llmClient;
  String _currentResponse = '';
  bool _isLoading = false; // 是否正在加载
  String _parentMessageId = ''; // 父消息ID
  bool _isCancelled = false; // 是否取消
  bool _isWating = false; // 是否正在补全
  bool _isFinalAnswerReceived = false; // 是否收到最终答案

  WidgetsToImageController toImagecontroller = WidgetsToImageController();
  // to save image bytes of widget
  Uint8List? bytes;

  bool mobile = kIsMobile;

  @override
  void initState() {
    super.initState();
    _initializeState();
    on<CodePreviewEvent>(_onArtifactEvent);
    on<ShareEvent>(_handleShare);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_isMobile() != mobile) {
        setState(() {
          mobile = _isMobile();
          _showCodePreview = false;
        });
      }
      if (!mobile && showModalCodePreview) {
        setState(() {
          Navigator.pop(context);
          showModalCodePreview = false;
        });
      }
    });
  }

  @override
  void dispose() {
    _removeListeners();
    super.dispose();
  }

  // 初始化相关方法
  void _initializeState() {
    _initializeLLMClient();
    _addListeners();
    _initializeHistoryMessages();
    on<RunFunctionEvent>(_onRunFunction);
    on<fc.AskFollowupQuestionEvent>(_onAskFollowupQuestion);
    on<fc.FinalAnswerEvent>(_onFinalAnswer);
  }

  RunFunctionEvent? _runFunctionEvent;
  fc.AskFollowupQuestionEvent? _askFollowupQuestionEvent;
  fc.FinalAnswerEvent? _finalAnswerEvent;
  bool _isRunningFunction = false;
  bool _userApproved = false;
  bool _userRejected = false;

  Future<void> _onAskFollowupQuestion(fc.AskFollowupQuestionEvent event) async {
    setState(() {
      _askFollowupQuestionEvent = event;
      _isLoading = false; // Stop loading state to allow user input
      _isWating = false; // Stop waiting state
      _isFinalAnswerReceived =
          true; // Stop the flow, just like with final_answer
    });

    // Get the question and options from the event
    final question = event.question;
    final options = event.options;

    // If the last message exists and is from the assistant, update it
    if (_messages.isNotEmpty && _messages.last.role == MessageRole.assistant) {
      // Get the original content that contains the function call
      final originalContent = _messages.last.content ?? '';

      // Generate a user-friendly display of the question and options
      String displayText = '';

      // Add the question
      if (question.isNotEmpty) {
        displayText = '\n\n**Question:** $question';
      }

      // Add options if available
      if (options != null && options.isNotEmpty) {
        displayText += '\n\n**Options:**';
        for (int i = 0; i < options.length; i++) {
          displayText += '\n- ${options[i]}';
        }
      }

      // Format the content to preserve the function call and add the user-friendly version
      String formattedContent = originalContent + displayText;

      // Update the existing message with the formatted content
      _messages.last = _messages.last.copyWith(
        content: formattedContent,
      );

      // parentMessageId remains the same since we're modifying the existing message
    }

    // Wait for user response in the next handleSubmitted call
  }

  Future<void> _onFinalAnswer(fc.FinalAnswerEvent event) async {
    setState(() {
      _finalAnswerEvent = event;
      _isFinalAnswerReceived = true;
    });

    final msgId = Uuid().v4();
    final answer = event.answer;

    // Add the final answer as an assistant message
    _messages.add(ChatMessage(
      messageId: msgId,
      content: answer,
      role: MessageRole.assistant,
      parentMessageId: _parentMessageId,
      isFinalAnswer: true,
    ));
    _parentMessageId = msgId;
  }

  Future<void> _onRunFunction(RunFunctionEvent event) async {
    setState(() {
      _userApproved = false;
      _userRejected = false;
      _runFunctionEvent = event;
    });

    // 显示授权对话框
    // if (mounted) {
    //   await _showFunctionApprovalDialog(event);
    // }

    if (!_isLoading) {
      _handleSubmitted(SubmitData("", []), addUserMessage: false);
    }
  }

  Future<bool> _showFunctionApprovalDialog(RunFunctionEvent event) async {
    // 检查工具名称的前缀以确定是哪个服务器的工具
    final clientName =
        _findClientName(ProviderManager.mcpServerProvider.tools, event.name);
    if (clientName == null) return false;

    final serverConfig = await ProviderManager.mcpServerProvider.loadServers();
    final servers = serverConfig['mcpServers'] as Map<String, dynamic>? ?? {};

    if (servers.containsKey(clientName)) {
      final config = servers[clientName] as Map<String, dynamic>? ?? {};
      final autoApprove = config['auto_approve'] as bool? ?? false;

      // 如果设置了自动批准，直接返回true
      if (autoApprove) {
        return true;
      }
    }

    // 否则显示授权对话框
    var t = AppLocalizations.of(context)!;
    return await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (BuildContext context) {
            return AlertDialog(
              title: Text(t.functionCallAuth),
              content: SingleChildScrollView(
                child: ListBody(
                  children: <Widget>[
                    Text(t.allowFunctionExecution),
                    SizedBox(height: 8),
                    Text(event.name),
                    SizedBox(height: 8),
                  ],
                ),
              ),
              actions: <Widget>[
                TextButton(
                  child: Text(t.cancel),
                  onPressed: () {
                    setState(() {
                      _userRejected = true;
                      _runFunctionEvent = null;
                    });
                    Navigator.of(context).pop(false);
                  },
                ),
                TextButton(
                  child: Text(t.allow),
                  onPressed: () {
                    setState(() {
                      _userApproved = true;
                    });
                    Navigator.of(context).pop(true);
                  },
                ),
              ],
            );
          },
        ) ??
        false;
  }

  void _addListeners() {
    ProviderManager.settingsProvider.addListener(_onSettingsChanged);
    ProviderManager.chatModelProvider.addListener(_initializeLLMClient);
    ProviderManager.chatProvider.addListener(_onChatProviderChanged);
  }

  void _removeListeners() {
    ProviderManager.settingsProvider.removeListener(_onSettingsChanged);
    ProviderManager.chatProvider.removeListener(_onChatProviderChanged);
  }

  void _initializeLLMClient() {
    _llmClient = LLMFactoryHelper.createFromModel(
        ProviderManager.chatModelProvider.currentModel);
    setState(() {});
  }

  void _onSettingsChanged() {
    _initializeLLMClient();
  }

  void _onChatProviderChanged() {
    _initializeHistoryMessages();
  }

  List<ChatMessage> _allMessages = [];

  Future<List<ChatMessage>> _getHistoryTreeMessages() async {
    final activeChat = ProviderManager.chatProvider.activeChat;
    if (activeChat == null) return [];

    Map<String, List<String>> messageMap = {};

    final messages = await activeChat.getChatMessages();

    for (var message in messages) {
      if (message.role == MessageRole.user) {
        continue;
      }
      if (messageMap[message.parentMessageId] == null) {
        messageMap[message.parentMessageId] = [];
      }

      messageMap[message.parentMessageId]?.add(message.messageId);
    }

    for (var message in messages) {
      final brotherIds = messageMap[message.messageId] ?? [];

      if (brotherIds.length > 1) {
        int index =
            messages.indexWhere((m) => m.messageId == message.messageId);
        if (index != -1) {
          messages[index].childMessageIds ??= brotherIds;
        }

        for (var brotherId in brotherIds) {
          final index = messages.indexWhere((m) => m.messageId == brotherId);
          if (index != -1) {
            messages[index].brotherMessageIds ??= brotherIds;
          }
        }
      }
    }

    setState(() {
      _allMessages = messages;
    });

    // print('messages:\n${const JsonEncoder.withIndent('  ').convert(messages)}');

    final lastMessage = messages.last;
    return _getTreeMessages(lastMessage.messageId, messages);
  }

  List<ChatMessage> _getTreeMessages(
      String messageId, List<ChatMessage> messages) {
    final lastMessage = messages.firstWhere((m) => m.messageId == messageId);
    List<ChatMessage> treeMessages = [];

    ChatMessage? currentMessage = lastMessage;
    while (currentMessage != null) {
      if (currentMessage.role != MessageRole.user) {
        final childMessageIds = currentMessage.childMessageIds;
        if (childMessageIds != null && childMessageIds.isNotEmpty) {
          for (var childId in childMessageIds.reversed) {
            final childMessage = messages.firstWhere(
              (m) => m.messageId == childId,
              orElse: () => ChatMessage(content: '', role: MessageRole.user),
            );
            if (treeMessages
                .any((m) => m.messageId == childMessage.messageId)) {
              continue;
            }
            treeMessages.insert(0, childMessage);
          }
        }
      }

      treeMessages.insert(0, currentMessage);

      final parentId = currentMessage.parentMessageId;
      if (parentId == null || parentId.isEmpty) break;

      currentMessage = messages.firstWhere(
        (m) => m.messageId == parentId,
        orElse: () => ChatMessage(
          messageId: '',
          content: '',
          role: MessageRole.user,
          parentMessageId: '',
        ),
      );

      if (currentMessage.messageId.isEmpty) break;
    }

    // print('messageId: ${lastMessage.messageId}');

    // Find all direct child messages (not just user messages)
    ChatMessage? nextMessage = messages.firstWhere(
      (m) => m.parentMessageId == lastMessage.messageId,
      orElse: () =>
          ChatMessage(messageId: '', content: '', role: MessageRole.user),
    );

    // print(
    // 'nextMessage:\n${const JsonEncoder.withIndent('  ').convert(nextMessage)}');

    while (nextMessage != null && nextMessage.messageId.isNotEmpty) {
      if (!treeMessages.any((m) => m.messageId == nextMessage!.messageId)) {
        treeMessages.add(nextMessage);
      }
      final childMessageIds = nextMessage.childMessageIds;
      if (childMessageIds != null && childMessageIds.isNotEmpty) {
        for (var childId in childMessageIds) {
          final childMessage = messages.firstWhere(
            (m) => m.messageId == childId,
            orElse: () =>
                ChatMessage(messageId: '', content: '', role: MessageRole.user),
          );
          if (treeMessages.any((m) => m.messageId == childMessage.messageId)) {
            continue;
          }
          treeMessages.add(childMessage);
        }
      }

      nextMessage = messages.firstWhere(
        (m) => m.parentMessageId == nextMessage!.messageId,
        orElse: () =>
            ChatMessage(messageId: '', content: '', role: MessageRole.user),
      );
    }

    // print(
    //     'treeMessages:\n${const JsonEncoder.withIndent('  ').convert(treeMessages)}');
    return treeMessages;
  }

  // 消息处理相关方法
  Future<void> _initializeHistoryMessages() async {
    final activeChat = ProviderManager.chatProvider.activeChat;
    setState(() {
      _showCodePreview = false;
    });
    if (activeChat == null) {
      setState(() {
        _messages = [];
        _chat = null;
        _parentMessageId = '';
        _runFunctionEvent = null;
        _isRunningFunction = false;
        _userApproved = false;
        _userRejected = false;
        _isFinalAnswerReceived = false; // Reset the final answer flag
      });
      return;
    }
    if (_chat?.id != activeChat.id) {
      final messages = await _getHistoryTreeMessages();
      // 找到最后一条用户消息的索引
      final lastUserIndex =
          messages.lastIndexWhere((m) => m.role == MessageRole.user);
      String parentId = '';

      // 如果找到用户消息，且其后有助手消息，则使用助手消息的ID
      if (lastUserIndex != -1 && lastUserIndex + 1 < messages.length) {
        parentId = messages[lastUserIndex + 1].messageId;
      } else if (messages.isNotEmpty) {
        // 如果没有找到合适的消息，使用最后一条消息的ID
        parentId = messages.last.messageId;
      }

      setState(() {
        _messages = messages;
        _chat = activeChat;
        _parentMessageId = parentId;
        _runFunctionEvent = null;
        _isRunningFunction = false;
        _userApproved = false;
        _userRejected = false;
        _isFinalAnswerReceived =
            false; // Also reset final answer flag when switching chats
      });
    }
  }

  // UI 构建相关方法
  Widget _buildMessageList() {
    if (_messages.isEmpty) {
      final l10n = AppLocalizations.of(context)!;
      return Expanded(
        child: Container(
          color: AppColors.transparent,
          child: Center(
            child: Text(
              l10n.welcomeMessage,
              style: TextStyle(
                fontSize: 18,
                color: AppColors.getWelcomeMessageColor(),
              ),
            ),
          ),
        ),
      );
    }

    final parentMsgIndex = _messages.length - 1;

    return Expanded(
      child: MessageList(
        messages: _isWating
            ? [
                ..._messages,
                ChatMessage(content: '', role: MessageRole.loading)
              ]
            : _messages.toList(),
        onRetry: _onRetry,
        onSwitch: _onSwitch,
      ),
    );
  }

  void _onSwitch(String messageId) {
    final messages = _getTreeMessages(messageId, _allMessages);
    setState(() {
      _messages = messages;
    });
  }

  // 消息处理相关方法
  void _handleTextChanged(String text) {
    setState(() {
      _isComposing = text.isNotEmpty;
    });
  }

  String? _findClientName(
      Map<String, List<Map<String, dynamic>>> tools, String toolName) {
    for (var entry in tools.entries) {
      final clientTools = entry.value;
      if (clientTools.any((tool) => tool['name'] == toolName)) {
        return entry.key;
      }
    }
    return null;
  }

  Future<void> _sendToolCallAndProcessResponse(
      String toolName, Map<String, dynamic> toolArguments) async {
    final clientName =
        _findClientName(ProviderManager.mcpServerProvider.tools, toolName);
    if (clientName == null) return;

    final mcpClient = ProviderManager.mcpServerProvider.getClient(clientName);
    if (mcpClient == null) return;

    try {
      final response = await mcpClient.sendToolCall(
        name: toolName,
        arguments: toolArguments,
      );

      setState(() {
        _currentResponse = response.result['content'].toString();
        // We'll only add the message once here - the main loop doesn't need to add it again
        if (_currentResponse.isNotEmpty) {
          // that triggered the function call
          final msgId = Uuid().v4();
          _messages.add(ChatMessage(
            messageId: msgId,
            content:
                "<call_function_result name=\"$toolName\">\n$_currentResponse\n</call_function_result>",
            // This is a user message containing the function result
            role: MessageRole.user,
            name: toolName,
            toolCallId: toolName,
            parentMessageId: _parentMessageId,
          ));
          // Update the parent message ID for the next message
          _parentMessageId = msgId;
        }
      });
    } on TimeoutException catch (error) {
      // Specifically handle timeout exceptions from SSE client
      Logger.root.severe('MCP tool call timed out: $error');

      // Import the function_calling.dart utility for timeout message
      final timeoutMessage = fc.generateToolCallTimeoutMessage(toolName);

      setState(() {
        _currentResponse = timeoutMessage;

        // Add the timeout message as a user message to continue conversation
        final msgId = Uuid().v4();
        _messages.add(ChatMessage(
          messageId: msgId,
          content:
              "<call_function_result name=\"$toolName\">\n$timeoutMessage\n</call_function_result>",
          role: MessageRole.user,
          name: toolName,
          toolCallId: toolName,
          parentMessageId: _parentMessageId,
        ));
        // Update the parent message ID for the next message
        _parentMessageId = msgId;
      });
    } catch (error) {
      // Handle other exceptions from MCP clients
      Logger.root.severe('MCP tool call failed: $error');

      // Generate a generic error message
      final errorMessage =
          "Error calling tool '$toolName': ${error.toString()}";

      setState(() {
        _currentResponse = errorMessage;

        // Add the error message as a user message to continue conversation
        final msgId = Uuid().v4();
        _messages.add(ChatMessage(
          messageId: msgId,
          content:
              "<call_function_result name=\"$toolName\">\n$errorMessage\n</call_function_result>",
          role: MessageRole.user,
          name: toolName,
          toolCallId: toolName,
          parentMessageId: _parentMessageId,
        ));

        // Update the parent message ID for the next message
        _parentMessageId = msgId;
      });
    }
  }

  ChatMessage? _findUserMessage(ChatMessage message) {
    final parentMessage = _messages.firstWhere(
      (m) => m.messageId == message.parentMessageId,
      orElse: () =>
          ChatMessage(messageId: '', content: '', role: MessageRole.user),
    );

    if (parentMessage.messageId.isEmpty) return null;

    if (parentMessage.role != MessageRole.user) {
      return _findUserMessage(parentMessage);
    }

    return parentMessage;
  }

  Future<void> _onRetry(ChatMessage message) async {
    final userMessage = _findUserMessage(message);
    if (userMessage == null) return;

    final messageIndex = _messages.indexOf(userMessage);
    if (messageIndex == -1) return;

    final previousMessages = _messages.sublist(0, messageIndex + 1);

    setState(() {
      _messages = previousMessages;
      _parentMessageId = userMessage.messageId;
      _isLoading = true;
      _isFinalAnswerReceived =
          false; // Reset the final answer flag when retrying
    });

    await _handleSubmitted(
      SubmitData(
        userMessage.content ?? '',
        (userMessage.files ?? []).map((f) => f as PlatformFile).toList(),
      ),
      addUserMessage: false,
    );
  }

  Future<bool> _checkNeedToolCallXml() async {
    Logger.root.info('Checking for tool calls in XML format...');

    // If there's a pending function event, we should process it first
    if (_runFunctionEvent != null) {
      Logger.root
          .info('Found pending function event: ${_runFunctionEvent!.name}');
      return true;
    }

    final lastMessage = _messages.last;
    // Check if the last message is from a user and if it's a tool result that's already been processed
    if (lastMessage.role == MessageRole.user) {
      // Skip processing if this is a tool result message that we've already added
      if (lastMessage.toolCallId != null) {
        Logger.root.info(
            'Last message is a tool result that was already processed, skipping duplicate processing');
        return false;
      }
      Logger.root.info('Last message is from user, need to process it');
      return true;
    }

    final content = lastMessage.content ?? '';
    if (content.isEmpty) {
      Logger.root.info('Last message content is empty, no tool calls');
      return false;
    }

    // 使用正则表达式检查是否包含 <function name=*>*</function> 格式的标签
    final RegExp functionTagRegex = RegExp(
        '<function\\s+name=["\']([^"\']*)["\']\\s*>(.*?)</function>',
        dotAll: true);
    final match = functionTagRegex.firstMatch(content);

    if (match == null) {
      Logger.root.info('No function tags found in content');
      return false;
    }

    final toolName = match.group(1);
    final toolArguments = match.group(2);

    if (toolName == null || toolArguments == null) {
      Logger.root.info('Found function tag but missing name or arguments');
      return false;
    }

    Logger.root.info('Found tool call: $toolName');

    // Check for built-in tool calls
    if (toolName == 'final_answer') {
      // Parse the final answer content
      final answerMap = json.decode(toolArguments);
      final finalAnswer = answerMap['answer'] as String? ?? '';
      final command = answerMap['command'] as String?;

      Logger.root.info('Found final_answer tool call');

      // Create the FinalAnswerEvent
      final event = fc.FinalAnswerEvent(finalAnswer, command);
      _onFinalAnswer(event);

      return false; // Return false to stop the tool calling loop
    } else if (toolName == 'followup_question') {
      // Parse the question content
      final questionMap = json.decode(toolArguments);
      final question = questionMap['question'] as String? ?? '';
      final options = questionMap['options'] as List<dynamic>?;

      List<String>? optionsList;
      if (options != null) {
        optionsList = options.map((option) => option.toString()).toList();
      }

      Logger.root.info('Found followup_question tool call');

      // Create the AskFollowupQuestionEvent
      final event = fc.AskFollowupQuestionEvent(question, optionsList);
      _onAskFollowupQuestion(event);

      // We should wait for user input, so stop the tool calling loop
      return false;
    }

    // Process regular tool call
    Logger.root.info('Processing regular tool call: $toolName');
    final toolArgumentsMap = json.decode(toolArguments);

    // Create the run function event but don't trigger _onRunFunction here
    // This will be handled by the main handleSubmitted loop
    _runFunctionEvent = RunFunctionEvent(toolName, toolArgumentsMap);

    return true;
  }

  Future<bool> _checkNeedToolCall() async {
    return await _checkNeedToolCallXml();
  }

  // 消息提交处理

  Future<void> _handleSubmitted(SubmitData data,
      {bool addUserMessage = true}) async {
    setState(() {
      _isCancelled = false;
      _isFinalAnswerReceived =
          false; // Reset the final answer flag at the start
    });

    try {
      //first, insert user message
      if (addUserMessage) {
        final msgId = Uuid().v4();
        _messages.add(ChatMessage(
          messageId: msgId,
          content: data.text,
          role: MessageRole.user,
          parentMessageId: _parentMessageId,
        ));
        _parentMessageId = msgId;
      }

      // Continue tool call cycle until final_answer is received
      bool shouldContinue = true;
      int iterationCount = 0;
      final maxIterations = 100; // Safeguard against infinite loops

      // Main loop - will keep running until we get a final answer or there's no more tool calls
      do {
        iterationCount++;
        Logger.root.info('Starting tool call cycle iteration $iterationCount');

        // Break out if we've exceeded max iterations (safety measure)
        if (iterationCount > maxIterations) {
          Logger.root.warning(
              'Exceeded maximum tool call iterations ($maxIterations). Breaking loop.');

          // Add a final message to indicate the loop was terminated
          final msgId = Uuid().v4();
          _messages.add(ChatMessage(
            messageId: msgId,
            content:
                "Conversation exceeded maximum iterations. Please provide a final answer or ask a followup question.",
            role: MessageRole.user,
            parentMessageId: _parentMessageId,
          ));
          _parentMessageId = msgId;

          break;
        }

        // 1. First, check if there's a tool call to process
        bool foundToolCall = await _checkNeedToolCall();

        // 2. If found a tool call, process it
        if (foundToolCall && _runFunctionEvent != null) {
          // Handle tool approval
          final event = _runFunctionEvent!;
          final approved = await _showFunctionApprovalDialog(event);

          if (approved) {
            setState(() {
              _isRunningFunction = true;
              _userApproved = false;
            });

            final toolName = event.name;
            await _sendToolCallAndProcessResponse(toolName, event.arguments);
            setState(() {
              _isRunningFunction = false;
            });
            _runFunctionEvent = null;

            // After processing a tool call, check if we need to wait for LLM response
            // or if we already have a final answer/followup question
            shouldContinue =
                !_isFinalAnswerReceived && _askFollowupQuestionEvent == null;
          } else {
            // User rejected the tool call
            setState(() {
              _userRejected = false;
              _runFunctionEvent = null;
            });
            final msgId = Uuid().v4();
            _messages.add(ChatMessage(
              messageId: msgId,
              content: 'User rejected the tool call.',
              role: MessageRole.user,
              parentMessageId: _parentMessageId,
            ));
            _parentMessageId = msgId;

            // Continue the conversation after rejection with a reminder
            shouldContinue = true;
          }
        }

        // 3. Check if the last message is from the assistant without a proper function call
        if (_messages.isNotEmpty &&
            _messages.last.role == MessageRole.assistant) {
          final lastContent = _messages.last.content ?? '';

          // If the last message is an assistant message without proper function use
          if (!_isFunctionCallMessage(lastContent) &&
              !_isFollowupQuestionMessage(lastContent) &&
              !_isFinalAnswerMessage(lastContent) &&
              !_isFinalAnswerReceived) {
            // Check if content has substantial text and count improper responses
            final contentLength = lastContent.trim().length;
            final hasSubstantialContent = contentLength > 100;
            final consecutiveImproperResponses =
                _countConsecutiveImproperResponses();

            // Only add reminder if content is short or this is at least the second improper response
            if (!hasSubstantialContent || consecutiveImproperResponses > 1) {
              Logger.root.info(
                  'Last message is an assistant message without proper function use');

              // Add reminder for the LLM to use functions properly
              final msgId = Uuid().v4();
              _messages.add(ChatMessage(
                messageId: msgId,
                content: toolNotProvided,
                role: MessageRole.user,
                parentMessageId: _parentMessageId,
              ));
              _parentMessageId = msgId;
            }
          }
        }

        // 4. Process LLM response if we should continue and haven't received a final answer
        if (shouldContinue && !_isFinalAnswerReceived) {
          await _processLLMResponse();

          // After LLM response, check if the response contains a valid function call, final answer, or followup question
          if (_messages.isNotEmpty &&
              _messages.last.role == MessageRole.assistant) {
            final content = _messages.last.content ?? '';

            if (_isFunctionCallMessage(content) ||
                _isFollowupQuestionMessage(content) ||
                _isFinalAnswerMessage(content)) {
              Logger.root.info(
                  'Response contains valid function call, final answer, or followup question');
              shouldContinue = true;
            } else {
              Logger.root.info(
                  'Response does not contain valid function call, final answer, or followup question');

              // Check if the content has substantial text and this isn't just a short response
              final contentLength = content.trim().length;
              final hasSubstantialContent = contentLength > 100;
              final consecutiveImproperResponses =
                  _countConsecutiveImproperResponses();

              // Only add reminder if content is short or this is at least the second improper response
              if (!hasSubstantialContent || consecutiveImproperResponses > 1) {
                // Add reminder for the LLM
                final msgId = Uuid().v4();
                _messages.add(ChatMessage(
                  messageId: msgId,
                  content: toolNotProvided,
                  role: MessageRole.user,
                  parentMessageId: _parentMessageId,
                ));
                _parentMessageId = msgId;
              }
              shouldContinue = true;
            }
          }
        }

        // 5. If we got a final answer or followup question in this iteration, stop the cycle
        if (_isFinalAnswerReceived || _askFollowupQuestionEvent != null) {
          Logger.root.info(
              'Final answer or followup question received, ending tool call cycle');
          shouldContinue = false;
        }

        // Log current state for debugging
        Logger.root.info(
            'End of iteration $iterationCount: shouldContinue=$shouldContinue, isFinalAnswerReceived=$_isFinalAnswerReceived');
      } while (shouldContinue &&
          !_isFinalAnswerReceived &&
          _askFollowupQuestionEvent == null &&
          iterationCount < maxIterations);

      await _updateChat();
    } catch (e, stackTrace) {
      _handleError(e, stackTrace);
      await _updateChat();
    }

    setState(() {
      _isLoading = false;
    });
  }

  Future<String> _getSystemPrompt() async {
    return ProviderManager.settingsProvider.generalSetting.systemPrompt;
    // final promptGenerator = SystemPromptGenerator();

    // var tools = <Map<String, dynamic>>[];
    // for (var entry in ProviderManager.mcpServerProvider.tools.entries) {
    //   if (ProviderManager.serverStateProvider.isEnabled(entry.key)) {
    //     tools.addAll(entry.value);
    //   }
    // }

    // if (tools.isEmpty) {
    //   return ProviderManager.settingsProvider.generalSetting.systemPrompt;
    // }

    // final systemPrompt = promptGenerator.generateSystemPrompt(tools);

    // Logger.root.info('systemPrompt: $systemPrompt');

    // return systemPrompt;
  }

  Future<String> _injectSystemPrompt(String userMessage) async {
    final promptGenerator = SystemPromptGenerator();

    var tools = <Map<String, dynamic>>[];
    for (var entry in ProviderManager.mcpServerProvider.tools.entries) {
      if (ProviderManager.serverStateProvider.isEnabled(entry.key)) {
        tools.addAll(entry.value);
      }
    }

    final toolPrompt = promptGenerator.generateToolPrompt(tools);

    return "<system_prompt>\n$toolPrompt</system_prompt>\n\n<user_message>\n$userMessage\n</user_message>\n>";
  }

  Future<void> _processLLMResponse() async {
    setState(() {
      _isWating = true;
    });

    // Prepare the message list without automatically adding reminder messages
    final List<ChatMessage> messageList = _prepareMessageList();
    final lastMessageIndex = messageList.length - 1;

    // We'll only add a reminder if this is at least the second time we're seeing
    // an improper assistant response in a row
    bool shouldAddReminder = false;

    // Check if there are at least 2 consecutive assistant messages without proper function calls
    if (messageList.isNotEmpty &&
        lastMessageIndex >= 1 &&
        messageList[lastMessageIndex].role == MessageRole.assistant &&
        messageList[lastMessageIndex - 1].role == MessageRole.assistant) {
      final lastContent = messageList[lastMessageIndex].content ?? '';
      final prevContent = messageList[lastMessageIndex - 1].content ?? '';

      // Only add a reminder if both messages lack proper function calls
      if ((!_isFunctionCallMessage(lastContent) &&
              !_isFollowupQuestionMessage(lastContent) &&
              !_isFinalAnswerMessage(lastContent)) &&
          (!_isFunctionCallMessage(prevContent) &&
              !_isFollowupQuestionMessage(prevContent) &&
              !_isFinalAnswerMessage(prevContent))) {
        shouldAddReminder = true;
      }
    }

    // Add a reminder only when necessary
    if (shouldAddReminder) {
      final msgId = Uuid().v4();
      final reminderMsg = ChatMessage(
        messageId: msgId,
        content:
            "Please use a function call, provide a final_answer, or ask a followup_question. The LLM should always use these mechanisms for responses.",
        role: MessageRole.user,
        parentMessageId: _parentMessageId,
      );

      messageList.add(reminderMsg);
      // Update the parent message ID
      _parentMessageId = msgId;
    }

    Logger.root.info('start process llm response: $messageList');

    final modelSetting = ProviderManager.settingsProvider.modelSetting;

    final firstUserMessageIndex = messageList.indexWhere(
      (m) => m.role == MessageRole.user,
    );

    final systemPrompt = await _getSystemPrompt();

    messageList[firstUserMessageIndex] =
        messageList[firstUserMessageIndex].copyWith(
      content: await _injectSystemPrompt(
          messageList[firstUserMessageIndex].content ?? ''),
    );

    final stream = _llmClient!.chatStreamCompletion(CompletionRequest(
      model: ProviderManager.chatModelProvider.currentModel.name,
      messages: [
        ChatMessage(
          content: systemPrompt,
          role: MessageRole.system,
        ),
        ...messageList,
      ],
      modelSetting: modelSetting,
    ));

    _initializeAssistantResponse();
    await _processResponseStream(stream);
    Logger.root.info('end process llm response');
  }

  // Helper methods to identify different types of function-related messages
  bool _isFunctionCallMessage(String content) {
    // Check for any function tag with more flexible pattern matching
    return RegExp('<function\\s+name=', caseSensitive: false).hasMatch(content);
  }

  bool _isFollowupQuestionMessage(String content) {
    // More flexible matching for followup question
    return RegExp('<function\\s+name=["\']followup_question["\']',
            caseSensitive: false)
        .hasMatch(content);
  }

  bool _isFinalAnswerMessage(String content) {
    Logger.root.info('isFinalAnswerMessage: $content');
    // More flexible matching for final answer
    return RegExp('<function\\s+name=["\']final_answer["\']',
            caseSensitive: false)
        .hasMatch(content);
  }

  List<ChatMessage> _prepareMessageList() {
    final List<ChatMessage> messageList = _messages
        .map((m) => ChatMessage(
              role: m.role,
              content: m.content,
              toolCallId: m.toolCallId,
              name: m.name,
              toolCalls: m.toolCalls,
              files: m.files,
            ))
        .toList();

    return messageList;
  }

  // Helper method to count consecutive improper LLM responses
  int _countConsecutiveImproperResponses() {
    int count = 0;
    // Start from the end of the messages and go backwards
    for (int i = _messages.length - 1; i >= 0; i--) {
      final message = _messages[i];

      // Only count assistant messages
      if (message.role == MessageRole.assistant) {
        final content = message.content ?? '';

        // If this message lacks proper function tags, increment the count
        if (!_isFunctionCallMessage(content) &&
            !_isFollowupQuestionMessage(content) &&
            !_isFinalAnswerMessage(content)) {
          count++;
        } else {
          // We found a proper response, so break the chain
          break;
        }
      } else {
        // If we hit a user message, break the chain
        break;
      }
    }
    return count;
  }

  void _initializeAssistantResponse() {
    setState(() {
      _currentResponse = '';
      _messages.add(
        ChatMessage(
          content: _currentResponse,
          role: MessageRole.assistant,
          parentMessageId: _parentMessageId,
        ),
      );
    });
  }

  Future<void> _processResponseStream(Stream<LLMResponse> stream) async {
    bool isFirstChunk = true;
    bool hasToolCall = false;
    bool hasFollowupQuestion = false;
    bool hasFinalAnswer = false;

    setState(() {
      _askFollowupQuestionEvent =
          null; // Reset any previous followup question event
    });

    await for (final chunk in stream) {
      if (isFirstChunk) {
        setState(() {
          _isWating = false;
        });
        isFirstChunk = false;
      }

      if (_isCancelled) break;

      // Append the new content to our cumulative response
      final newContent = chunk.content ?? '';
      _currentResponse += newContent;

      // Check if this chunk contains any function call tags
      if (newContent.contains('<function name=')) {
        if (!hasToolCall) {
          Logger.root.info('Found tool call in stream chunk');
          hasToolCall = true;
        }

        // Check for specific types of function calls
        if (newContent.contains('<function name="followup_question">')) {
          hasFollowupQuestion = true;
        } else if (newContent.contains('<function name="final_answer">')) {
          hasFinalAnswer = true;
        }
      }

      // Update the message in the UI
      setState(() {
        final msgId = Uuid().v4();
        _messages.last = ChatMessage(
            content: _currentResponse,
            role: MessageRole.assistant,
            parentMessageId: _parentMessageId,
            messageId: msgId);
        //set the
        _parentMessageId = msgId;
      });
    }

    Logger.root.info(
        'Response stream completed, hasToolCall=$hasToolCall, hasFinalAnswer=$hasFinalAnswer, hasFollowupQuestion=$hasFollowupQuestion');
    _isCancelled = false;

    // After receiving the complete response, check if the response is valid
    if (hasToolCall) {
      Logger.root.info('Processing tool call after stream completion');
      // The next iteration of the main loop will handle this tool call
    } else if (!hasFinalAnswer && !hasFollowupQuestion) {
      // The LLM didn't use any of the expected mechanisms
      Logger.root.info(
          'LLM did not provide a valid response (no function call, final answer, or followup question)');

      // Check if the content contains substantial text (more than just a brief response)
      final contentLength = _currentResponse.trim().length;
      final hasSubstantialContent = contentLength > 100;

      // Only add a reminder if the response is very short (likely incomplete)
      // or if this is at least the second time we're seeing an improper response
      final consecutiveImproperResponses = _countConsecutiveImproperResponses();

      if (!hasSubstantialContent || consecutiveImproperResponses > 1) {
        // Add a message to remind the LLM to use functions
        final msgId = Uuid().v4();
        _messages.add(ChatMessage(
          messageId: msgId,
          content: toolNotProvided,
          role: MessageRole.user,
          parentMessageId: _parentMessageId,
        ));

        // Update the parent message ID for the next message
        _parentMessageId = msgId;

        // We need to process the response again to get a valid response
        await _processLLMResponse();
      }
    }
  }

  Future<void> _updateChat() async {
    if (ProviderManager.chatProvider.activeChat == null) {
      await _createNewChat();
    } else {
      await _updateExistingChat();
    }
  }

  Future<void> _createNewChat() async {
    String title =
        await _llmClient!.genTitle([_messages.first, _messages.last]);
    await ProviderManager.chatProvider
        .createChat(Chat(title: title), _handleParentMessageId(_messages));
    Logger.root.info('create new chat: $title');
  }

  // Handles parentMessageId relationships for all messages in the chat
  List<ChatMessage> _handleParentMessageId(List<ChatMessage> messages) {
    if (messages.isEmpty) return [];

    // Create a copy to avoid modifying the original list
    List<ChatMessage> processedMessages = List.from(messages);

    // Create a message ID map to quickly find message positions
    Map<String, int> messageIdToIndex = {};
    for (int i = 0; i < processedMessages.length; i++) {
      messageIdToIndex[processedMessages[i].messageId] = i;
    }

    // First pass: ensure all messages have valid parentMessageId
    for (int i = 1; i < processedMessages.length; i++) {
      ChatMessage currentMsg = processedMessages[i];

      // If parentMessageId is empty or points to a non-existent message
      if (currentMsg.parentMessageId.isEmpty ||
          !messageIdToIndex.containsKey(currentMsg.parentMessageId)) {
        // Set parent to the previous message
        processedMessages[i] = currentMsg.copyWith(
          parentMessageId: processedMessages[i - 1].messageId,
        );
      }
    }

    // Second pass: handle function calls, tools and their results properly
    for (int i = 0; i < processedMessages.length; i++) {
      final msg = processedMessages[i];

      // Check if this is a function call message
      bool isFunctionCall = msg.role == MessageRole.assistant &&
          (msg.content?.contains('<function') ?? false);

      // Check if this is a function result message
      bool isFunctionResult = msg.role == MessageRole.user &&
          (msg.toolCallId != null ||
              (msg.content?.contains('<call_function_result') ?? false));

      // Make sure function results have the function call as parent
      if (isFunctionResult && i > 0) {
        // Look backward to find the most recent function call
        int functionCallIndex = -1;
        for (int j = i - 1; j >= 0; j--) {
          if (processedMessages[j].role == MessageRole.assistant &&
              (processedMessages[j].content?.contains('<function') ?? false)) {
            functionCallIndex = j;
            break;
          }
        }

        if (functionCallIndex != -1) {
          // Update the function result to have the function call as parent
          processedMessages[i] = processedMessages[i].copyWith(
            parentMessageId: processedMessages[functionCallIndex].messageId,
          );
        }
      }

      // Look ahead to find responses to this message and update their parentMessageId if needed
      if (i < processedMessages.length - 1) {
        for (int j = i + 1; j < processedMessages.length; j++) {
          // For assistant messages following a user message
          if (msg.role == MessageRole.user &&
              processedMessages[j].role == MessageRole.assistant &&
              j == i + 1) {
            processedMessages[j] = processedMessages[j].copyWith(
              parentMessageId: msg.messageId,
            );
            break; // Only update the immediate next assistant message
          }
        }
      }
    }

    // Logger.root.info('Processed message chain: ${processedMessages.map((m) => "${m.role} - ${m.messageId} - parent: ${m.parentMessageId}").join('\n')}');

    return processedMessages;
  }

  Future<void> _updateExistingChat() async {
    final activeChat = ProviderManager.chatProvider.activeChat!;
    await ProviderManager.chatProvider.updateChat(Chat(
      id: activeChat.id!,
      title: activeChat.title,
      createdAt: activeChat.createdAt,
      updatedAt: DateTime.now(),
    ));

    await ProviderManager.chatProvider
        .addChatMessage(activeChat.id!, _handleParentMessageId(_messages));
  }

  void _handleError(dynamic error, StackTrace stackTrace) {
    Logger.root.severe(error, stackTrace);

    // 重置所有相关状态
    setState(() {
      _isRunningFunction = false;
      _runFunctionEvent = null;
      _userApproved = false;
      _userRejected = false;
      _isLoading = false;
      _isCancelled = false;
      _isWating = false;
      _isFinalAnswerReceived =
          false; // Also reset the final answer flag on error
    });

    if (mounted) {
      showDialog(
        context: context,
        builder: (BuildContext context) {
          return AlertDialog(
            title: Row(
              children: [
                Icon(Icons.error_outline, color: AppColors.getErrorIconColor()),
                const SizedBox(width: 8),
                Text(AppLocalizations.of(context)!.error),
              ],
            ),
            content: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    AppLocalizations.of(context)!.userCancelledToolCall,
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: AppColors.getErrorTextColor(),
                    ),
                  ),
                  const SizedBox(height: 8),
                  SelectableText(
                    error.toString(),
                    style: TextStyle(color: AppColors.getErrorTextColor()),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: Text(AppLocalizations.of(context)!.close),
              ),
            ],
          );
        },
      );
    }
  }

  // 处理分享事件
  Future<void> _handleShare(ShareEvent event) async {
    if (_messages.isEmpty) return;
    await Future.delayed(const Duration(milliseconds: 100));
    if (mounted) {
      if (kIsMobile) {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => ListViewToImageScreen(messages: _messages),
          ),
        );
      } else {
        showDialog(
          context: context,
          builder: (context) => ListViewToImageScreen(messages: _messages),
        );
      }
    }
  }

  bool _isMobile() {
    final height = MediaQuery.of(context).size.height;
    final width = MediaQuery.of(context).size.width;
    return height > width;
  }

  void _handleCancel() {
    setState(() {
      _isComposing = false;
      _isLoading = false;
      _isCancelled = true;
    });
  }

  CodePreviewEvent? _codePreviewEvent;

  void _onArtifactEvent(CodePreviewEvent event) {
    _toggleCodePreview();
    setState(() {
      _codePreviewEvent = event;
    });
  }

  bool showModalCodePreview = false;
  void _showMobileCodePreview() {
    setState(() {
      showModalCodePreview = true;
    });
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (BuildContext context) {
        return SafeArea(
          child: Container(
            decoration: BoxDecoration(
              color: Theme.of(context).scaffoldBackgroundColor,
              borderRadius:
                  const BorderRadius.vertical(top: Radius.circular(20)),
            ),
            child: DraggableScrollableSheet(
              initialChildSize: 0.6,
              minChildSize: 0.3,
              maxChildSize: 0.9,
              expand: false,
              builder: (context, scrollController) {
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 40,
                      height: 4,
                      margin: const EdgeInsets.symmetric(vertical: 16),
                      decoration: BoxDecoration(
                        color: AppColors.getBottomSheetHandleColor(context),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                    Expanded(
                      child: _codePreviewEvent != null
                          ? ChatCodePreview(
                              codePreviewEvent: _codePreviewEvent!,
                            )
                          : const SizedBox.shrink(),
                    ),
                  ],
                );
              },
            ),
          ),
        );
      },
    );
  }

  void _toggleCodePreview() {
    if (_isMobile()) {
      _showMobileCodePreview();
      if (_showCodePreview) {
        setState(() {
          _showCodePreview = false;
        });
      }
    } else {
      setState(() {
        _showCodePreview = !_showCodePreview;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (mobile) {
      return Column(
        children: [
          _buildMessageList(),
          InputArea(
            disabled: _isLoading,
            isComposing: _isComposing,
            onTextChanged: _handleTextChanged,
            onSubmitted: _handleSubmitted,
            onCancel: _handleCancel,
          ),
        ],
      );
    }

    return Row(
      children: [
        Expanded(
          flex: 1,
          child: Column(
            children: [
              _buildMessageList(),
              // loading icon
              if (_isRunningFunction)
                Container(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          valueColor: AlwaysStoppedAnimation<Color>(
                            Theme.of(context).primaryColor,
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Text(
                        AppLocalizations.of(context)!.functionRunning,
                        style: TextStyle(
                          fontSize: 14,
                          color: Theme.of(context)
                              .textTheme
                              .bodyMedium
                              ?.color
                              ?.withOpacity(0.7),
                        ),
                      ),
                    ],
                  ),
                ),
              InputArea(
                disabled: _isLoading,
                isComposing: _isComposing,
                onTextChanged: _handleTextChanged,
                onSubmitted: _handleSubmitted,
                onCancel: _handleCancel,
              ),
            ],
          ),
        ),
        if (!mobile && _showCodePreview)
          Expanded(
            flex: 1,
            child: _codePreviewEvent != null
                ? ChatCodePreview(
                    codePreviewEvent: _codePreviewEvent!,
                  )
                : const SizedBox.shrink(),
          ),
      ],
    );
  }
}
