import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:halo_mobile/features/settings/local_data_maintenance.dart';

void main() {
  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync('halo-local-data');
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  Directory child(String name) =>
      Directory('${root.path}${Platform.pathSeparator}$name')
        ..createSync(recursive: true);

  ProductionLocalDataMaintenance build({
    _FakeHistory? history,
    Directory? storage,
    Directory? cache,
    Directory? exports,
  }) {
    final storageDirectory = storage ?? child('storage');
    final cacheDirectory = cache ?? child('cache');
    final exportDirectory = exports ?? child('exports');
    return ProductionLocalDataMaintenance(
      history: history ?? _FakeHistory(),
      storageDirectory: () async => storageDirectory,
      cacheDirectory: () async => cacheDirectory,
      exportDirectory: () async => exportDirectory,
      now: () => DateTime.utc(2026, 7, 30, 12, 30, 15),
    );
  }

  test('snapshot measures real bytes and real history counts', () async {
    final storage = child('storage');
    File('${storage.path}${Platform.pathSeparator}db.sqlite')
      ..createSync()
      ..writeAsBytesSync(List.filled(2048, 7));
    final cache = child('cache');
    File('${cache.path}${Platform.pathSeparator}thumb.bin')
      ..createSync()
      ..writeAsBytesSync(List.filled(512, 1));
    final maintenance = build(
      history: _FakeHistory(conversations: 9, messages: 137),
      storage: storage,
      cache: cache,
    );

    final snapshot = await maintenance.loadSnapshot();

    expect(snapshot.storageBytes, 2048);
    expect(snapshot.cacheBytes, 512);
    expect(snapshot.conversationCount, 9);
    expect(snapshot.messageCount, 137);
  });

  test('an unreadable count never blanks out the measurable bytes', () async {
    final storage = child('storage');
    File('${storage.path}${Platform.pathSeparator}db.sqlite')
      ..createSync()
      ..writeAsBytesSync(List.filled(64, 3));
    final maintenance = build(
      history: _FakeHistory(failCount: true),
      storage: storage,
    );

    final snapshot = await maintenance.loadSnapshot();

    expect(snapshot.storageBytes, 64);
    expect(snapshot.conversationCount, isNull);
    expect(snapshot.messageCount, isNull);
  });

  test('clearing the cache reports the bytes it actually freed', () async {
    final cache = child('cache');
    File('${cache.path}${Platform.pathSeparator}a.bin')
      ..createSync()
      ..writeAsBytesSync(List.filled(300, 1));
    Directory('${cache.path}${Platform.pathSeparator}nested')
      ..createSync()
      ..childFile('b.bin', 700);
    final maintenance = build(cache: cache);

    final freed = await maintenance.clearCache();

    expect(freed, 1000);
    expect(cache.listSync(), isEmpty);
    // The cache directory itself belongs to the OS and must survive.
    expect(cache.existsSync(), isTrue);
  });

  test('the export bundle carries history and never carries secrets', () async {
    final history = _FakeHistory(
      exported: [
        {
          'conversationId': 'conversation-product',
          'expertId': 'product-manager',
          'messages': [
            {
              'messageId': 'm1',
              'projection': {'text': '先把需求澄清清楚。'},
            },
          ],
        },
      ],
    );
    final maintenance = build(history: history);

    final bundle = await maintenance.exportBundle();
    final decoded =
        jsonDecode(await bundle.file.readAsString()) as Map<String, Object?>;

    expect(decoded['format'], 'halo.local-data-export');
    expect(decoded['formatVersion'], 1);
    expect(decoded['exportedAt'], '2026-07-30T12:30:15.000Z');
    expect((decoded['conversations']! as List).single, history.exported.single);
    expect(bundle.byteCount, bundle.file.lengthSync());
    // The carried payload is scanned wholesale rather than by known key: a
    // future field that smuggles a credential in must fail this test. The
    // envelope's own `excludes` disclosure is excluded from the scan because
    // it names these terms on purpose.
    final raw = jsonEncode(decoded['conversations']);
    for (final forbidden in const [
      'sk-',
      'Bearer',
      'authorization',
      'secretRef',
      'keychain',
      'apiKey',
    ]) {
      expect(
        raw.toLowerCase().contains(forbidden.toLowerCase()),
        isFalse,
        reason: 'export must not contain $forbidden',
      );
    }
  });

  test('erasing delegates to the history port and nothing else', () async {
    final history = _FakeHistory();
    final storage = child('storage');
    final marker = File('${storage.path}${Platform.pathSeparator}keys.plist')
      ..createSync()
      ..writeAsStringSync('unrelated');
    final maintenance = build(history: history, storage: storage);

    await maintenance.eraseLocalData();

    expect(history.eraseCount, 1);
    // Erase is scoped to chat history: unrelated on-disk state stays put.
    expect(marker.existsSync(), isTrue);
  });

  test('byte formatting matches what the settings rows render', () {
    expect(formatLocalDataBytes(0), '0 B');
    expect(formatLocalDataBytes(512), '512 B');
    expect(formatLocalDataBytes(1536), '1.5 KB');
    expect(formatLocalDataBytes(1572864), '1.5 MB');
    expect(formatLocalDataBytes(1024 * 1024 * 300), '300 MB');
  });
}

extension on Directory {
  void childFile(String name, int bytes) {
    File('$path${Platform.pathSeparator}$name')
      ..createSync(recursive: true)
      ..writeAsBytesSync(List.filled(bytes, 2));
  }
}

class _FakeHistory implements SingleChatHistoryMaintenance {
  _FakeHistory({
    this.conversations = 0,
    this.messages = 0,
    this.exported = const [],
    this.failCount = false,
  });

  final int conversations;
  final int messages;
  final List<Map<String, Object?>> exported;
  final bool failCount;
  int eraseCount = 0;

  @override
  Future<({int conversations, int messages})> countStoredHistory() async {
    if (failCount) throw StateError('unavailable');
    return (conversations: conversations, messages: messages);
  }

  @override
  Future<List<Map<String, Object?>>> exportStoredHistory() async => exported;

  @override
  Future<void> eraseStoredMessages() async => eraseCount += 1;
}
