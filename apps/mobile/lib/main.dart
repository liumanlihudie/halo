import 'package:flutter/widgets.dart';
import 'package:halo_mobile/app/app.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  const initialLocation = String.fromEnvironment(
    'HALO_INITIAL_ROUTE',
    defaultValue: '/conversations',
  );
  runApp(const HaloApp(initialLocation: initialLocation));
}
