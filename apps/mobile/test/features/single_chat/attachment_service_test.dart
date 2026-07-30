import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart' show XFile;
import 'package:halo_mobile/features/single_chat/attachments/chat_attachment_service.dart';

void main() {
  late Directory tempRoot;
  late Directory supportDirectory;
  late Directory sourceDirectory;

  setUp(() async {
    tempRoot = await Directory.systemTemp.createTemp('attachment_service_test');
    supportDirectory = await Directory(
      '${tempRoot.path}/support',
    ).create(recursive: true);
    sourceDirectory = await Directory(
      '${tempRoot.path}/source',
    ).create(recursive: true);
  });

  tearDown(() async {
    await tempRoot.delete(recursive: true);
  });

  Future<File> writeSourceFile(String name, List<int> bytes) async {
    final file = File('${sourceDirectory.path}/$name');
    await file.writeAsBytes(bytes, flush: true);
    return file;
  }

  ChatAttachmentService serviceWith({
    Future<XFile?> Function()? gallery,
    Future<XFile?> Function()? camera,
    Future<XFile?> Function()? filePicker,
  }) {
    return ChatAttachmentService(
      galleryPicker: gallery ?? () async => null,
      cameraPicker: camera ?? () async => null,
      filePicker: filePicker ?? () async => null,
      supportDirectoryProvider: () async => supportDirectory,
    );
  }

  test('pickImage copies into attachments dir under a new name', () async {
    final bytes = List<int>.generate(1024, (index) => index % 256);
    final source = await writeSourceFile('holiday.jpg', bytes);
    final service = serviceWith(gallery: () async => XFile(source.path));

    final attachment = await service.pickImage();

    expect(attachment, isNotNull);
    expect(attachment!.kind, ChatAttachmentKind.image);
    expect(attachment.fileName, 'holiday.jpg');
    expect(attachment.byteSize, bytes.length);
    expect(
      attachment.storedPath,
      startsWith(
        '${supportDirectory.path}${Platform.pathSeparator}attachments',
      ),
    );
    expect(attachment.storedPath, isNot(source.path));
    expect(attachment.storedPath, endsWith('.jpg'));
    expect(attachment.storedPath, contains(attachment.id));
    expect(File(attachment.storedPath).existsSync(), isTrue);
  });

  test('stored file content equals source content', () async {
    final bytes = List<int>.generate(4096, (index) => (index * 7) % 256);
    final source = await writeSourceFile('report.pdf', bytes);
    final service = serviceWith(filePicker: () async => XFile(source.path));

    final attachment = await service.pickFile();

    expect(attachment, isNotNull);
    expect(await File(attachment!.storedPath).readAsBytes(), bytes);
  });

  test('pickFile returns kind file with metadata', () async {
    final source = await writeSourceFile('notes.txt', [1, 2, 3]);
    final service = serviceWith(filePicker: () async => XFile(source.path));

    final attachment = await service.pickFile();

    expect(attachment, isNotNull);
    expect(attachment!.kind, ChatAttachmentKind.file);
    expect(attachment.fileName, 'notes.txt');
    expect(attachment.byteSize, 3);
    expect(attachment.storedPath, endsWith('.txt'));
  });

  test('takePhoto copies camera capture', () async {
    final source = await writeSourceFile('capture.heic', [9, 8, 7, 6]);
    final service = serviceWith(camera: () async => XFile(source.path));

    final attachment = await service.takePhoto();

    expect(attachment, isNotNull);
    expect(attachment!.kind, ChatAttachmentKind.image);
    expect(File(attachment.storedPath).readAsBytesSync(), [9, 8, 7, 6]);
  });

  test('cancellation returns null for every operation', () async {
    final service = serviceWith();

    expect(await service.pickImage(), isNull);
    expect(await service.takePhoto(), isNull);
    expect(await service.pickFile(), isNull);
  });

  test('picker error maps to fixed safe message per operation', () async {
    final service = serviceWith(
      gallery: () async => throw StateError('raw platform detail'),
      camera: () async => throw StateError('raw platform detail'),
      filePicker: () async => throw StateError('raw platform detail'),
    );

    await expectLater(
      service.pickImage(),
      throwsA(
        isA<ChatAttachmentException>().having(
          (error) => error.safeMessage,
          'safeMessage',
          ChatAttachmentService.pickImageFailureMessage,
        ),
      ),
    );
    await expectLater(
      service.takePhoto(),
      throwsA(
        isA<ChatAttachmentException>().having(
          (error) => error.safeMessage,
          'safeMessage',
          ChatAttachmentService.takePhotoFailureMessage,
        ),
      ),
    );
    await expectLater(
      service.pickFile(),
      throwsA(
        isA<ChatAttachmentException>().having(
          (error) => error.safeMessage,
          'safeMessage',
          ChatAttachmentService.pickFileFailureMessage,
        ),
      ),
    );
  });

  test('safe message does not leak raw error text', () async {
    final service = serviceWith(
      gallery: () async => throw StateError('SECRET_INTERNAL_PATH'),
    );

    try {
      await service.pickImage();
      fail('expected ChatAttachmentException');
    } on ChatAttachmentException catch (error) {
      expect(error.safeMessage, isNot(contains('SECRET_INTERNAL_PATH')));
      expect(error.toString(), isNot(contains('SECRET_INTERNAL_PATH')));
    }
  });
}
