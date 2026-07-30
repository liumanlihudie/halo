import 'package:flutter_test/flutter_test.dart';
import 'package:halo_mobile/model_runtime/cancellation_token.dart';

void main() {
  test('cancel isolates a throwing caller listener and notifies the rest', () {
    final token = CancellationToken();
    var notified = 0;
    token.addListener(() => throw StateError('listener failed'));
    token.addListener(() => notified++);

    expect(token.cancel, returnsNormally);
    expect(notified, 1);
    expect(token.isCancelled, isTrue);
    expect(token.activeListenerCount, 0);
  });

  test('linked cancellation survives a throwing provider listener', () {
    final source = CancellationToken();
    final linked = LinkedCancellationScope([source]);
    var notified = 0;
    linked.token.addListener(() => throw StateError('provider failed'));
    linked.token.addListener(() => notified++);

    expect(source.cancel, returnsNormally);
    expect(linked.token.isCancelled, isTrue);
    expect(notified, 1);
    linked.dispose();
    expect(source.activeListenerCount, 0);
  });
}
