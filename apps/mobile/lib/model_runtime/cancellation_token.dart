import 'dart:async';

class CancellationToken {
  final Completer<void> _cancelled = Completer<void>();
  final Map<int, void Function()> _listeners = {};
  var _nextListenerId = 0;

  bool get isCancelled => _cancelled.isCompleted;

  Future<void> get whenCancelled => _cancelled.future;

  int get activeListenerCount => _listeners.length;

  CancellationSubscription addListener(void Function() listener) {
    if (isCancelled) {
      _notifySafely(listener);
      return CancellationSubscription._();
    }
    final id = _nextListenerId++;
    _listeners[id] = listener;
    return CancellationSubscription._(() => _listeners.remove(id));
  }

  void cancel() {
    if (!_cancelled.isCompleted) {
      _cancelled.complete();
      final listeners = _listeners.values.toList(growable: false);
      _listeners.clear();
      for (final listener in listeners) {
        _notifySafely(listener);
      }
    }
  }

  static void _notifySafely(void Function() listener) {
    try {
      listener();
    } on Object {
      // Cancellation is best-effort fan-out. One faulty observer must not
      // prevent other resources from being cancelled and drained.
    }
  }
}

class CancellationSubscription {
  CancellationSubscription._([this._onDispose]);

  void Function()? _onDispose;

  void dispose() {
    final onDispose = _onDispose;
    _onDispose = null;
    onDispose?.call();
  }
}

final class LinkedCancellationScope {
  LinkedCancellationScope(Iterable<CancellationToken> sources) {
    final unique = <CancellationToken>{...sources};
    for (final source in unique) {
      _subscriptions.add(source.addListener(token.cancel));
    }
  }

  final CancellationToken token = CancellationToken();
  final List<CancellationSubscription> _subscriptions = [];
  bool _disposed = false;

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    for (final subscription in _subscriptions) {
      subscription.dispose();
    }
    _subscriptions.clear();
  }
}
