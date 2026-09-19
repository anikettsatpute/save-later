import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';

import 'services/share_parser.dart';
import 'ui/add_sheet.dart';
import 'ui/inbox_page.dart';

void main() {
  runApp(const ProviderScope(child: SaveLaterApp()));
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
    // Cold start from a share.
    ReceiveSharingIntent.instance.getInitialMedia().then(_handleShared);
    // While running.
    ReceiveSharingIntent.instance.getMediaStream().listen(_handleShared);
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
