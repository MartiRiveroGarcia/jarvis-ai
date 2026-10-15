import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// What the voice button shows. Presentation only: the caller decides it from
/// the conversation state.
enum VoiceButtonVisual { idle, listening, thinking, speaking }

/// The app's main interaction point: a large circular push-to-talk button.
///
/// A trigger and a renderer only. It reports presses and activations and
/// draws [visual]; it knows nothing about recording, requests or playback.
///
/// Touch is push-to-talk: [onPressStart] on pointer down, [onPressEnd] on
/// release, [onPressCancel] if the system cancels the pointer. Only the first
/// pointer counts. Accessibility services and keyboards use [onActivate]
/// instead, so no hold is needed. With neither [onPressStart] nor
/// [onActivate], the button is disabled.
class VoiceButton extends StatefulWidget {
  const VoiceButton({
    super.key,
    required this.visual,
    required this.semanticLabel,
    this.semanticValue,
    this.semanticHint,
    this.onPressStart,
    this.onPressEnd,
    this.onPressCancel,
    this.onActivate,
    this.size = 168,
  });

  final VoiceButtonVisual visual;
  final String semanticLabel;
  final String? semanticValue;
  final String? semanticHint;

  final VoidCallback? onPressStart;
  final VoidCallback? onPressEnd;
  final VoidCallback? onPressCancel;

  /// The semantic tap and keyboard activation.
  final VoidCallback? onActivate;

  /// Diameter of the button; reduced on very narrow screens.
  final double size;

  static const pressedScale = 0.94;
  static const pulseDuration = Duration(milliseconds: 2400);
  static const listeningPulseDuration = Duration(milliseconds: 900);

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

  /// The pointer whose release ends the press. Gesture bookkeeping only.
  int? _pointer;
  bool _reduceMotion = false;
  bool _focused = false;

  bool get _enabled => widget.onPressStart != null || widget.onActivate != null;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduceMotion = MediaQuery.disableAnimationsOf(context);
    _syncPulse();
  }

  @override
  void didUpdateWidget(VoiceButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.visual != widget.visual) {
      _syncPulse();
    }
  }

  void _syncPulse() {
    final duration = widget.visual == VoiceButtonVisual.listening
        ? VoiceButton.listeningPulseDuration
        : VoiceButton.pulseDuration;
    if (_reduceMotion || widget.visual == VoiceButtonVisual.thinking) {
      _pulse
        ..stop()
        ..value = 0;
    } else if (!_pulse.isAnimating || _pulse.duration != duration) {
      _pulse
        ..duration = duration
        ..repeat();
    }
  }

  @override
  void dispose() {
    _pulseCurve.dispose();
    _pulse.dispose();
    super.dispose();
  }

  void _handleDown(PointerDownEvent event) {
    final onPressStart = widget.onPressStart;
    if (_pointer != null || onPressStart == null) {
      return;
    }
    setState(() => _pointer = event.pointer);
    HapticFeedback.lightImpact();
    onPressStart();
  }

  void _handleUp(PointerUpEvent event) {
    if (_endPress(event.pointer)) {
      widget.onPressEnd?.call();
    }
  }

  void _handleCancel(PointerCancelEvent event) {
    if (_endPress(event.pointer)) {
      widget.onPressCancel?.call();
    }
  }

  bool _endPress(int pointer) {
    if (pointer != _pointer) {
      return false;
    }
    setState(() => _pointer = null);
    return true;
  }

  void _handleActivate() {
    final onActivate = widget.onActivate;
    if (onActivate == null) {
      return;
    }
    HapticFeedback.lightImpact();
    onActivate();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final enabled = _enabled;
    final activate = widget.onActivate == null ? null : _handleActivate;

    return LayoutBuilder(
      builder: (context, constraints) {
        final size = math.min(widget.size, constraints.maxWidth * 0.5);
        return Semantics(
          button: true,
          enabled: enabled,
          label: widget.semanticLabel,
          value: widget.semanticValue,
          hint: widget.semanticHint,
          // The focus node's own semantics are excluded below.
          focusable: activate != null,
          focused: _focused,
          excludeSemantics: true,
          onTap: activate,
          child: FocusableActionDetector(
            enabled: activate != null,
            actions: {
              ActivateIntent: CallbackAction<ActivateIntent>(
                onInvoke: (_) => activate?.call(),
              ),
            },
            onFocusChange: (focused) => setState(() => _focused = focused),
            child: Listener(
              onPointerDown: _handleDown,
              onPointerUp: _handleUp,
              onPointerCancel: _handleCancel,
              child: SizedBox.square(
                // Room for the pulse ring around the button.
                dimension: size * 1.3,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    if (widget.visual != VoiceButtonVisual.thinking)
                      _PulseRing(
                        scale: _ringScale,
                        opacity: _ringOpacity,
                        size: size,
                        color: _coreColor(colors, enabled),
                      )
                    else if (!_reduceMotion)
                      SizedBox.square(
                        key: const Key('voice-button-progress'),
                        dimension: size * 1.12,
                        child: CircularProgressIndicator(
                          strokeWidth: 3,
                          color: colors.primary,
                        ),
                      ),
                    AnimatedScale(
                      scale: _pointer != null ? VoiceButton.pressedScale : 1,
                      duration: _reduceMotion
                          ? Duration.zero
                          : const Duration(milliseconds: 120),
                      curve: Curves.easeOut,
                      child: _Core(
                        size: size,
                        base: _coreColor(colors, enabled),
                        icon: _icon,
                        iconColor: enabled
                            ? colors.onPrimary
                            : colors.onSurfaceVariant,
                        glow: enabled ? colors.primary : null,
                        focusColor: _focused ? colors.onSurface : null,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Color _coreColor(ColorScheme colors, bool enabled) {
    if (!enabled) {
      return colors.surfaceContainerHighest;
    }
    return widget.visual == VoiceButtonVisual.listening
        ? colors.tertiary
        : colors.primary;
  }

  IconData get _icon => switch (widget.visual) {
    VoiceButtonVisual.idle || VoiceButtonVisual.listening => Icons.mic_rounded,
    VoiceButtonVisual.thinking => Icons.more_horiz_rounded,
    VoiceButtonVisual.speaking => Icons.graphic_eq_rounded,
  };
}

/// Soft ring that grows and fades behind the button.
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
    required this.base,
    required this.icon,
    required this.iconColor,
    required this.glow,
    required this.focusColor,
  });

  final double size;
  final Color base;
  final IconData icon;
  final Color iconColor;
  final Color? glow;
  final Color? focusColor;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      key: const Key('voice-button'),
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: RadialGradient(
          colors: [base, Color.lerp(base, Colors.black, 0.25)!],
        ),
        border: focusColor == null
            ? null
            : Border.all(color: focusColor!, width: 3),
        boxShadow: [
          if (glow case final glow?)
            BoxShadow(
              color: glow.withValues(alpha: 0.3),
              blurRadius: 32,
              spreadRadius: 2,
            ),
        ],
      ),
      child: SizedBox.square(
        dimension: size,
        child: Icon(
          icon,
          key: const Key('voice-button-icon'),
          size: size * 0.38,
          color: iconColor,
        ),
      ),
    );
  }
}
