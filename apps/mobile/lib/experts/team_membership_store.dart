import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// Which installed experts the user has removed from their team.
///
/// The expert catalog itself ships with the app; removal is a durable local
/// choice, not a deletion — the market still lists the expert and can bring
/// it back. Pages listen and re-filter when the set changes.
final class TeamMembershipStore extends ChangeNotifier {
  TeamMembershipStore({File? file}) : _fileOverride = file;

  static final TeamMembershipStore instance = TeamMembershipStore();

  final File? _fileOverride;
  Set<String> _removed = {};
  bool _loaded = false;

  Future<File> _file() async {
    if (_fileOverride != null) return _fileOverride;
    final directory = await getApplicationSupportDirectory();
    return File(
      '${directory.path}${Platform.pathSeparator}removed-experts.json',
    );
  }

  Future<void> ensureLoaded() async {
    if (_loaded) return;
    try {
      final file = await _file();
      if (await file.exists()) {
        final decoded = jsonDecode(await file.readAsString());
        if (decoded is List) {
          _removed = {for (final id in decoded.whereType<String>()) id};
        }
      }
    } catch (_) {
      // An unreadable choice file means nothing was removed — the team shows
      // everyone rather than hiding experts on a guess.
    }
    _loaded = true;
    notifyListeners();
  }

  bool isRemoved(String profileId) => _removed.contains(profileId);

  Future<void> remove(String profileId) async {
    _removed.add(profileId);
    await _persist();
    notifyListeners();
  }

  Future<void> restore(String profileId) async {
    _removed.remove(profileId);
    await _persist();
    notifyListeners();
  }

  Future<void> _persist() async {
    try {
      final file = await _file();
      await file.parent.create(recursive: true);
      await file.writeAsString(jsonEncode(_removed.toList()), flush: true);
    } catch (_) {
      // The in-memory choice still applies this session.
    }
  }
}
