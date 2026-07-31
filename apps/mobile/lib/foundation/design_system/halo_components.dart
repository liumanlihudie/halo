import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:halo_mobile/foundation/design_system/halo_icons.dart';
import 'package:halo_mobile/foundation/design_system/halo_tokens.dart';

class HaloPageScaffold extends StatelessWidget {
  const HaloPageScaffold({
    required this.title,
    required this.body,
    this.leading,
    this.actions = const [],
    this.backgroundColor = HaloColors.paper,
    this.compactTitle = false,
    this.titleBadge,
    this.titleBadgeTone = HaloTagTone.accent,
    this.bottom,
    super.key,
  });

  final String title;
  final Widget body;
  final Widget? leading;
  final List<Widget> actions;
  final Color backgroundColor;
  final bool compactTitle;
  final String? titleBadge;
  final HaloTagTone titleBadgeTone;
  final Widget? bottom;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: HaloColors.paper,
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            Material(
              key: const ValueKey('halo-nav-surface'),
              color: HaloColors.paper,
              child: HaloNavBar(
                title: title,
                leading: leading,
                actions: actions,
                compactTitle: compactTitle,
                titleBadge: titleBadge,
                titleBadgeTone: titleBadgeTone,
              ),
            ),
            Expanded(
              child: Material(
                key: const ValueKey('halo-body-surface'),
                color: backgroundColor,
                child: body,
              ),
            ),
            ?bottom,
          ],
        ),
      ),
    );
  }
}

class HaloNavBar extends StatelessWidget {
  const HaloNavBar({
    required this.title,
    this.leading,
    this.actions = const [],
    this.compactTitle = false,
    this.titleBadge,
    this.titleBadgeTone = HaloTagTone.accent,
    super.key,
  });

  final String title;
  final Widget? leading;
  final List<Widget> actions;
  final bool compactTitle;
  final String? titleBadge;
  final HaloTagTone titleBadgeTone;

  @override
  Widget build(BuildContext context) {
    final titleWidget = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(
          child: Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: compactTitle ? TextAlign.center : TextAlign.left,
            style: compactTitle
                ? HaloTextStyles.compactTitle
                : HaloTextStyles.pageTitle,
          ),
        ),
        if (titleBadge case final badge?) ...[
          const SizedBox(width: 6),
          HaloTag(badge, tone: titleBadgeTone),
        ],
      ],
    );

    if (!compactTitle) {
      return SizedBox(
        height: HaloMetrics.navigationBarHeight,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(15, 3, 15, 9),
          child: Row(
            children: [
              if (leading != null) ...[leading!, const SizedBox(width: 8)],
              Expanded(child: titleWidget),
              ...actions,
            ],
          ),
        ),
      );
    }

    return SizedBox(
      height: HaloMetrics.navigationBarHeight,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(15, 3, 15, 9),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                leading ?? const SizedBox(width: HaloMetrics.iconButtonSize),
                Row(mainAxisSize: MainAxisSize.min, children: actions),
              ],
            ),
          ),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 235),
            child: titleWidget,
          ),
        ],
      ),
    );
  }
}

class HaloIconButton extends StatelessWidget {
  const HaloIconButton({
    required this.prototypeIconClass,
    required this.semanticLabel,
    this.onPressed,
    this.primary = false,
    this.iconSize = 18,
    super.key,
  });

  final String prototypeIconClass;
  final String semanticLabel;
  final VoidCallback? onPressed;
  final bool primary;
  final double iconSize;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: semanticLabel,
      child: SizedBox.square(
        dimension: HaloMetrics.iconButtonSize,
        child: IconButton(
          padding: EdgeInsets.zero,
          splashRadius: 19,
          style: IconButton.styleFrom(
            backgroundColor: primary ? HaloColors.accent : Colors.transparent,
            foregroundColor: primary ? Colors.white : HaloColors.ink,
          ),
          onPressed: onPressed,
          icon: Icon(
            HaloIcon.requirePrototypeClass(prototypeIconClass),
            size: iconSize,
          ),
        ),
      ),
    );
  }
}

class HaloSearchField extends StatelessWidget {
  const HaloSearchField({
    required this.placeholder,
    this.onTap,
    this.controller,
    this.onChanged,
    this.readOnly = true,
    super.key,
  });

