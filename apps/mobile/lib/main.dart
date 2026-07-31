import 'package:flutter/widgets.dart';
import 'package:halo_mobile/app/app.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // Cold-start beacons for the one bug a screenshot cannot localize: a white
  // screen is either Dart never entering or entering and never presenting.
  // These two lines in os_log say which. Safe text only.
  // ignore: avoid_print
  print('halo.boot main');
  WidgetsBinding.instance.addPostFrameCallback((_) {
    // ignore: avoid_print
    print('halo.boot first-frame');
  });
  const initialLocation = String.fromEnvironment(
    'HALO_INITIAL_ROUTE',
    defaultValue: '/conversations',
  );
  runApp(const HaloApp(initialLocation: initialLocation));
}
