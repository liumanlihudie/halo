import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:halo_mobile/orchestration/graph_spec/graph_spec.dart';

import 'graph_spec_test.dart';

void main() {
  test('decodeString is the strict external import entry point', () {
    final source = validGraphSpec();

    final restored = GraphSpec.decodeString(jsonEncode(source.toJson()));

    expect(restored.toJson(), source.toJson());
  });

  test(
    'external decoder rejects duplicate object keys before DTO decoding',
    () {
      final source = jsonEncode(validGraphSpec().toJson());
      final duplicateRoot = source.replaceFirst(
        '"schemaVersion":1',
        '"schemaVersion":1,"schemaVersion":1',
      );
      final duplicateNested = source.replaceFirst(
        '"maxAttempts":1',
        '"maxAttempts":1,"maxAttempts":1',
      );

      expect(
        () => GraphSpec.decodeString(duplicateRoot),
        throwsA(isA<GraphSpecFormatException>()),
      );
      expect(
        () => GraphSpec.decodeString(duplicateNested),
        throwsA(isA<GraphSpecFormatException>()),
      );
    },
  );

  test('external decoder applies byte limit before UTF-8 or JSON parsing', () {
    final oversizedMalformed = List<int>.filled(256 * 1024 + 1, 0xff);

    expect(
      () => GraphSpec.decodeUtf8(oversizedMalformed),
      throwsA(
        isA<GraphSpecFormatException>().having(
          (error) => error.message,
          'message',
          contains('256 KiB'),
        ),
      ),
    );
  });

  test('strict decoder rejects unknown fields at every DTO boundary', () {
    final json = validGraphSpec().toJson();
    json['surprise'] = true;

    expect(
      () => GraphSpec.fromJson(json),
      throwsA(isA<GraphSpecFormatException>()),
    );

    final nested = validGraphSpec().toJson();
    (nested['limits']! as Map<String, Object?>)['surprise'] = true;
    expect(
      () => GraphSpec.fromJson(nested),
      throwsA(isA<GraphSpecFormatException>()),
    );

    for (final path in ['stateSchemaRef', 'limits', 'integrity']) {
      final fixture = validGraphSpec().toJson();
      (fixture[path]! as Map<String, Object?>)['surprise'] = true;
      expect(
        () => GraphSpec.fromJson(fixture),
        throwsA(isA<GraphSpecFormatException>()),
        reason: path,
      );
    }

    final node = validGraphSpec().toJson();
    ((node['nodes']! as List).first as Map<String, Object?>)['surprise'] = true;
    expect(
      () => GraphSpec.fromJson(node),
      throwsA(isA<GraphSpecFormatException>()),
    );

    final retry = validGraphSpec().toJson();
    ((((retry['nodes']! as List).first as Map<String, Object?>)['retryPolicy']!)
            as Map<String, Object?>)['surprise'] =
        true;
    expect(
      () => GraphSpec.fromJson(retry),
      throwsA(isA<GraphSpecFormatException>()),
    );

    final edge = validGraphSpec().toJson();
    ((edge['edges']! as List).first as Map<String, Object?>)['surprise'] = true;
    expect(
      () => GraphSpec.fromJson(edge),
      throwsA(isA<GraphSpecFormatException>()),
    );
  });

  test('strict decoder rejects excessive depth, size and illegal numbers', () {
    final deep = validGraphSpec().toJson();
    Object? value = 'leaf';
    for (var index = 0; index < 40; index++) {
      value = <String, Object?>{'next': value};
    }
    ((deep['nodes']! as List).first as Map<String, Object?>)['config'] =
        <String, Object?>{'deep': value};
    expect(
      () => GraphSpec.fromJson(deep),
      throwsA(isA<GraphSpecFormatException>()),
    );

    final large = validGraphSpec().toJson();
    ((large['nodes']! as List).first as Map<String, Object?>)['config'] =
        <String, Object?>{'blob': List.filled(270000, 'x').join()};
    expect(
      () => GraphSpec.fromJson(large),
      throwsA(isA<GraphSpecFormatException>()),
    );

    final nonFinite = validGraphSpec().toJson();
    ((nonFinite['nodes']! as List).first as Map<String, Object?>)['config'] =
        <String, Object?>{'number': double.nan};
    expect(
      () => GraphSpec.fromJson(nonFinite),
      throwsA(isA<GraphSpecFormatException>()),
    );

    final oversizedInteger = validGraphSpec().toJson();
    ((oversizedInteger['nodes']! as List).first
        as Map<String, Object?>)['config'] = <String, Object?>{
      'number': pow(2, 63),
    };
    expect(
      () => GraphSpec.fromJson(oversizedInteger),
      throwsA(isA<GraphSpecFormatException>()),
    );

    final unsafeGatewayInteger = validGraphSpec().toJson();
    (unsafeGatewayInteger['limits']! as Map<String, Object?>)['maxWallTimeMs'] =
        9007199254740992;
    expect(
      () => GraphSpec.fromJson(unsafeGatewayInteger),
      throwsA(isA<GraphSpecFormatException>()),
    );
  });

  test('strict decoder enforces registered node config schemas', () {
    final json = validGraphSpec().toJson();
    ((json['nodes']! as List).last as Map<String, Object?>)['config'] = {
      'eventType': 42,
      'arbitraryScript': 'run()',
    };

    expect(
      () => GraphSpec.fromJson(json),
      throwsA(isA<GraphSpecFormatException>()),
    );
  });

  test('RetryPolicy snapshots the caller-owned retryable error list', () {
    final errors = <String>['timeout'];
    final policy = RetryPolicy(
      maxAttempts: 2,
      backoff: RetryBackoff.fixed,
      retryableErrors: errors,
    );

    errors.add('credential');

    expect(policy.retryableErrors, ['timeout']);
    expect(() => policy.retryableErrors.add('other'), throwsUnsupportedError);
  });
}
