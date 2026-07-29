import 'dart:collection';

import 'package:halo_mobile/model_runtime/gemini_transport.dart';
import 'package:halo_mobile/model_runtime/testing/safe_native_transport_record.dart';

class FakeGeminiTransport implements GeminiHttpTransport {
  final Queue<Object> _outcomes = Queue();
  final List<SafeNativeTransportRecord> records = [];

  void enqueue(GeminiTransportResponse response) => _outcomes.add(response);

  void enqueueError(Object error) => _outcomes.add(error);

  @override
  Future<GeminiTransportResponse> generateContent(
    GeminiTransportRequest request,
  ) async {
    records.add(
      SafeNativeTransportRecord(
        endpoint: request.endpoint,
        body: request.body,
        hadCredential: true,
      ),
    );
    if (_outcomes.isEmpty) {
      throw StateError('No fake Gemini response enqueued');
    }
    final outcome = _outcomes.removeFirst();
    if (outcome is GeminiTransportResponse) return outcome;
    throw outcome;
  }
}
