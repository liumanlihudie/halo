import 'dart:async';

import 'package:halo_mobile/model_runtime/structured_sse_frame.dart';

class FakeStructuredSseTransport implements StructuredSseFrameTransport {
  FakeStructuredSseTransport.fromFrames(Iterable<StructuredSseFrame> frames)
    : _stream = Stream.fromIterable(frames);

  FakeStructuredSseTransport.controlled() {
    _controller = StreamController<StructuredSseFrame>(
      sync: true,
      onPause: () => pauseCount++,
      onResume: () => resumeCount++,
    );
    _stream = _controller!.stream;
  }

  late final Stream<StructuredSseFrame> _stream;
  StreamController<StructuredSseFrame>? _controller;
  int pauseCount = 0;
  int resumeCount = 0;

  void add(StructuredSseFrame frame) {
    final controller = _controller;
    if (controller == null) {
      throw StateError('Only a controlled fake accepts frames');
    }
    controller.add(frame);
  }

  void addError(Object error) {
    final controller = _controller;
    if (controller == null) {
      throw StateError('Only a controlled fake accepts errors');
    }
    controller.addError(error);
  }

  Future<void> close() async {
    await _controller?.close();
  }

  @override
  Stream<StructuredSseFrame> openFrameStream() => _stream;
}
