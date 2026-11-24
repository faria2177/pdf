import 'package:material_ui/material_ui.dart';
import 'package:pdfrx/pdfrx.dart';

import 'pages/home_page.dart';
import 'services/intent_service.dart';
import 'services/recent_store.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await pdfrxFlutterInitialize();
  await RecentStore.instance.load();
  runApp(const PdfStudioApp());
}

final navigatorKey = GlobalKey<NavigatorState>();

class PdfStudioApp extends StatefulWidget {
  const PdfStudioApp({super.key});

  @override
  State<PdfStudioApp> createState() => _PdfStudioAppState();
}

class _PdfStudioAppState extends State<PdfStudioApp> {
  @override
  void initState() {
    super.initState();
    // PDFs handed over by other apps ("Open with" / "Share").
    IntentService.instance.start((path) {
      final nav = navigatorKey.currentState;
      if (nav != null) openPdfInViewer(nav.context, path);
    });
  }

  @override
  Widget build(BuildContext context) {
    const seed = Color(0xFFB70228);
    return MaterialApp(
      title: 'PDF Studio',
      navigatorKey: navigatorKey,
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.system,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: seed),
      ),
      darkTheme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: seed, brightness: Brightness.dark),
      ),
      // Android 15+ draws apps edge-to-edge. Keep every screen, bottom sheet and dialog
      // above the system navigation bar (and clear of side cut-outs in landscape).
      builder: (context, child) => ColoredBox(
        color: Theme.of(context).colorScheme.surfaceContainer,
        child: SafeArea(top: false, child: child ?? const SizedBox.shrink()),
      ),
      home: const HomePage(),
    );
  }
}
