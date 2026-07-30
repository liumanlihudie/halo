import 'dart:io';

import 'package:flutter/services.dart';
import 'package:gal/gal.dart';
import 'package:share_plus/share_plus.dart';

/// What a long-pressed message offers, resolved from its content.
///
/// System side effects (clipboard, photo library, share sheet) are injectable
/// so tests exercise the mapping without platform channels.
class MessageActionsService {
  MessageActionsService({
    Future<void> Function(String text)? copyToClipboard,
    Future<void> Function(String text)? shareText,
    Future<void> Function(String path)? shareFile,
    Future<void> Function(String path)? saveImageToGallery,
  }) : _copyToClipboard = copyToClipboard ?? _systemCopy,
       _shareText = shareText ?? _systemShareText,
       _shareFile = shareFile ?? _systemShareFile,
       _saveImageToGallery = saveImageToGallery ?? _systemSaveImage;

  final Future<void> Function(String text) _copyToClipboard;
  final Future<void> Function(String text) _shareText;
  final Future<void> Function(String path) _shareFile;
  final Future<void> Function(String path) _saveImageToGallery;

  Future<void> copyText(String text) async {
    if (text.trim().isEmpty) {
      throw const MessageActionException('没有可复制的文字');
    }
    await _run(() => _copyToClipboard(text), '复制失败，请重试');
  }

  Future<void> shareText(String text) async {
    if (text.trim().isEmpty) {
      throw const MessageActionException('没有可分享的内容');
    }
    await _run(() => _shareText(text), '分享失败，请重试');
  }

  /// Shares a local file; on iOS the sheet includes 存储到文件.
  Future<void> shareFile(String path) async {
    _requireLocalFile(path);
    await _run(() => _shareFile(path), '分享失败，请重试');
  }

  Future<void> saveImageToGallery(String path) async {
    _requireLocalFile(path);
    await _run(() => _saveImageToGallery(path), '保存到相册失败，请检查相册权限');
  }

  void _requireLocalFile(String path) {
    // Remote fixture URLs have nothing on disk to hand to the system.
    if (path.startsWith('http') || !File(path).existsSync()) {
      throw const MessageActionException('文件不在本机，无法操作');
    }
  }

  Future<void> _run(
    Future<void> Function() action,
    String failureMessage,
  ) async {
    try {
      await action();
    } on MessageActionException {
      rethrow;
    } catch (_) {
      // Raw platform error text never reaches the UI.
      throw MessageActionException(failureMessage);
    }
  }

  static Future<void> _systemCopy(String text) =>
      Clipboard.setData(ClipboardData(text: text));

  static Future<void> _systemShareText(String text) =>
      SharePlus.instance.share(ShareParams(text: text));

  static Future<void> _systemShareFile(String path) =>
      SharePlus.instance.share(ShareParams(files: [XFile(path)]));

  static Future<void> _systemSaveImage(String path) => Gal.putImage(path);
}

final class MessageActionException implements Exception {
  const MessageActionException(this.safeMessage);

  final String safeMessage;
}
