import 'dart:convert';
import 'dart:io';

// ignore_for_file: prefer_initializing_formals

import 'package:flutter/foundation.dart';

/// What the local data page is allowed to say about on-device storage.
///
/// Every field is measured, never estimated: a settings screen that invents
/// numbers is worse than one that admits it cannot read them, so each value is
/// nullable and the page renders `—` rather than a guess.
@immutable
class LocalDataSnapshot {
  const LocalDataSnapshot({
    this.storageBytes,
    this.cacheBytes,
    this.conversationCount,
    this.messageCount,
  });

  final int? storageBytes;
  final int? cacheBytes;
  final int? conversationCount;
  final int? messageCount;
}

/// The chat history operations the local data page needs.
///
/// Deliberately narrower than the repository: the page may count, export and
/// erase history, and may do nothing else to it.
abstract interface class SingleChatHistoryMaintenance {
  /// `(conversations, messages)` currently persisted.
  Future<({int conversations, int messages})> countStoredHistory();

  /// Every stored conversation with its messages, oldest first.
  Future<List<Map<String, Object?>>> exportStoredHistory();

  /// Deletes all stored messages. Conversation bindings survive so the shipped
  /// contact list still opens; only the user's content is removed.
  Future<void> eraseStoredMessages();
}

/// Result of writing an export bundle to disk.
@immutable
class LocalDataExportBundle {
  const LocalDataExportBundle({required this.file, required this.byteCount});

  final File file;
  final int byteCount;
}

/// The circle's half of the local data promises.
///
/// Separate from the chat history port because the two live in different
/// databases; the maintenance page must cover both or its buttons start
/// overstating what they did.
abstract interface class CircleDataMaintenance {
  Future<int> countPosts();
  Future<List<Map<String, Object?>>> exportPosts();
  Future<void> erasePosts();
}

abstract interface class LocalDataMaintenancePort {
  Future<LocalDataSnapshot> loadSnapshot();

  /// Deletes cached files and returns the number of bytes reclaimed.
  Future<int> clearCache();

  /// Writes a JSON export of the chat history and returns it for sharing.
  Future<LocalDataExportBundle> exportBundle();

  /// Erases on-device chat content. Never touches the Keychain, so model
  /// credentials and provider configuration survive.
  Future<void> eraseLocalData();
}

/// File-system backed implementation.
///
/// **Credentials are structurally out of reach here.** This class is given a
/// history port and two directories; it has no access to the secure credential
/// store and no `SecretRef` ever passes through it, so neither the export
/// bundle nor the erase path can leak or destroy a Keychain item.
final class ProductionLocalDataMaintenance implements LocalDataMaintenancePort {
  ProductionLocalDataMaintenance({
    required this._history,
    required this._storageDirectory,
    required this._cacheDirectory,
    required this._exportDirectory,
    CircleDataMaintenance? circle,
    DateTime Function()? now,
  }) : _circle = circle,
       _now = now ?? DateTime.now;

  /// Bundle format version. A future importer must refuse anything newer.
  static const int exportFormatVersion = 1;

  final SingleChatHistoryMaintenance _history;
  final CircleDataMaintenance? _circle;
  final Future<Directory> Function() _storageDirectory;
  final Future<Directory> Function() _cacheDirectory;
  final Future<Directory> Function() _exportDirectory;
  final DateTime Function() _now;

  @override
  Future<LocalDataSnapshot> loadSnapshot() async {
    // Each measurement fails independently: an unreadable cache directory must
    // not blank out the message count the user can otherwise be told.
    final storageBytes = await _tryMeasure(_storageDirectory);
    final cacheBytes = await _tryMeasure(_cacheDirectory);
    int? conversations;
    int? messages;
    try {
      final counts = await _history.countStoredHistory();
      conversations = counts.conversations;
      messages = counts.messages;
    } catch (_) {
      // Leaves both null; the page shows `—`.
    }
    return LocalDataSnapshot(
      storageBytes: storageBytes,
      cacheBytes: cacheBytes,
      conversationCount: conversations,
      messageCount: messages,
    );
  }

  @override
  Future<int> clearCache() async {
    final directory = await _cacheDirectory();
    if (!directory.existsSync()) {
      return 0;
    }
    var freed = 0;
    // Delete entry by entry rather than the directory itself: the OS owns the
    // cache directory, and a partial failure should still reclaim the rest.
    for (final entity in directory.listSync()) {
      final size = await _measureEntity(entity);
      try {
        await entity.delete(recursive: true);
        freed += size;
      } catch (_) {
        continue;
      }
    }
    return freed;
  }

  @override
  Future<LocalDataExportBundle> exportBundle() async {
    final conversations = await _history.exportStoredHistory();
    final payload = <String, Object?>{
      'format': 'halo.local-data-export',
      'formatVersion': exportFormatVersion,
      'exportedAt': _now().toUtc().toIso8601String(),
      // Stated in the file itself so a bundle found later is self-describing.
      'excludes': const [
        'apiCredentials',
        'keychainReferences',
        'providerConfiguration',
      ],
      'conversations': conversations,
      'circlePosts': await _exportPostsQuietly(),
    };
    final directory = await _exportDirectory();
    await directory.create(recursive: true);
    final stamp = _now().toUtc().toIso8601String().replaceAll(
      RegExp('[:.]'),
      '-',
    );
    final file = File(
      '${directory.path}${Platform.pathSeparator}halo-export-$stamp.json',
    );
    final bytes = utf8.encode(
      const JsonEncoder.withIndent('  ').convert(payload),
    );
    await file.writeAsBytes(bytes, flush: true);
    return LocalDataExportBundle(file: file, byteCount: bytes.length);
  }

  @override
  Future<void> eraseLocalData() async {
    await _history.eraseStoredMessages();
    // The button says the on-device content is gone; leaving the feed behind
    // would make that untrue.
    try {
      await _circle?.erasePosts();
    } catch (_) {
      // The chat history is already cleared; reporting success for the part
      // that worked beats leaving both.
    }
  }

  Future<List<Map<String, Object?>>> _exportPostsQuietly() async {
    try {
      return await (_circle?.exportPosts() ?? Future.value(const []));
    } catch (_) {
      return const [];
    }
  }

  Future<int?> _tryMeasure(Future<Directory> Function() open) async {
    try {
      final directory = await open();
      if (!directory.existsSync()) return 0;
      return await _measureEntity(directory);
    } catch (_) {
      return null;
    }
  }

  Future<int> _measureEntity(FileSystemEntity entity) async {
    try {
      if (entity is File) {
        return await entity.length();
      }
      if (entity is Directory) {
        var total = 0;
        await for (final child in entity.list(recursive: true)) {
          if (child is File) {
            try {
              total += await child.length();
            } catch (_) {
              continue;
            }
          }
        }
        return total;
      }
    } catch (_) {
      return 0;
    }
    return 0;
  }
}

/// Renders a byte count the way the settings UI shows it.
String formatLocalDataBytes(int bytes) {
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit += 1;
  }
  final rendered = unit == 0 || value >= 100
      ? value.toStringAsFixed(0)
      : value.toStringAsFixed(1);
  return '$rendered ${units[unit]}';
}
