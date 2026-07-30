import 'dart:convert';

import 'package:halo_mobile/orchestration/orchestration_models.dart';

final class StartConversationCommandValidator {
  const StartConversationCommandValidator._();

  static void validate(StartConversationRunCommand command) {
    _validateText('Command input', command.input, 4096, 16384);
    final identifiers = <String, String>{
      'clientCommandId': command.clientCommandId,
      'conversationId': command.conversationId,
      'hostAgentId': command.hostAgentId,
      for (var i = 0; i < command.memberAgentIds.length; i++)
        'memberAgentIds[$i]': command.memberAgentIds[i],
      for (var i = 0; i < command.mentionedAgentIds.length; i++)
        'mentionedAgentIds[$i]': command.mentionedAgentIds[i],
    };
    for (final entry in identifiers.entries) {
      _validateText(entry.key, entry.value, 256, 256);
    }
    for (final entry in {
      'inputRef': command.inputRef,
      'contextRef': command.contextRef,
    }.entries) {
      if (entry.value != null) {
        _validateText(entry.key, entry.value!, 256, 256);
      }
    }
    if (command.memberAgentIds.isEmpty || command.memberAgentIds.length > 8) {
      throw ArgumentError('A run requires between 1 and 8 group members');
    }
    if (command.memberAgentIds.toSet().length !=
        command.memberAgentIds.length) {
      throw ArgumentError('Group member IDs must be unique');
    }
    if (!command.memberAgentIds.contains(command.hostAgentId)) {
      throw ArgumentError('Host Agent must be a current group member');
    }
    final mentioned = command.mentionedAgentIds.toSet();
    if (mentioned.length != command.mentionedAgentIds.length) {
      throw ArgumentError('Mentioned Agent IDs must be unique');
    }
    if (mentioned.length > 4) {
      throw ArgumentError('At most 4 agents may be mentioned');
    }
    if (!mentioned.every(command.memberAgentIds.contains)) {
      throw ArgumentError('Mentioned agents must be current group members');
    }
    if (command.replyMode == ConversationReplyMode.mentioned &&
        mentioned.isEmpty) {
      throw ArgumentError('Mentioned mode requires between 1 and 4 agents');
    }
  }

  static void _validateText(
    String field,
    String value,
    int maxScalars,
    int maxBytes,
  ) {
    _rejectUnpairedSurrogates(field, value);
    if (value.trim().isEmpty ||
        value.runes.length > maxScalars ||
        utf8.encode(value).length > maxBytes) {
      throw ArgumentError(
        '$field must be non-blank, at most $maxScalars Unicode scalars '
        'and at most $maxBytes UTF-8 bytes',
      );
    }
  }

  static void _rejectUnpairedSurrogates(String field, String value) {
    var index = 0;
    while (index < value.length) {
      final codeUnit = value.codeUnitAt(index);
      if (codeUnit >= 0xD800 && codeUnit <= 0xDBFF) {
        if (index + 1 >= value.length) {
          throw ArgumentError('$field contains an unpaired UTF-16 surrogate');
        }
        final next = value.codeUnitAt(index + 1);
        if (next < 0xDC00 || next > 0xDFFF) {
          throw ArgumentError('$field contains an unpaired UTF-16 surrogate');
        }
        index += 2;
        continue;
      }
      if (codeUnit >= 0xDC00 && codeUnit <= 0xDFFF) {
        throw ArgumentError('$field contains an unpaired UTF-16 surrogate');
      }
      index++;
    }
  }
}
