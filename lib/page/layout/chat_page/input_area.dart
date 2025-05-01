import 'package:chatmcp/page/layout/widgets/mcp_tools.dart';
import 'package:chatmcp/provider/provider_manager.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:io' show Platform;
import 'package:chatmcp/utils/platform.dart';
import 'package:file_picker/file_picker.dart';
import 'package:chatmcp/widgets/upload_menu.dart';
import 'package:chatmcp/generated/app_localizations.dart';
import 'package:flutter/cupertino.dart';

class SubmitData {
  final String text;
  final List<PlatformFile> files;

  SubmitData(this.text, this.files);

  @override
  String toString() {
    return 'SubmitData(text: $text, files: $files)';
  }
}

class InputArea extends StatefulWidget {
  final bool isComposing;
  final bool disabled;
  final ValueChanged<String> onTextChanged;
  final ValueChanged<SubmitData> onSubmitted;
  final VoidCallback? onCancel;
  final ValueChanged<List<PlatformFile>>? onFilesSelected;

  const InputArea({
    super.key,
    required this.isComposing,
    required this.disabled,
    required this.onTextChanged,
    required this.onSubmitted,
    this.onFilesSelected,
    this.onCancel,
  });

  @override
  State<InputArea> createState() => _InputAreaState();
}

class _InputAreaState extends State<InputArea> {
  List<PlatformFile> _selectedFiles = [];
  final TextEditingController textController = TextEditingController();
  bool _isImeComposing = false;

  Future<void> _pickFiles() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        allowMultiple: true,
        type: FileType.any,
      );

      if (result != null && result.files.isNotEmpty) {
        setState(() {
          _selectedFiles = [..._selectedFiles, ...result.files];
        });
        widget.onFilesSelected?.call(_selectedFiles);
      }
    } catch (e) {
      debugPrint('Error picking files: $e');
    }
  }

  Future<void> _pickImages() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        allowMultiple: true,
        type: FileType.image,
      );

      if (result != null && result.files.isNotEmpty) {
        setState(() {
          _selectedFiles = [..._selectedFiles, ...result.files];
        });
        widget.onFilesSelected?.call(_selectedFiles);
      }
    } catch (e) {
      debugPrint('Error picking images: $e');
    }
  }

  void _removeFile(int index) {
    setState(() {
      _selectedFiles.removeAt(index);
    });
    widget.onFilesSelected?.call(_selectedFiles);
  }

  void _afterSubmitted() {
    textController.clear();
    _selectedFiles.clear();
  }

  String _truncateFileName(String fileName) {
    const int maxLength = 20;
    if (fileName.length <= maxLength) return fileName;

    final extension =
        fileName.contains('.') ? '.${fileName.split('.').last}' : '';
    final nameWithoutExt = fileName.contains('.')
        ? fileName.substring(0, fileName.lastIndexOf('.'))
        : fileName;

    if (nameWithoutExt.length <= maxLength - extension.length - 3) {
      return fileName;
    }

    final truncatedLength = (maxLength - extension.length - 3) ~/ 2;
    return '${nameWithoutExt.substring(0, truncatedLength)}'
        '...'
        '${nameWithoutExt.substring(nameWithoutExt.length - truncatedLength)}'
        '$extension';
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Container(
      decoration: BoxDecoration(
        color: Colors.transparent,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          FutureBuilder<int>(
            future: ProviderManager.mcpServerProvider.installedServersCount,
            builder: (context, snapshot) {
              if (snapshot.hasData && snapshot.data! > 0) {
                return const McpTools();
              }
              return const SizedBox.shrink();
            },
          ),
          if (_selectedFiles.isNotEmpty)
            Container(
              padding: const EdgeInsets.only(left: 8.0, top: 4.0, bottom: 4.0),
              constraints: const BoxConstraints(maxHeight: 60),
              width: double.infinity,
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.start,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: _selectedFiles.asMap().entries.map((entry) {
                    final index = entry.key;
                    final file = entry.value;
                    return Padding(
                      padding: const EdgeInsets.only(right: 8.0),
                      child: Chip(
                        label: Text(
                          _truncateFileName(file.name),
                          style: const TextStyle(fontSize: 12),
                          overflow: TextOverflow.ellipsis,
                        ),
                        deleteIcon:
                            const Icon(CupertinoIcons.clear_circled, size: 16),
                        onDeleted: () => _removeFile(index),
                      ),
                    );
                  }).toList(),
                ),
              ),
            ),
          Padding(
            padding: const EdgeInsets.all(8.0),
            child: Stack(
              children: [
                Focus(
                  onKeyEvent: (node, event) {
                    if (event is KeyDownEvent &&
                        event.logicalKey == LogicalKeyboardKey.enter) {
                      if (HardwareKeyboard.instance.isShiftPressed) {
                        return KeyEventResult.ignored;
                      }

                      if (_isImeComposing) {
                        return KeyEventResult.ignored;
                      }

                      if (widget.isComposing &&
                          textController.text.trim().isNotEmpty) {
                        widget.onSubmitted(
                            SubmitData(textController.text, _selectedFiles));
                        _afterSubmitted();
                      }
                      return KeyEventResult.handled;
                    }
                    return KeyEventResult.ignored;
                  },
                  child: TextField(
                    enabled: !widget.disabled,
                    controller: textController,
                    onChanged: widget.onTextChanged,
                    maxLines: 5,
                    minLines: 1,
                    onAppPrivateCommand: (value, map) {
                      debugPrint('onAppPrivateCommand: $value');
                    },
                    buildCounter: (context,
                        {required currentLength,
                        required isFocused,
                        maxLength}) {
                      return null;
                    },
                    textInputAction:
                        kIsWeb || Platform.isAndroid || Platform.isIOS
                            ? TextInputAction.send
                            : TextInputAction.newline,
                    onSubmitted: kIsWeb || Platform.isAndroid || Platform.isIOS
                        ? (text) {
                            if (widget.isComposing && text.trim().isNotEmpty) {
                              widget.onSubmitted(
                                  SubmitData(text, _selectedFiles));
                              _afterSubmitted();
                            }
                          }
                        : null,
                    inputFormatters: [
                      TextInputFormatter.withFunction((oldValue, newValue) {
                        _isImeComposing = newValue.composing != TextRange.empty;
                        return newValue;
                      }),
                    ],
                    keyboardType: TextInputType.multiline,
                    style: const TextStyle(fontSize: 14.0),
                    scrollPhysics: const BouncingScrollPhysics(),
                    decoration: InputDecoration(
                      hintText: l10n.askMeAnything,
                      hintStyle: const TextStyle(fontSize: 14.0),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(11),
                      ),
                      contentPadding:
                          EdgeInsets.symmetric(horizontal: 14, vertical: 18),
                      isDense: true,
                    ),
                  ),
                ),
                Positioned(
                  right: 8,
                  top: 0,
                  bottom: 0,
                  child: Center(
                    child: Row(
                      children: widget.disabled
                          ? [
                              IconButton(
                                  onPressed: widget.onCancel != null
                                      ? () {
                                          widget.onCancel!();
                                        }
                                      : null,
                                  icon: const Icon(CupertinoIcons.stop))
                            ]
                          : [
                              if (kIsMobile) ...[
                                UploadMenu(
                                  disabled: widget.disabled,
                                  onPickImages: _pickImages,
                                  onPickFiles: _pickFiles,
                                ),
                              ] else ...[
                                IconButton(
                                  icon: const Icon(CupertinoIcons.plus_app),
                                  onPressed:
                                      widget.disabled ? null : _pickFiles,
                                  tooltip: l10n.uploadFiles,
                                ),
                              ],
                            ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
