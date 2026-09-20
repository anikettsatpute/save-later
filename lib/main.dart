import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';

import 'firebase_options.dart';
import 'services/auth_service.dart';
import 'services/share_parser.dart';
import 'ui/add_sheet.dart';
import 'ui/inbox_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Cloud sync is optional: without `flutterfire configure` output (or on
  // Linux/Windows, where the Firestore SDK doesn't exist) the app runs
  // local-only and hides sign-in UI. See FIREBASE_SETUP.md.
  var firebaseReady = false;
  if (supportsCloudSync) {
    try {
      try {
        await Firebase.initializeApp(
            options: DefaultFirebaseOptions.currentPlatform);
      } catch (_) {
        // No generated options yet — fall back to native config files
        // (google-services.json / GoogleService-Info.plist).
        await Firebase.initializeApp();
      }
      try {
        FirebaseFirestore.instance.settings =
            const Settings(persistenceEnabled: true);
      } catch (_) {
        // Settings can only be set before first use — ignore otherwise.
      }
      firebaseReady = true;
    } catch (_) {
      firebaseReady = false;
    }
  }
  runApp(ProviderScope(overrides: [
    firebaseReadyProvider.overrideWith((_) => firebaseReady),
  ], child: const SaveLaterApp()));
}

class SaveLaterApp extends StatefulWidget {
  const SaveLaterApp({super.key});

  @override
  State<SaveLaterApp> createState() => _SaveLaterAppState();
}

class _SaveLaterAppState extends State<SaveLaterApp> {
  final _navigatorKey = GlobalKey<NavigatorState>();
  bool _sheetOpen = false;

  @override
  void initState() {
    super.initState();
    // Share intents only exist on mobile. On web/desktop the plugin throws
    // MissingPluginException — skip entirely (browser test found this).
    if (kIsWeb) return;
    try {
      // Cold start from a share.
      ReceiveSharingIntent.instance.getInitialMedia().then(_handleShared);
      // While running.
      ReceiveSharingIntent.instance.getMediaStream().listen(_handleShared,
          onError: (_) {});
    } catch (_) {
      // Plugin unavailable (desktop/web) — manual add still works.
    }
  }

  void _handleShared(List<SharedMediaFile> files) {
    if (files.isEmpty || _sheetOpen) return;
    // Combine all shared text parts (some apps send title + url separately).
    final combined = files.map((f) => f.path.trim()).where((t) => t.isNotEmpty).join('\n');
    if (combined.isEmpty) return;
    final parsed = ShareParser.parse(combined);
    if (parsed.url == null) return; // nothing usable shared
    final ctx = _navigatorKey.currentContext;
    if (ctx == null) return;
    _sheetOpen = true;
    showModalBottomSheet(
      context: ctx,
      isScrollControlled: true,
      builder: (_) => AddSheet(initialUrl: parsed.url!, initialNote: parsed.titleHint),
    ).whenComplete(() {
      _sheetOpen = false;
      ReceiveSharingIntent.instance.reset();
    });
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Save Later',
      navigatorKey: _navigatorKey,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo, brightness: Brightness.dark),
        useMaterial3: true,
      ),
      home: const InboxPage(),
    );
  }
}
