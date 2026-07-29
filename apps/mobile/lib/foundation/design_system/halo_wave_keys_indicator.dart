import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:halo_mobile/foundation/design_system/halo_tokens.dart';

/// Indeterminate "piano key" wave used while an agent is producing a reply.
///
/// Deliberately indeterminate: an agent turn has no honest completion ratio, so
/// nothing here may be read as progress. Determinate work keeps a real bar.
///
/// The animation never settles, exactly like the indeterminate
/// [LinearProgressIndicator] it replaces, so widget tests covering a running
/// turn must use bounded `pump(duration)` calls rather than `pumpAndSettle`.
class HaloWaveKeysIndicator extends StatefulWidget {
  const HaloWaveKeysIndicator({
    this.keyCount = 5,
    this.keyWidth = 4,
    this.keySpacing = 5,
    this.minKeyHeight = 6,
    this.maxKeyHeight = 18,
    this.period = const Duration(milliseconds: 1100),
    this.color = HaloColors.accent,
    this.semanticLabel = '正在生成回复',
    super.key,
  }) : assert(keyCount > 0),
       assert(minKeyHeight > 0 && maxKeyHeight > minKeyHeight);

  final int keyCount;
  final double keyWidth;
  final double keySpacing;
  final double minKeyHeight;
  final double maxKeyHeight;
  final Duration period;
  final Color color;
  final String semanticLabel;

  @override
  State<HaloWaveKeysIndicator> createState() => _HaloWaveKeysIndicatorState();
}

class _HaloWaveKeysIndicatorState extends State<HaloWaveKeysIndicator>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: widget.period,
  )..repeat();

  @override
  void didUpdateWidget(HaloWaveKeysIndicator oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.period != widget.period) {
      _controller
        ..duration = widget.period
        ..repeat();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: widget.semanticLabel,
      liveRegion: true,
      child: ExcludeSemantics(
        child: SizedBox(
          height: widget.maxKeyHeight,
          child: AnimatedBuilder(
            animation: _controller,
            builder: (context, _) => Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                for (var index = 0; index < widget.keyCount; index++) ...[
                  if (index > 0) SizedBox(width: widget.keySpacing),
                  _WaveKey(
                    width: widget.keyWidth,
                    height: _heightAt(index),
                    color: widget.color,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  double _heightAt(int index) {
    // One full wave travels across the whole row per period.
    final phase = _controller.value - index / (widget.keyCount * 1.6);
    final swing = 0.5 - 0.5 * math.cos(2 * math.pi * phase);
    return widget.minKeyHeight +
        (widget.maxKeyHeight - widget.minKeyHeight) * swing;
  }
}

class _WaveKey extends StatelessWidget {
  const _WaveKey({
    required this.width,
    required this.height,
    required this.color,
  });

  final double width;
  final double height;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(width / 2),
      ),
    );
  }
}