  final String placeholder;
  final VoidCallback? onTap;
  final TextEditingController? controller;
  final ValueChanged<String>? onChanged;
  final bool readOnly;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: HaloMetrics.searchHeight,
      child: TextField(
        controller: controller,
        readOnly: readOnly,
        onTap: onTap,
        onChanged: onChanged,
        textAlign: TextAlign.center,
        style: HaloTextStyles.body,
        decoration: InputDecoration(
          hintText: placeholder,
          hintStyle: const TextStyle(color: Color(0xFF9CA1AA), fontSize: 13),
          prefixIcon: Icon(
            HaloIcon.requirePrototypeClass('ph ph-magnifying-glass'),
            size: 17,
            color: const Color(0xFF9CA1AA),
          ),
          prefixIconConstraints: const BoxConstraints(minWidth: 33),
          filled: true,
          fillColor: const Color(0xFFF1F2F5),
          contentPadding: const EdgeInsets.symmetric(horizontal: 10),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(HaloRadii.search),
            borderSide: BorderSide.none,
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(HaloRadii.search),
            borderSide: BorderSide.none,
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(HaloRadii.search),
            borderSide: const BorderSide(color: HaloColors.accent, width: 1.5),
          ),
        ),
      ),
    );
  }
}

enum HaloAvatarTone { accent, red, green, purple, gold, blue, slate }

class HaloAvatar extends StatelessWidget {
  const HaloAvatar({
    this.imageUrl,
    this.letter,
    this.svgAsset,
    this.size = HaloMetrics.avatarSize,
    this.backgroundColor,
    this.tone = HaloAvatarTone.accent,
    super.key,
  }) : assert(imageUrl != null || letter != null || svgAsset != null);

  final String? imageUrl;
  final String? letter;

  /// A designed badge bundled with the app. Preferred over [imageUrl]: it is
  /// always available offline and never a stock photo of a stranger.
  final String? svgAsset;
  final double size;
  final Color? backgroundColor;
  final HaloAvatarTone tone;

  @override
  Widget build(BuildContext context) {
    final radius = size == HaloMetrics.avatarSize
        ? HaloRadii.avatar
        : HaloRadii.compactAvatar;
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: SizedBox.square(
        dimension: size,
        child: svgAsset != null
            ? SvgPicture.asset(svgAsset!, fit: BoxFit.cover)
            : imageUrl != null
            ? Image.network(
                imageUrl!,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => _letterAvatar(),
              )
            : _letterAvatar(),
      ),
    );
  }

  Widget _letterAvatar() {
    final colors = switch (tone) {
      HaloAvatarTone.accent => const [Color(0xFF596BD9), Color(0xFF303D89)],
      HaloAvatarTone.red => const [Color(0xFFCF5961), Color(0xFF8F3239)],
      HaloAvatarTone.green => const [Color(0xFF2D9C83), Color(0xFF176253)],
      HaloAvatarTone.purple => const [Color(0xFF7A68D8), Color(0xFF44388E)],
      HaloAvatarTone.gold => const [Color(0xFFB07A39), Color(0xFF694219)],
      HaloAvatarTone.blue => const [Color(0xFF3476B9), Color(0xFF1F456D)],
      HaloAvatarTone.slate => const [Color(0xFF596172), Color(0xFF2E3440)],
    };
    return DecoratedBox(
      decoration: BoxDecoration(
        color: backgroundColor,
        gradient: backgroundColor == null
            ? LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: colors,
              )
            : null,
      ),
      child: Center(
        child: Text(
          letter ?? 'H',
          style: TextStyle(
            color: Colors.white,
            fontSize: size * 0.34,
            fontWeight: FontWeight.w800,
          ),
        ),
      ),
    );
  }
}

class HaloGroupAvatar extends StatelessWidget {
  const HaloGroupAvatar({
    required this.tiles,
    this.size = HaloMetrics.avatarSize,
    super.key,
  }) : assert(tiles.length == 4);

  final List<String> tiles;
  final double size;

