import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:halo_mobile/app/streaming_answer_extractor.dart';

void main() {
  String feedAll(StreamingAnswerExtractor extractor, Iterable<String> chunks) {
    final suffixes = StringBuffer();
    for (final chunk in chunks) {
      suffixes.write(extractor.feed(chunk));
    }
    return suffixes.toString();
  }

  List<String> splitEvery(String text, int size) => [
    for (var i = 0; i < text.length; i += size)
      text.substring(i, i + size > text.length ? text.length : i + size),
  ];

  test('decodes a plain Answer value fed in small chunks', () {
    final extractor = StreamingAnswerExtractor();
    const payload = '{"Answer": "先把需求澄清清楚，再决定优先级。", "Problem": "需求尚未澄清"}';
    final suffixes = feedAll(extractor, splitEvery(payload, 3));

    expect(extractor.answerSoFar, '先把需求澄清清楚，再决定优先级。');
    expect(suffixes, '先把需求澄清清楚，再决定优先级。');
    expect(extractor.answerComplete, isTrue);
  });

  test('feed returns only the newly decoded suffix', () {
    final extractor = StreamingAnswerExtractor();
    expect(extractor.feed('{"Answer": "ab'), 'ab');
    expect(extractor.feed('cd'), 'cd');
    expect(extractor.answerSoFar, 'abcd');
    expect(extractor.answerComplete, isFalse);
    expect(extractor.feed('"'), '');
    expect(extractor.answerComplete, isTrue);
  });

  test('decodes every simple escape sequence', () {
    final extractor = StreamingAnswerExtractor();
    extractor.feed(r'{"Answer": "a\"b\\c\/d\be\ff\ng\rh\ti"}');

    expect(extractor.answerSoFar, 'a"b\\c/d\be\ff\ng\rh\ti');
    expect(extractor.answerComplete, isTrue);
  });

  test('decodes \\uXXXX escapes including chunk-split surrogate pairs', () {
    final extractor = StreamingAnswerExtractor();
    extractor.feed(r'{"Answer": "笑笑 \uD83D');
    // The held-back high surrogate must not leak a malformed half-character.
    expect(extractor.answerSoFar, '笑笑 ');
    final suffix = extractor.feed(r'\uDE00 end"}');

    expect(suffix, '😀 end');
    expect(extractor.answerSoFar, '笑笑 😀 end');
    expect(extractor.answerComplete, isTrue);
  });

  test('handles an escape split across chunk boundaries', () {
    final extractor = StreamingAnswerExtractor();
    extractor.feed('{"Answer": "line1');
    expect(extractor.feed('\\'), '');
    expect(extractor.feed('n'), '\n');
    // A \u escape split mid-hex is buffered until complete.
    extractor.feed('\\u7b');
    expect(extractor.answerSoFar, 'line1\n');
    extractor.feed('11"}');

    expect(extractor.answerSoFar, 'line1\n笑');
    expect(extractor.answerComplete, isTrue);
  });

  test('a literal surrogate pair split across chunks stays intact', () {
    const emoji = '😀';
    final extractor = StreamingAnswerExtractor();
    extractor.feed('{"Answer": "x${emoji[0]}');
    expect(extractor.answerSoFar, 'x');
    extractor.feed('${emoji[1]}y"}');

    expect(extractor.answerSoFar, 'x😀y');
    expect(extractor.answerComplete, isTrue);
  });

  test('tolerates a leading markdown fence line', () {
    final extractor = StreamingAnswerExtractor();
    final payload =
        '```json\n${jsonEncode({'Answer': '围栏内的回答', 'Problem': 'x'})}\n```';
    feedAll(extractor, splitEvery(payload, 5));

    expect(extractor.answerSoFar, '围栏内的回答');
    expect(extractor.answerComplete, isTrue);
  });

  test('emits nothing until the Answer key has arrived', () {
    final extractor = StreamingAnswerExtractor();
    expect(extractor.feed('{"Problem": "需求尚未澄清", '), '');
    expect(extractor.answerSoFar, isEmpty);
    expect(extractor.feed('"Ans'), '');
    expect(extractor.feed('wer" : "好'), '好');
    expect(extractor.answerSoFar, '好');
  });

  test('ignores all content after the closing quote', () {
    final extractor = StreamingAnswerExtractor();
    extractor.feed('{"Answer": "完整回答", "Recommendation": "别把这段算进来"}');
    expect(extractor.answerComplete, isTrue);
    expect(extractor.feed('{"Answer": "第二个对象"}'), '');

    expect(extractor.answerSoFar, '完整回答');
  });

  test('whitespace around the colon is accepted', () {
    final extractor = StreamingAnswerExtractor();
    extractor.feed('{ "Answer" \n\t : \n "空白容忍" }');

    expect(extractor.answerSoFar, '空白容忍');
    expect(extractor.answerComplete, isTrue);
  });

  test('a quoted "Answer" without a colon does not start the value', () {
    final extractor = StreamingAnswerExtractor();
    extractor.feed('{"Notes": "\\"Answer\\" is the key name", "Answer": "对"}');

    // First candidate is rejected at the non-colon character and scanning
    // resumes deterministically until the real key.
    expect(extractor.answerSoFar, '对');
    expect(extractor.answerComplete, isTrue);
  });
}
