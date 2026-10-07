import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// The app's main interaction point: a large circular microphone button.
///
/// Sprint 01 only has the idle look and press feedback. The visuals are split
/// into a pulse ring, the core circle and the icon so later voice states
/// (listening, processing, responding) can restyle those layers.
class VoiceButton extends StatefulWidget {
  const VoiceButton({
    super.key,
    required this.onPressed,
    required this.semanticLabel,
    this.semanticHint,
    this.size = 168,
  });

  /// Null disables the button.
  final VoidCallback? onPressed;
  final String semanticLabel;
  final String? semanticHint;

  /// Diameter of the button; reduced on very narrow screens.
  final double size;

  static const pressedScale = 0.94;
  static const pulseDuration = Duration(milliseconds: 2400);

  @override
  State<VoiceButton> createState() => _VoiceButtonState();
}

class _VoiceButtonState extends State<VoiceButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: VoiceButton.pulseDuration,
  );
  late final CurvedAnimation _pulseCurve = CurvedAnimation(
    parent: _pulse,
    curve: Curves.easeOut,
  );
  late final Animation<double> _ringScale = Tween<double>(
    begin: 1,
    end: 1.18,
  ).animate(_pulseCurve);
  late final Animation<double> _ringOpacity = Tween<double>(
    begin: 0.35,
    end: 0,
  ).animate(_pulseCurve);
  bool _pressed = false;
  bool _reduceMotion = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduceMotion = MediaQuery.disableAnimationsOf(context);
    if (_reduceMotion) {
      _pulse
        ..stop()
        ..value = 0;
    } else if (!_pulse.isAnimating) {
      _pulse.repeat();
    }
  }

  @override
  void dispose() {
    _pulseCurve.dispose();
    _pulse.dispose();
    super.dispose();
  }

  void _handleTap() {
    HapticFeedback.lightImpact();
    widget.onPressed?.call();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final enabled = widget.onPressed != null;

    return LayoutBuilder(
      builder: (context, constraints) {
        final size = math.min(widget.size, constraints.maxWidth * 0.5);
        return Semantics(
          button: true,
          enabled: enabled,
          label: widget.semanticLabel,
          hint: widget.semanticHint,
          excludeSemantics: true,
          onTap: enabled ? _handleTap : null,
          child: SizedBox.square(
            // Room for the pulse ring around the button.
            dimension: size * 1.3,
            child: Stack(
              alignment: Alignment.center,
              children: [
                _PulseRing(
                  scale: _ringScale,
                  opacity: _ringOpacity,
                  size: size,
                  color: colors.primary,
                ),
                AnimatedScale(
                  scale: _pressed ? VoiceButton.pressedScale : 1,
                  duration: _reduceMotion
                      ? Duration.zero
                      : const Duration(milliseconds: 120),
                  curve: Curves.easeOut,
                  child: _Core(
                    size: size,
                    colors: colors,
                    enabled: enabled,
                    onTap: enabled ? _handleTap : null,
                    onHighlightChanged: (pressed) =>
                        setState(() => _pressed = pressed),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Soft ring that grows and fades behind the button while idle.
class _PulseRing extends StatelessWidget {
  const _PulseRing({
    required this.scale,
    required this.opacity,
    required this.size,
    required this.color,
  });

  final Animation<double> scale;
  final Animation<double> opacity;
  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return ScaleTransition(
      scale: scale,
      child: FadeTransition(
        opacity: opacity,
        child: Container(
          key: const Key('voice-button-pulse'),
          width: size,
          height: size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: color.withValues(alpha: 0.5),
          ),
        ),
      ),
    );
  }
}

class _Core extends StatelessWidget {
  const _Core({
    required this.size,
    required this.colors,
    required this.enabled,
    required this.onTap,
    required this.onHighlightChanged,
  });

  final double size;
  final ColorScheme colors;
  final bool enabled;
  final VoidCallback? onTap;
  final ValueChanged<bool> onHighlightChanged;

  @override
  Widget build(BuildContext context) {
    final base = enabled ? colors.primary : colors.surfaceContainerHighest;
    return DecoratedBox(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: RadialGradient(
          colors: [base, Color.lerp(base, Colors.black, 0.25)!],
        ),
        boxShadow: [
          if (enabled)
            BoxShadow(
              color: colors.primary.withValues(alpha: 0.3),
              blurRadius: 32,
              spreadRadius: 2,
            ),
        ],
      ),
      child: Material(
        type: MaterialType.transparency,
        shape: const CircleBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          key: const Key('voice-button'),
          customBorder: const CircleBorder(),
          onTap: onTap,
          onHighlightChanged: onHighlightChanged,
          child: SizedBox.square(
            dimension: size,
            child: Icon(
              Icons.mic_rounded,
              size: size * 0.38,
              color: enabled ? colors.onPrimary : colors.onSurfaceVariant,
            ),
          ),
        ),
      ),
    );
  }
}
