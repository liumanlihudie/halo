import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:halo_mobile/features/single_chat/message_actions_service.dart';

void main() {
  late Directory directory;
  late File localFile;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('halo-msg-actions-');
    localFile = File('${directory.path}/photo.jpg')
      ..writeAsBytesSync([1, 2, 3]);
  });

  tearDown(() => directory.deleteSync(recursive: true));

  test('copy and share pass the exact text through', () async {
    final copied = <String>[];
    final shared = <String>[];
    final service = MessageActionsService(
      copyToClipboard: (text) async => copied.add(text),
      shareText: (text) async => shared.add(text),
    );

    await service.copyText('这是回答');
    await service.shareText('这是回答');

    expect(copied, ['这是回答']);
    expect(shared, ['这是回答']);
  });

  test('empty text is rejected before any system call', () async {
    var called = false;
    final service = MessageActionsService(
      copyToClipboard: (_) async => called = true,
      shareText: (_) async => called = true,
    );

    await expectLater(
      service.copyText('   '),
      throwsA(isA<MessageActionException>()),
    );
    await expectLater(
      service.shareText(''),
      throwsA(isA<MessageActionException>()),
    );
    expect(called, isFalse);
  });

  test('image save and file share require a real local file', () async {
    var called = false;
    final service = MessageActionsService(
      shareFile: (_) async => called = true,
      saveImageToGallery: (_) async => called = true,
    );

    // Remote fixture URLs and missing paths have nothing to hand over.
    for (final bad in ['https://example.com/a.jpg', '${directory.path}/x.j']) {
      await expectLater(
        service.saveImageToGallery(bad),
        throwsA(
          isA<MessageActionException>().having(
            (error) => error.safeMessage,
            'safeMessage',
            '文件不在本机，无法操作',
          ),
        ),
      );
      await expectLater(
        service.shareFile(bad),
        throwsA(isA<MessageActionException>()),
      );
    }
    expect(called, isFalse);

    await service.saveImageToGallery(localFile.path);
    await service.shareFile(localFile.path);
    expect(called, isTrue);
  });

  test('platform failures surface as fixed safe messages', () async {
    final service = MessageActionsService(
      copyToClipboard: (_) async => throw StateError('raw platform detail'),
      saveImageToGallery: (_) async => throw StateError('permission blob'),
    );

    await expectLater(
      service.copyText('文字'),
      throwsA(
        isA<MessageActionException>().having(
          (error) => error.safeMessage,
          'safeMessage',
          '复制失败，请重试',
        ),
      ),
    );
    await expectLater(
      service.saveImageToGallery(localFile.path),
      throwsA(
        isA<MessageActionException>().having(
          (error) => error.safeMessage,
          'safeMessage',
          '保存到相册失败，请检查相册权限',
        ),
      ),
    );
  });
}
