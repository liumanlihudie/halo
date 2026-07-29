import 'package:halo_mobile/foundation/design_system/halo_components.dart';

class ConversationFixture {
  const ConversationFixture({
    required this.id,
    required this.title,
    required this.preview,
    required this.time,
    required this.avatarLetter,
    this.sender,
    this.tag,
    this.tagTone = HaloTagTone.accent,
    this.unread = 0,
    this.imageUrl,
    this.groupAvatarTiles,
    this.avatarTone = HaloAvatarTone.accent,
  });

  final String id;
  final String title;
  final String preview;
  final String time;
  final String avatarLetter;
  final String? sender;
  final String? tag;
  final HaloTagTone tagTone;
  final int unread;
  final String? imageUrl;
  final List<String>? groupAvatarTiles;
  final HaloAvatarTone avatarTone;
}

class ExpertFixture {
  const ExpertFixture({
    required this.id,
    required this.name,
    required this.category,
    required this.model,
    required this.status,
    required this.avatarLetter,
    this.imageUrl,
    this.avatarTone = HaloAvatarTone.accent,
  });

  final String id;
  final String name;
  final String category;
  final String model;
  final String status;
  final String avatarLetter;
  final String? imageUrl;
  final HaloAvatarTone avatarTone;
}

class MarketExpertFixture {
  const MarketExpertFixture({
    required this.id,
    required this.name,
    required this.category,
    required this.model,
    required this.description,
  });

  final String id;
  final String name;
  final String category;
  final String model;
  final String description;
}

class CirclePostFixture {
  const CirclePostFixture({
    required this.author,
    required this.source,
    required this.meta,
    required this.title,
    required this.body,
    required this.avatarLetter,
    this.imageUrl,
    this.tone = HaloTagTone.accent,
  });

  final String author;
  final String source;
  final String meta;
  final String title;
  final String body;
  final String avatarLetter;
  final String? imageUrl;
  final HaloTagTone tone;
}

class SettingFixture {
  const SettingFixture({
    required this.title,
    required this.detail,
    required this.iconClass,
    this.toggle,
  });

  final String title;
  final String detail;
  final String iconClass;
  final bool? toggle;
}