  @override
  Widget build(BuildContext context) {
    final tileSize = (size - 8) / 2;
    return ClipRRect(
      borderRadius: BorderRadius.circular(HaloRadii.avatar),
      child: SizedBox.square(
        dimension: size,
        child: ColoredBox(
          color: const Color(0xFFE9EBF0),
          child: Padding(
            padding: const EdgeInsets.all(3),
            child: Wrap(
              spacing: 2,
              runSpacing: 2,
              children: [
                for (final (index, tile) in tiles.indexed)
                  ClipRRect(
                    key: ValueKey('group-avatar-tile-$index'),
                    borderRadius: BorderRadius.circular(6),
                    child: SizedBox.square(
                      dimension: tileSize,
                      child: tile.startsWith('letter:')
                          ? ColoredBox(
                              color: const Color(0xFF6673C5),
                              child: Center(
                                child: Text(
                                  tile.substring(7),
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 8,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                            )
                          : Image.network(
                              tile,
                              fit: BoxFit.cover,
                              errorBuilder: (_, _, _) =>
                                  const ColoredBox(color: HaloColors.accent),
                            ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

enum HaloTagTone { accent, green, amber, red, gray }

class HaloTag extends StatelessWidget {
  const HaloTag(this.label, {this.tone = HaloTagTone.accent, super.key});

  final String label;
  final HaloTagTone tone;

  @override
  Widget build(BuildContext context) {
    final (background, foreground) = switch (tone) {
      HaloTagTone.accent => (HaloColors.accentSoft, HaloColors.accentDeep),
      HaloTagTone.green => (const Color(0xFFE9F6F1), const Color(0xFF23825D)),
      HaloTagTone.amber => (const Color(0xFFFFF3E3), const Color(0xFFB67320)),
      HaloTagTone.red => (const Color(0xFFFFEDEF), const Color(0xFFC9444B)),
      HaloTagTone.gray => (const Color(0xFFF0F1F4), const Color(0xFF7B808A)),
    };
    return SizedBox(
      height: 17,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.circular(HaloRadii.tag),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 5),
          child: Center(
            child: Text(
              label,
              style: TextStyle(
                color: foreground,
                fontSize: 8,
                fontWeight: FontWeight.w700,
                height: 1,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class HaloSectionLabel extends StatelessWidget {
  const HaloSectionLabel(this.label, {super.key});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(1, 15, 1, 5),
      child: Text(label, style: HaloTextStyles.sectionLabel),
    );
  }
}

class HaloSettingsGroup extends StatelessWidget {
  const HaloSettingsGroup({required this.children, super.key});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(HaloRadii.card),
      child: ColoredBox(
        color: HaloColors.paper,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var index = 0; index < children.length; index++) ...[
              children[index],
              if (index != children.length - 1)
                const Divider(height: 1, color: HaloColors.line),
            ],
          ],
        ),
      ),
    );
  }
}

class HaloSettingsRow extends StatelessWidget {
  const HaloSettingsRow({
    required this.label,
    this.prototypeIconClass,
    this.detail,
    this.trailing,
    this.onTap,
    super.key,
  });

  final String label;
  final String? prototypeIconClass;
  final String? detail;
  final Widget? trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            minHeight: HaloMetrics.settingsRowHeight,
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 8),
            child: Row(
              children: [
                if (prototypeIconClass case final iconClass?) ...[
                  DecoratedBox(
                    decoration: BoxDecoration(
                      color: HaloColors.accentSoft,
                      borderRadius: BorderRadius.circular(
                        HaloRadii.settingsIcon,
                      ),
                    ),
                    child: SizedBox.square(
                      dimension: 30,
                      child: Icon(
                        HaloIcon.requirePrototypeClass(iconClass),
                        size: 17,
                        color: HaloColors.accentDeep,
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                ],
                Expanded(child: Text(label, style: HaloTextStyles.body)),
                if (detail != null)
                  Flexible(
                    child: Text(
                      detail!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.end,
                      style: const TextStyle(
                        color: Color(0xFF979CA6),
                        fontSize: 11,
                      ),
                    ),
                  ),
                if (trailing != null) ...[const SizedBox(width: 8), trailing!],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class HaloSwitch extends StatelessWidget {
  const HaloSwitch({
    required this.value,
    required this.onChanged,
    this.semanticLabel,
    super.key,
  });

  final bool value;
  final ValueChanged<bool>? onChanged;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: semanticLabel,
      toggled: value,
      enabled: onChanged != null,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onChanged == null ? null : () => onChanged!(!value),
        child: SizedBox(
          width: 43,
          height: 25,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOut,
            padding: const EdgeInsets.all(3),
            decoration: BoxDecoration(
              color: value ? HaloColors.accent : const Color(0xFFCDD1D9),
              borderRadius: BorderRadius.circular(14),
            ),
            child: AnimatedAlign(
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeOut,
              alignment: value ? Alignment.centerRight : Alignment.centerLeft,
              child: Container(
                width: 19,
                height: 19,
                decoration: const BoxDecoration(
                  color: Colors.white,
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: Color(0x33000000),
                      blurRadius: 3,
                      offset: Offset(0, 1),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
