// Diagnostic probe: surfaces the real production-kernel bootstrap error, which
// HaloApp currently swallows (`app.dart` catchError). Delete or keep as a smoke
// test once bootstrap failures are reported to the user.
import 'package:flutter_test/flutter_test.dart';
import 'package:halo_mobile/app/production_app_kernel.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('production kernel bootstrap reports its real failure', (
    tester,
  ) async {
    Object? failure;
    StackTrace? stack;
    try {
      final kernel = await ProductionAppKernelFactory().create();
      // ignore: avoid_print
      print('KERNEL >>> booted: ${kernel.name}');
      // ignore: avoid_print
      print(
        'KERNEL >>> routing=${kernel.dependencies.modelRouting != null} '
        'settings=${kernel.dependencies.providerSettings != null} '
        'repo=${kernel.dependencies.chatRepository.runtimeType}',
      );
      await kernel.close();
    } catch (error, stackTrace) {
      failure = error;
      stack = stackTrace;
    }
    if (failure != null) {
      // ignore: avoid_print
      print('KERNEL >>> FAILED: ${failure.runtimeType}: $failure');
      // ignore: avoid_print
      print(
        'KERNEL >>> STACK: ${stack.toString().split('\n').take(12).join(' /// ')}',
      );
    }
    expect(failure, isNull, reason: 'bootstrap must succeed on device');
  });
}
