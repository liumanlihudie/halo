import 'dart:collection';

import 'package:halo_mobile/model_runtime/anthropic_transport.dart';
import 'package:halo_mobile/model_runtime/testing/safe_native_transport_record.dart';

class FakeAnthropicTransport implements AnthropicHttpTransport {
  final Queue<Object> _outcomes = Queue();
  final List<SafeNativeTransportRecord> records = [];

  void enqueue(AnthropicTransportResponse response) => _outcomes.add(response);

  void enqueueError(Object error) => _outcomes.add(error);

  @override
  Future<AnthropicTransportResponse> sendMessage(
    AnthropicTransportRequest request,
  ) async {
    records.add(
      SafeNativeTransportRecord(
        endpoint: request.endpoint,
        body: request.body,
        hadCredential: true,
        metadata: {'apiVersion': request.apiVersion},
      ),
    );
    if (_outcomes.isEmpty) {
      throw StateError('No fake Anthropic response enqueued');
    }
    final outcome = _outcomes.removeFirst();
    if (outcome is AnthropicTransportResponse) return outcome;
    throw outcome;
  }
}
