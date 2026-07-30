import 'package:flutter_test/flutter_test.dart';
import 'package:halo_mobile/orchestration/graph_spec/condition_expression.dart';
import 'package:halo_mobile/orchestration/graph_spec/graph_spec.dart';

void main() {
  const schema = StateSchemaRef(schemaId: 'test.state', version: 1);
  final resolver = MapStateSchemaResolver({
    r'$.mode': const StateFieldSchema(ConditionValueType.string),
    r'$.round': const StateFieldSchema(ConditionValueType.int64),
    r'$.ready': const StateFieldSchema(ConditionValueType.boolean),
    r'$.note': const StateFieldSchema(
      ConditionValueType.string,
      nullable: true,
    ),
    r'$.tags': const StateFieldSchema(ConditionValueType.stringArray),
  });

  test('decodes the documented boolean expression grammar into an AST', () {
    final expression = ConditionExpressionDecoder(schemaResolver: resolver)
        .decode(
          r'$.mode == "all" && ($.round < 2 || !exists($.note))',
          schemaRef: schema,
        );

    expect(expression, isA<ConditionAnd>());
  });

  test('rejects script syntax and unknown state paths', () {
    final decoder = ConditionExpressionDecoder(schemaResolver: resolver);

    expect(
      () => decoder.decode('process.exit(1)', schemaRef: schema),
      throwsA(
        isA<ConditionDecodeException>().having(
          (error) => error.code,
          'code',
          'condition_syntax_error',
        ),
      ),
    );
    expect(
      () => decoder.decode(r'$.missing == true', schemaRef: schema),
      throwsA(
        isA<ConditionDecodeException>().having(
          (error) => error.code,
          'code',
          'condition_unknown_path',
        ),
      ),
    );
  });

  test('rejects type mismatches and Gateway-unsafe integers', () {
    final decoder = ConditionExpressionDecoder(schemaResolver: resolver);

    expect(
      () => decoder.decode(r'$.round == "2"', schemaRef: schema),
      throwsA(
        isA<ConditionDecodeException>().having(
          (error) => error.code,
          'code',
          'condition_type_error',
        ),
      ),
    );
    expect(
      () =>
          decoder.decode(r'$.round == 9223372036854775808', schemaRef: schema),
      throwsA(
        isA<ConditionDecodeException>().having(
          (error) => error.code,
          'code',
          'condition_number_out_of_range',
        ),
      ),
    );
    expect(
      () => decoder.decode(r'$.round == 9007199254740992', schemaRef: schema),
      throwsA(
        isA<ConditionDecodeException>().having(
          (error) => error.code,
          'code',
          'condition_number_out_of_range',
        ),
      ),
    );
  });

  test('validates contains and nullable semantics from the state schema', () {
    final decoder = ConditionExpressionDecoder(schemaResolver: resolver);

    expect(
      decoder.decode(r'contains($.tags, "ios")', schemaRef: schema),
      isA<ConditionContains>(),
    );
    expect(
      decoder.decode(r'isNull($.note)', schemaRef: schema),
      isA<ConditionIsNull>(),
    );
    expect(
      () => decoder.decode(r'isNull($.mode)', schemaRef: schema),
      throwsA(
        isA<ConditionDecodeException>().having(
          (error) => error.code,
          'code',
          'condition_type_error',
        ),
      ),
    );
  });

  test('rejects excessive AST nodes and parenthesis depth', () {
    final decoder = ConditionExpressionDecoder(schemaResolver: resolver);
    final deep =
        '${List.filled(40, '(').join()}\$.ready == true'
        '${List.filled(40, ')').join()}';
    final bomb = List.filled(150, r'$.ready == true').join(' && ');

    for (final source in [deep, bomb]) {
      expect(
        () => decoder.decode(source, schemaRef: schema),
        throwsA(
          isA<ConditionDecodeException>().having(
            (error) => error.code,
            'code',
            'condition_complexity_exceeded',
          ),
        ),
      );
    }
  });

  test('rejects an unpaired surrogate decoded from a JSON string literal', () {
    final decoder = ConditionExpressionDecoder(schemaResolver: resolver);

    expect(
      () => decoder.decode(r'$.mode == "\ud800"', schemaRef: schema),
      throwsA(
        isA<ConditionDecodeException>().having(
          (error) => error.code,
          'code',
          'condition_invalid_unicode',
        ),
      ),
    );
  });
}
