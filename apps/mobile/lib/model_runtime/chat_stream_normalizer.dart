import 'package:halo_mobile/model_runtime/cancellation_token.dart';
import 'package:halo_mobile/model_runtime/chat_stream_models.dart';
import 'package:halo_mobile/model_runtime/structured_sse_frame.dart';

abstract interface class ChatStreamNormalizer {
  Stream<ChatStreamEvent> normalize(
    Stream<StructuredSseFrame> frames, {
    required CancellationToken cancellationToken,
  });
}
