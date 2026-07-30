import 'package:halo_mobile/model_runtime/cancellation_token.dart';
import 'package:halo_mobile/model_runtime/chat_stream_models.dart';
import 'package:halo_mobile/model_runtime/model_runtime_models.dart';

abstract interface class StreamingChatModelRuntime {
  Stream<ChatStreamEvent> streamChat(
    ChatRequest request, {
    required CancellationToken cancellationToken,
  });
}
