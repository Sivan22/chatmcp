import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';

/// Generates a standardized timeout message for tool calls
String generateToolCallTimeoutMessage(String toolName) {
  return "Tool call request for '$toolName' timed out. The operation couldn't be completed within the expected time. Please try again or consider using an alternative approach.";
}

/// Handle MCP tool call timeout exceptions
/// Returns a user-friendly message to notify the LLM about the timeout
String handleMcpToolCallTimeout(String toolName, Object error) {
  debugPrint('MCP tool call timeout for $toolName: $error');
  return generateToolCallTimeoutMessage(toolName);
}

/// Event triggered when a function needs to be executed
class RunFunctionEvent {
  /// The name of the function to run
  final String name;

  /// The arguments to pass to the function
  final Map<String, dynamic> arguments;

  /// Constructor
  RunFunctionEvent(this.name, this.arguments);

  @override
  String toString() {
    return 'RunFunctionEvent{name: $name, arguments: $arguments}';
  }
}

/// Event triggered when the LLM asks a followup question to the user
class AskFollowupQuestionEvent {
  /// The question being asked
  final String question;

  /// Optional list of options for the user to choose from
  final List<String>? options;

  /// Constructor
  AskFollowupQuestionEvent(this.question, this.options);

  @override
  String toString() {
    return 'AskFollowupQuestionEvent{question: $question, options: $options}';
  }
}

/// Event triggered when the LLM provides a final answer
class FinalAnswerEvent {
  /// The final answer content
  final String answer;

  /// Optional command to execute to demonstrate the result
  final String? command;

  /// Constructor
  FinalAnswerEvent(this.answer, this.command);

  @override
  String toString() {
    return 'FinalAnswerEvent{answer: $answer, command: $command}';
  }
}

/// Base class for function calling tools
abstract class BaseFunctionTool {
  /// The name of the tool
  String get name;

  /// Description of what the tool does
  String get description;

  /// Schema for the tool parameters
  Map<String, dynamic> get parameters;

  /// Execute the tool with the given arguments
  Future<dynamic> execute(Map<String, dynamic> arguments);

  /// Convert the tool to a JSON schema representation
  Map<String, dynamic> toJsonSchema() {
    return {
      "name": name,
      "description": description,
      "parameters": parameters,
    };
  }
}

/// Tool for asking followup questions to the user
class AskFollowupQuestionTool extends BaseFunctionTool {
  @override
  String get name => "followup_question";

  @override
  String get description =>
      "Ask the user a question to gather additional information needed to complete the task. "
      "This tool should be used when you encounter ambiguities, need clarification, or require more details to proceed effectively. "
      "It allows for interactive problem-solving by enabling direct communication with the user. "
      "Use this tool judiciously to maintain a balance between gathering necessary information and avoiding excessive back-and-forth.";

  @override
  Map<String, dynamic> get parameters => {
        "type": "object",
        "properties": {
          "question": {
            "type": "string",
            "description":
                "The question to ask the user. This should be a clear, specific question that addresses the information you need."
          },
          "options": {
            "type": "array",
            "items": {"type": "string"},
            "description":
                "Optional list of options for the user to choose from. If provided, the user will be able to select one of these options instead of typing a response."
          }
        },
        "required": ["question"]
      };

  @override
  Future<dynamic> execute(Map<String, dynamic> arguments) async {
    final question = arguments["question"] as String;

    List<String>? options;
    if (arguments.containsKey("options") && arguments["options"] != null) {
      final optionsList = arguments["options"] as List<dynamic>;
      options = optionsList.map((opt) => opt.toString()).toList();
    }

    return AskFollowupQuestionEvent(question, options);
  }
}

/// Tool for providing a final answer to the user
class FinalAnswerTool extends BaseFunctionTool {
  @override
  String get name => "final_answer";

  @override
  String get description =>
      "After each tool use, the user will respond with the result of that tool use, "
      "i.e. if it succeeded or failed, along with any reasons for failure. "
      "Once you've received the results of tool uses and can confirm that the task is complete, "
      "use this tool to present the result of your work to the user. "
      "Optionally you may provide a CLI command to showcase the result of your work. "
      "The user may respond with feedback if they are not satisfied with the result, "
      "which you can use to make improvements and try again.";

  @override
  Map<String, dynamic> get parameters => {
        "type": "object",
        "properties": {
          "answer": {
            "type": "string",
            "description": "Your final, complete answer to the user's question"
          },
          "command": {
            "type": "string",
            "description":
                "Optional CLI command to showcase the result of your work"
          }
        },
        "required": ["answer"]
      };

  @override
  Future<dynamic> execute(Map<String, dynamic> arguments) async {
    final answer = arguments["answer"] as String;
    final command = arguments["command"] as String?;

    return FinalAnswerEvent(answer, command);
  }
}

/// List of all built-in function tools
final List<BaseFunctionTool> builtInTools = [
  AskFollowupQuestionTool(),
  FinalAnswerTool(),
];

/// Parse a function call from XML format
Map<String, dynamic>? parseFunctionCall(String content) {
  // Basic implementation to extract function name and arguments
  RegExp regex =
      RegExp(r'<function\s+name="([^"]+)"[^>]*>(.*?)</function>', dotAll: true);
  Match? match = regex.firstMatch(content);

  if (match == null || match.groupCount < 2) {
    return null;
  }

  String name = match.group(1) ?? '';
  String args = match.group(2) ?? '';

  Map<String, dynamic> result = {
    'name': name,
    'arguments': {},
    'done': false,
  };

  try {
    // Try to parse the arguments as JSON
    Map<String, dynamic> jsonArgs = jsonDecode(args);
    result['arguments'] = jsonArgs;
  } catch (e) {
    // If JSON parsing fails, just use the raw text
    result['arguments'] = {'raw': args};
  }

  return result;
}

/// Format a function call into XML format
String formatFunctionCall(String name, Map<String, dynamic> arguments) {
  // Very simple implementation to avoid syntax errors
  String json = '{}';
  try {
    json = jsonEncode(arguments);
  } catch (e) {
    // Ignore JSON encoding errors and just use empty object
  }

  return '<function name="$name">\n$json\n</function>';
}
