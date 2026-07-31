// ignore_for_file: prefer_initializing_formals

import 'package:flutter/foundation.dart';
import 'package:halo_mobile/features/circle/circle_post_store.dart';

/// Drives the circle feed.
///
/// Loading failures leave the feed empty and say so, rather than falling back
/// to fixtures: an empty circle is the honest state of a new install, and
/// seeded content would read as experts having posted things they never did.
class CircleController extends ChangeNotifier {
  CircleController({required CirclePostStore store}) : _store = store;

  final CirclePostStore _store;

  List<CirclePost> _posts = const [];
  var _loaded = false;
  var _failed = false;

  List<CirclePost> get posts => _posts;
  bool get loaded => _loaded;
  bool get failed => _failed;
  bool get isEmpty => _loaded && !_failed && _posts.isEmpty;

  Future<void> load() async {
    try {
      _posts = await _store.loadFeed();
      _failed = false;
    } catch (_) {
      _posts = const [];
      _failed = true;
    }
    _loaded = true;
    notifyListeners();
  }

  Future<void> delete(String postId) async {
    try {
      await _store.delete(postId);
    } catch (_) {
      // Reload below reports the real state either way.
    }
    await load();
  }

  /// Stops [authorId] publishing anything new. Existing posts stay.
  Future<bool> banAuthor(CirclePostAuthor authorType, String authorId) async {
    try {
      await _store.setCanPublish(authorType, authorId, allowed: false);
      // Deliberately no reload of the feed content: the product requires the
      // posts already published to remain visible.
      notifyListeners();
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<bool> canPublish(CirclePostAuthor authorType, String authorId) {
    try {
      return _store.canPublish(authorType, authorId);
    } catch (_) {
      return Future.value(true);
    }
  }

  Future<void> allowAuthor(CirclePostAuthor authorType, String authorId) async {
    try {
      await _store.setCanPublish(authorType, authorId, allowed: true);
      notifyListeners();
    } catch (_) {
      // Nothing to report: the switch reflects storage on next read.
    }
  }
}
