import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'src/backend/backend.dart';
import 'src/backend/demo_backend.dart';
import 'src/backend/ffi_backend.dart';
import 'src/rust/frb_generated.dart';
import 'src/state/app_state.dart';
import 'src/state/settings.dart';
import 'src/ui/home_shell.dart';
import 'src/ui/login_screen.dart';
import 'src/ui/theme.dart';

const _demoDefine = bool.fromEnvironment('CROSSCHAT_DEMO');

/// Demo mode: sample data, no homeserver. `--dart-define=CROSSCHAT_DEMO=true`
/// at build time or `CROSSCHAT_DEMO=1` in the environment (desktop).
bool get _demo => _demoDefine || (!kIsWeb && Platform.environment['CROSSCHAT_DEMO'] == '1');

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  ChatBackend backend;
  if (_demo) {
    backend = DemoBackend(autoLogin: true);
  } else {
    try {
      await RustLib.init();
      backend = FfiBackend();
    } catch (e) {
      debugPrint('Rust core unavailable ($e); falling back to demo data');
      backend = DemoBackend();
    }
  }
  final settings = await AppSettings.load();
  final state = AppState(backend: backend, settings: settings);
  runApp(CrosschatApp(state: state));
  await state.init();
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
          return const Scaffold(body: Center(child: CircularProgressIndicator()));
        }
        if (state.session == null) return LoginScreen(state: state);
        return HomeShell(state: state);
      },
    ),
  );
}
