import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Ends the assistant session. The single Close path for the assistant
/// surface; the Android side will replace the default with its own central
/// session-ending path.
final assistantCloseProvider = Provider<VoidCallback>(
  (ref) =>
      () => SystemNavigator.pop(),
);
