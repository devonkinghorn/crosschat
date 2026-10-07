import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'src/backend/backend.dart';
import 'src/backend/demo_backend.dart';
import 'src/backend/ffi_backend.dart';
import 'src/local/local_server.dart';
import 'src/rust/frb_generated.dart';
import 'src/state/app_state.dart';
import 'src/state/settings.dart';
import 'src/ui/home_shell.dart';
import 'src/ui/setup_screen.dart';
import 'src/ui/theme.dart';

const _demoDefine = bool.fromEnvironment('CROSSCHAT_DEMO');

/// Demo mode: sample data, no homeserver. `--dart-define=CROSSCHAT_DEMO=true`
/// at build time or `CROSSCHAT_DEMO=1` in the environment (desktop).
bool get _demo => _demoDefine || (!kIsWeb && Platform.environment['CROSSCHAT_DEMO'] == '1');

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final state = await createAppState();
  runApp(CrosschatApp(state: state));
  await state.init();
}

/// Build the app state the way `main` does (also used by integration tests).
Future<AppState> createAppState() async {
  ChatBackend backend;
  LocalServerController? local;
  if (_demo) {
    backend = DemoBackend(autoLogin: true);
  } else {
    try {
      await RustLib.init();
      backend = FfiBackend();
      if (!kIsWeb && (Platform.isMacOS || Platform.isLinux)) local = ProcessLocalServer();
    } catch (e) {
      debugPrint('Rust core unavailable ($e); falling back to demo data');
      backend = DemoBackend();
    }
  }
  final settings = await AppSettings.load();
  return AppState(backend: backend, settings: settings, localServer: local);
}

class CrosschatApp extends StatelessWidget {
  const CrosschatApp({super.key, required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Crosschat',
    debugShowCheckedModeBanner: false,
    theme: buildTheme(),
    home: ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        if (state.initializing) {
          return Scaffold(
            body: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const CircularProgressIndicator(),
                  if (state.localStatus != null) ...[
                    const SizedBox(height: 16),
                    Text(state.localStatus!.detail, key: const Key('init-progress')),
                  ],
                ],
              ),
            ),
          );
        }
        if (state.session == null) return SetupScreen(state: state);
        return HomeShell(state: state);
      },
    ),
  );
}
