import 'package:flutter/foundation.dart';

enum StructuredSseFrameKind { data, done, error }

@immutable
class StructuredSseFrame {
  const StructuredSseFrame._({
    required this.kind,
    this.data,
    this.statusCode,
    required this.hasUnsafeBody,
  });

  factory StructuredSseFrame.data(Map<String, Object?> data) =>
      StructuredSseFrame._(
        kind: StructuredSseFrameKind.data,
        data: Map.unmodifiable(data),
        hasUnsafeBody: false,
      );

  factory StructuredSseFrame.done() => StructuredSseFrame._(
    kind: StructuredSseFrameKind.done,
    hasUnsafeBody: false,
  );

  factory StructuredSseFrame.error({int? statusCode, Object? unsafeBody}) =>
      StructuredSseFrame._(
        kind: StructuredSseFrameKind.error,
        statusCode: statusCode,
        hasUnsafeBody: unsafeBody != null,
      );

  final StructuredSseFrameKind kind;
  final Map<String, Object?>? data;
  final int? statusCode;
  final bool hasUnsafeBody;

  @override
  String toString() =>
      'StructuredSseFrame(kind: ${kind.name}, statusCode: $statusCode, '
      'hasUnsafeBody: $hasUnsafeBody)';
}

abstract interface class StructuredSseFrameTransport {
  Stream<StructuredSseFrame> openFrameStream();
}
