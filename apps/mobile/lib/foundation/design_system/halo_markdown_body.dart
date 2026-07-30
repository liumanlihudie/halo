import 'package:flutter/material.dart';
import 'package:gpt_markdown/gpt_markdown.dart';

import 'halo_tokens.dart';

/// Renders agent chat-bubble text as rich markdown, themed for Halo.
///
/// - Base text matches [HaloTextStyles.body] so plain text is visually
///   identical to a plain `Text(text, style: HaloTextStyles.body)`.
/// - Headings are only slightly larger than body text (chat bubble, not a
///   document).
/// - Inline code and fenced code blocks use a soft grey background from
///   [HaloColors]; long code blocks scroll horizontally instead of
///   overflowing the bubble.
/// - Links are tinted with the accent colour but are not tappable yet.
class HaloMarkdownBody extends StatelessWidget {
  const HaloMarkdownBody(this.text, {super.key});

  final String text;

  static const _monoFallback = <String>[
    'Menlo',
    'SF Mono',
    'Roboto Mono',
    'monospace',
  ];

  static const _codeTextStyle = TextStyle(
    color: HaloColors.ink,
    fontSize: 12,
    height: 1.5,
    fontFamilyFallback: _monoFallback,
  );

  static TextStyle _heading(double fontSize, FontWeight weight) => TextStyle(
    color: HaloColors.ink,
    fontSize: fontSize,
    height: 1.35,
    fontWeight: weight,
  );

  @override
  Widget build(BuildContext context) {
    if (text.trim().isEmpty) {
      return const SizedBox.shrink();
    }
    return GptMarkdownTheme(
      gptThemeData: GptMarkdownThemeData(
        brightness: Brightness.light,
        highlightColor: HaloColors.soft,
        h1: _heading(17, FontWeight.w700),
        h2: _heading(16, FontWeight.w700),
        h3: _heading(15, FontWeight.w600),
        h4: _heading(14, FontWeight.w600),
        h5: _heading(13, FontWeight.w600),
        h6: _heading(13, FontWeight.w600),
        hrLineThickness: 1,
        hrLineColor: HaloColors.line,
        linkColor: HaloColors.accent,
        linkHoverColor: HaloColors.accentDeep,
        autoAddDividerLineAfterH1: false,
      ),
      child: GptMarkdown(
        text,
        style: HaloTextStyles.body,
        highlightBuilder: _buildInlineCode,
        codeBuilder: _buildCodeBlock,
        linkBuilder: _buildLink,
      ),
    );
  }

  /// Inline `code`: soft grey chip, monospace, no bold surprise.
  Widget _buildInlineCode(BuildContext context, String text, TextStyle style) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
      decoration: BoxDecoration(
        color: HaloColors.soft,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        text,
        style: _codeTextStyle.copyWith(
          fontSize: (style.fontSize ?? HaloTextStyles.body.fontSize ?? 13) - 1,
        ),
      ),
    );
  }

  /// Fenced code block: soft grey panel that scrolls horizontally so long
  /// lines never overflow the chat bubble.
  Widget _buildCodeBlock(
    BuildContext context,
    String name,
    String code,
    bool closed,
  ) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(vertical: 4),
      decoration: BoxDecoration(
        color: HaloColors.soft,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: HaloColors.line),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Text(code, style: _codeTextStyle),
      ),
    );
  }

  /// Links: accent-coloured and underlined, but not tappable for now.
  Widget _buildLink(
    BuildContext context,
    InlineSpan text,
    String url,
    TextStyle style,
  ) {
    return Text.rich(
      text,
      style: style.copyWith(
        color: HaloColors.accent,
        decoration: TextDecoration.underline,
        decorationColor: HaloColors.accent,
      ),
    );
  }
}
