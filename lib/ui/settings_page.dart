import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/saved_item.dart';
import '../services/ai_service.dart';
import '../services/link_parser.dart';
import '../state/providers.dart';

/// Settings: Gemini key management + "test key" that runs a real
/// categorize call so users can verify the key works before saving links.
class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({super.key});
  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends ConsumerState<SettingsPage> {
  final _key = TextEditingController();
  bool _loaded = false;
  bool _obscure = true;
  bool _testing = false;
  String? _testResult;

  @override
  void initState() {
    super.initState();
    AiService().getApiKey().then((v) {
      _key.text = v ?? '';
      setState(() => _loaded = true);
    });
  }

  @override
  void dispose() {
    _key.dispose();
    super.dispose();
  }

  Future<void> _testKey() async {
    final key = _key.text.trim();
    if (key.isEmpty) {
      setState(() => _testResult = 'Paste a key first.');
      return;
    }
    setState(() {
      _testing = true;
      _testResult = null;
    });
    try {
      await AiService().saveApiKey(key);
      // Real end-to-end check with a fixed probe article.
      final meta = await LinkParser.fetchMeta('https://www.youtube.com/watch?v=dQw4w9WgXcQ');
      final ai = AiService();
      final r = await ai.enrichWithFlag(url: 'https://www.youtube.com/watch?v=dQw4w9WgXcQ', meta: meta);
      setState(() {
        _testResult = r.usedAi
            ? '✓ Key works — probe categorized as "${r.enrichment.category.name}" with summary.'
            : '✗ Key saved but AI failed: ${r.enrichment.error ?? 'unknown error'}';
      });
    } catch (e) {
      setState(() => _testResult = '✗ Test failed: $e');
    } finally {
      setState(() => _testing = false);
    }
  }

  Future<void> _retryPending() async {
    final items = await ref.read(itemsProvider.future);
    final ai = AiService();
    var fixed = 0;
    for (final item in items.where((e) => !e.aiProcessed)) {
      try {
        final meta = await LinkParser.fetchMeta(item.url);
        final r = await ai.enrichWithFlag(url: item.url, meta: meta);
        if (r.usedAi) {
          fixed++;
          await _upsertEnriched(item.id, r.enrichment.category, r.enrichment.summary, r.enrichment.tags);
        }
      } catch (_) {}
    }
    ref.invalidate(itemsProvider);
    ref.invalidate(countsProvider);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(fixed == 0 ? 'Nothing to retry (or AI still failing)' : 'Re-categorized $fixed item(s) with AI ✓')));
    }
  }

  Future<void> _upsertEnriched(
      String itemId, Category category, String summary, List<String> tags) async {
    final items = await ref.read(itemsProvider.future);
    final item = items.where((e) => e.id == itemId).firstOrNull;
    if (item == null) return;
    final container = ProviderScope.containerOf(context, listen: false);
    final db = container.read(dbProviderForRetry);
    await db.upsert(item.copyWith(
      category: category,
      summary: summary.isNotEmpty ? summary : item.summary,
      tags: tags,
      aiProcessed: true,
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text('AI categorization',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          const Text(
              'Paste a Gemini API key (free at aistudio.google.com → Get API key). Stored only on this device. Without a key, the app uses offline rules.\n\nIf items show "offline rules" even with a key, use Test key below — it will tell you exactly what is wrong (bad key, quota, blocked model).'),
          const SizedBox(height: 12),
          if (!_loaded)
            const Center(child: CircularProgressIndicator())
          else
            TextField(
              controller: _key,
              obscureText: _obscure,
              decoration: InputDecoration(
                labelText: 'Gemini API key',
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(
                  icon: Icon(_obscure ? Icons.visibility : Icons.visibility_off),
                  onPressed: () => setState(() => _obscure = !_obscure),
                ),
              ),
            ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton(
                onPressed: () async {
                  await AiService().saveApiKey(_key.text);
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('API key saved')));
                  }
                },
                child: const Text('Save key'),
              ),
              FilledButton.tonal(
                onPressed: _testing ? null : _testKey,
                child: _testing
                    ? const SizedBox(
                        width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Text('Test key'),
              ),
              OutlinedButton(
                onPressed: () async {
                  await AiService().clearApiKey();
                  _key.clear();
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('API key removed — rules mode')));
                  }
                },
                child: const Text('Remove'),
              ),
            ],
          ),
          if (_testResult != null) ...[
            const SizedBox(height: 12),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Text(_testResult!),
              ),
            ),
          ],
          const SizedBox(height: 24),
          const Text('Library',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          const Text(
              'Items saved while the AI was unreachable show an "offline rules" badge. Once your key works, retry them:'),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            icon: const Icon(Icons.auto_awesome),
            label: const Text('Retry AI for offline items'),
            onPressed: _retryPending,
          ),
        ],
      ),
    );
  }
}

extension<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
