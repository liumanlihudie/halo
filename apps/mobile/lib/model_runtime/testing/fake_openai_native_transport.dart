import 'dart:collection';

import 'package:halo_mobile/model_runtime/openai_native_transport.dart';
import 'package:halo_mobile/model_runtime/testing/safe_native_transport_record.dart';

class FakeOpenAINativeTransport implements OpenAINativeHttpTransport {
  final Queue<Object> _outcomes = Queue();
  final List<SafeNativeTransportRecord> records = [];

  void enqueue(OpenAINativeTransportResponse response) =>
      _outcomes.add(response);

  void enqueueError(Object error) => _outcomes.add(error);

  @override
  Future<OpenAINativeTransportResponse> sendChat(
    OpenAINativeTransportRequest request,
  ) async {
    records.add(
      SafeNativeTransportRecord(
        endpoint: request.endpoint,
        body: request.body,
        hadCredential: true,
      ),
    );
    if (_outcomes.isEmpty) {
      throw StateError('No fake OpenAI response enqueued');
    }
    final outcome = _outcomes.removeFirst();
    if (outcome is OpenAINativeTransportResponse) return outcome;
    throw outcome;
  }
}
