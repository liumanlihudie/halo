import 'dart:io';
import 'dart:math';

import 'package:file_selector/file_selector.dart' as file_selector;
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';

/// The kind of local attachment the user picked.
enum ChatAttachmentKind { image, file }

/// A picked attachment that has been durably copied into app storage.
///
/// [storedPath] always points at a private copy under the application
/// support directory (`attachments/<uuid>.<ext>`), never at the picker's
/// temporary file.
class ChatAttachment {
  const ChatAttachment({
    required this.id,
    required this.kind,
    required this.fileName,
    required this.storedPath,
    required this.byteSize,
  });

  final String id;
  final ChatAttachmentKind kind;
  final String fileName;
  final String storedPath;
  final int byteSize;
}

/// Failure surfaced to the UI with a fixed, safe Chinese message.
///
/// Raw platform error text is intentionally never included.
class ChatAttachmentException implements Exception {
  const ChatAttachmentException(this.safeMessage);

  final String safeMessage;

  @override
  String toString() => 'ChatAttachmentException: $safeMessage';
}

/// Picks a source file, or returns null when the user cancels.
typedef AttachmentSourcePicker = Future<XFile?> Function();

/// Provides the directory that owns the durable `attachments/` folder.
typedef AttachmentDirectoryProvider = Future<Directory> Function();

/// Local attachment capture for the single-chat "+" sheet.
///
/// Picked files are copied into `<app support>/attachments/<uuid>.<ext>`
/// so they survive the picker's temp-file lifecycle. Attachments are not
/// yet sent to the model (text-only P0 runtime).
class ChatAttachmentService {
  ChatAttachmentService({
    AttachmentSourcePicker? galleryPicker,
    AttachmentSourcePicker? cameraPicker,
    AttachmentSourcePicker? filePicker,
    AttachmentDirectoryProvider? supportDirectoryProvider,
  }) : _galleryPicker = galleryPicker ?? _defaultGalleryPicker,
       _cameraPicker = cameraPicker ?? _defaultCameraPicker,
       _filePicker = filePicker ?? _defaultFilePicker,
       _supportDirectoryProvider =
           supportDirectoryProvider ?? getApplicationSupportDirectory;

  static const String pickImageFailureMessage = '选择图片失败，请重试';
  static const String takePhotoFailureMessage = '拍摄照片失败，请重试';
  static const String pickFileFailureMessage = '选择文件失败，请重试';

  final AttachmentSourcePicker _galleryPicker;
  final AttachmentSourcePicker _cameraPicker;
  final AttachmentSourcePicker _filePicker;
  final AttachmentDirectoryProvider _supportDirectoryProvider;

  static Future<XFile?> _defaultGalleryPicker() =>
      ImagePicker().pickImage(source: ImageSource.gallery);

  static Future<XFile?> _defaultCameraPicker() =>
      ImagePicker().pickImage(source: ImageSource.camera);

  static Future<XFile?> _defaultFilePicker() => file_selector.openFile();

  /// Picks an image from the photo library. Null when the user cancels.
  Future<ChatAttachment?> pickImage() => _pickAndStore(
    picker: _galleryPicker,
    kind: ChatAttachmentKind.image,
    failureMessage: pickImageFailureMessage,
  );

  /// Takes a photo with the camera. Null when the user cancels.
  Future<ChatAttachment?> takePhoto() => _pickAndStore(
    picker: _cameraPicker,
    kind: ChatAttachmentKind.image,
    failureMessage: takePhotoFailureMessage,
  );

  /// Picks an arbitrary file. Null when the user cancels.
  Future<ChatAttachment?> pickFile() => _pickAndStore(
    picker: _filePicker,
    kind: ChatAttachmentKind.file,
    failureMessage: pickFileFailureMessage,
  );

  Future<ChatAttachment?> _pickAndStore({
    required AttachmentSourcePicker picker,
    required ChatAttachmentKind kind,
    required String failureMessage,
  }) async {
    try {
      final picked = await picker();
      if (picked == null) {
        return null;
      }
      final fileName = _displayNameOf(picked);
      final id = _newUuid();
      final extension = _extensionOf(fileName);
      final storedName = extension.isEmpty ? id : '$id.$extension';

      final supportDirectory = await _supportDirectoryProvider();
      final attachmentsDirectory = Directory(
        '${supportDirectory.path}${Platform.pathSeparator}attachments',
      );
      await attachmentsDirectory.create(recursive: true);
      final storedPath =
          '${attachmentsDirectory.path}${Platform.pathSeparator}$storedName';

      final bytes = await picked.readAsBytes();
      await File(storedPath).writeAsBytes(bytes, flush: true);

      return ChatAttachment(
        id: id,
        kind: kind,
        fileName: fileName,
        storedPath: storedPath,
        byteSize: bytes.length,
      );
    } catch (_) {
      throw ChatAttachmentException(failureMessage);
    }
  }

  static String _displayNameOf(XFile picked) {
    if (picked.name.isNotEmpty) {
      return picked.name;
    }
    final path = picked.path;
    final separatorIndex = path.lastIndexOf(Platform.pathSeparator);
    return separatorIndex < 0 ? path : path.substring(separatorIndex + 1);
  }

  static String _extensionOf(String fileName) {
    final dotIndex = fileName.lastIndexOf('.');
    if (dotIndex <= 0 || dotIndex == fileName.length - 1) {
      return '';
    }
    return fileName.substring(dotIndex + 1).toLowerCase();
  }

  static String _newUuid() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    final hex = bytes
        .map((value) => value.toRadixString(16).padLeft(2, '0'))
        .join();
    return '${hex.substring(0, 8)}-'
        '${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-'
        '${hex.substring(16, 20)}-'
        '${hex.substring(20)}';
  }
}
