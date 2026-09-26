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
    // Web: browser-extension / Web Share Target deep link
    // (?url= / ?text= / ?title=). Handled after first frame so the
    // navigator context exists, then the normal save sheet takes over
    // (LinkParser + AI enrich are reused — no auth needed in extension).
    if (kIsWeb) {
      WidgetsBinding.instance
          .addPostFrameCallback((_) => _handleWebDeepLink());
      return;
    }
    // Share intents only exist on mobile. On desktop the plugin throws
    // MissingPluginException — skip entirely (browser test found this).
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
    _openAddSheet(parsed.url!, parsed.titleHint, resetShare: true);
  }

  /// Web entry from the browser extension or OS share sheet:
  /// `/?url=...&title=...&text=...`
  /// Web Share Target delivers `title`, `text`, `url` the same way.
  void _handleWebDeepLink() {
    if (_sheetOpen) return;
    final params = Uri.base.queryParameters;
    if (params.isEmpty) return;
    final rawUrl = (params['url'] ?? '').trim();
    final text = (params['text'] ?? '').trim();
    final title = (params['title'] ?? '').trim();
    // Prefer explicit url=, else extract first http(s) URL from text/title.
    final rawParsed = rawUrl.isNotEmpty ? ShareParser.parse(rawUrl) : null;
    final ShareParseResult parsed;
    if (rawParsed?.url != null) {
      parsed = rawParsed!;
    } else {
      // Fall through to combined text when url= is missing or unusable.
      final combined = [text, title, rawUrl]
          .where((s) => s.isNotEmpty)
          .join('\n');
      if (combined.isEmpty) return;
      parsed = ShareParser.parse(combined);
    }
    if (parsed.url == null) return;
    // Extension tab title wins as the note; else keep the shared hint.
    final note = title.isNotEmpty && !title.contains(parsed.url!)
        ? title
        : parsed.titleHint;
    _openAddSheet(parsed.url!, note, resetShare: false);
  }

  void _openAddSheet(String url, String? note, {required bool resetShare}) {
    final ctx = _navigatorKey.currentContext;
    if (ctx == null) return;
    _sheetOpen = true;
    showModalBottomSheet(
      context: ctx,
      isScrollControlled: true,
      builder: (_) => AddSheet(initialUrl: url, initialNote: note),
    ).whenComplete(() {
      _sheetOpen = false;
      if (resetShare) {
        try {
          ReceiveSharingIntent.instance.reset();
        } catch (_) {}
      }
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
