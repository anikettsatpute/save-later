import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../models/saved_item.dart';
import '../services/ai_providers.dart';
import '../services/ai_service.dart';
import '../services/link_parser.dart';
import '../state/providers.dart';
import 'login_page.dart';

/// Settings v4: Gemini key + test, retry-AI, auto-tag rules manager
/// (Obsidian-template-style capture pipeline), about.
class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({super.key});
  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends ConsumerState<SettingsPage> {
  final _key = TextEditingController();
  final _orKey = TextEditingController();
  final _orModel = TextEditingController();
  final _azKey = TextEditingController();
  final _azEndpoint = TextEditingController();
  final _azDeployment = TextEditingController();
  final _azVersion = TextEditingController(text: '2024-10-21');
  bool _loaded = false;
  bool _obscure = true;
  bool _orObscure = true;
  bool _azObscure = true;
  bool _testing = false;
  String? _testResult;
  String _model = AiService.availableModels.first;
  AiProviderKind _provider = AiProviderKind.gemini;

  @override
  void initState() {
    super.initState();
    final ai = AiService();
    ai.getApiKey().then((v) {
      _key.text = v ?? '';
      setState(() => _loaded = true);
    });
    ai.getModel().then((m) {
      if (mounted) setState(() => _model = m);
    });
    ai.getProvider().then((p) {
      if (mounted) setState(() => _provider = p);
    });
    ai.getOpenRouterKey().then((v) {
      _orKey.text = v ?? '';
    });
    ai.getOpenRouterModel().then((v) {
      _orModel.text = v;
    });
    ai.getAzure().then((az) {
      _azKey.text = az.apiKey;
      _azEndpoint.text = az.endpoint;
      _azDeployment.text = az.deployment;
      _azVersion.text = az.apiVersion;
    });
  }

  @override
  void dispose() {
    _key.dispose();
    _orKey.dispose();
    _orModel.dispose();
    _azKey.dispose();
    _azEndpoint.dispose();
    _azDeployment.dispose();
    _azVersion.dispose();
    super.dispose();
  }

  Future<void> _testKey() async {
    final ai = AiService();
    final provider = _provider;
    // Persist whatever is on screen first so the probe uses it.
    if (provider == AiProviderKind.gemini && _key.text.trim().isNotEmpty) {
      await ai.saveApiKey(_key.text);
    } else if (provider == AiProviderKind.openrouter) {
      if (_orKey.text.trim().isNotEmpty) {
        await ai.saveOpenRouterKey(_orKey.text);
      }
      if (_orModel.text.trim().isNotEmpty) {
        await ai.saveOpenRouterModel(_orModel.text);
      }
    } else if (provider == AiProviderKind.azure) {
      await ai.saveAzure(
        endpoint: _azEndpoint.text,
        deployment: _azDeployment.text,
        apiVersion: _azVersion.text,
        apiKey: _azKey.text,
      );
    }
    if (provider == AiProviderKind.gemini && _key.text.trim().isEmpty ||
        provider == AiProviderKind.openrouter && _orKey.text.trim().isEmpty ||
        provider == AiProviderKind.azure && _azKey.text.trim().isEmpty) {
      setState(() => _testResult = 'Paste a key first.');
      return;
    }
    setState(() {
      _testing = true;
      _testResult = null;
    });
    try {
      final meta = await LinkParser.fetchMeta('https://www.youtube.com/watch?v=dQw4w9WgXcQ');
      final r = await ai.enrichWithFlag(
          url: 'https://www.youtube.com/watch?v=dQw4w9WgXcQ', meta: meta);
      setState(() {
        _testResult = r.usedAi
            ? '✓ ${provider.label} works — probe categorized as "${r.enrichment.category.name}" with summary.'
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
        // Reuse stored bodyText so retry sees the same platform content the
        // original save fetched (YouTube/Reddit/Instagram), plus user note.
        final r = await ai.enrichWithFlag(
          url: item.url,
          meta: meta,
          userNote: item.userNote,
          fetchedContent: item.bodyText,
        );
        if (r.usedAi) {
          fixed++;
          await _upsertEnriched(item.id, r.enrichment);
        }
      } catch (_) {}
    }
    ref.invalidate(itemsProvider);
    ref.invalidate(countsProvider);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(fixed == 0
              ? 'Nothing to retry (or AI still failing)'
              : 'Re-categorized $fixed item(s) with AI ✓')));
    }
  }

  Future<void> _upsertEnriched(String itemId, AiEnrichment e) async {
    final items = await ref.read(itemsProvider.future);
    final item = items.where((e) => e.id == itemId).firstOrNull;
    if (item == null) return;
    final container = ProviderScope.containerOf(context, listen: false);
    final db = container.read(dbProviderForRetry);
    await db.upsert(item.copyWith(
      category: e.category,
      summary: e.summary.isNotEmpty ? e.summary : item.summary,
      tags: e.tags,
      aiProcessed: true,
      aiTopic: e.topic.isNotEmpty ? e.topic : null,
      aiSubcategory: e.subcategory.isNotEmpty ? e.subcategory : null,
      aiKeyPoints: e.keyPoints,
      aiConfidence: e.confidence,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final rules = ref.watch(rulesProvider).maybeWhen(
          data: (v) => v,
          orElse: () => <TagRule>[],
        );
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text('Account & sync',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          const Card(
            child: Padding(
              padding: EdgeInsets.all(4),
              child: AccountTile(),
            ),
          ),
          const SizedBox(height: 8),
          const SyncNowButton(),
          const SizedBox(height: 8),
          const Text(
              'Sign in with Google to access saves on web + phone. '
              'AI keys stay on this device and never sync.'),
          const SizedBox(height: 24),
          const Text('AI provider',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          const Text(
              'Pick the backend. Keys stay on this device. Without a key for the active provider, the app uses offline rules.'),
          const SizedBox(height: 8),
          SegmentedButton<AiProviderKind>(
            showSelectedIcon: false,
            style: SegmentedButton.styleFrom(visualDensity: VisualDensity.compact),
            segments: AiProviderKind.values
                .map((p) => ButtonSegment(
                    value: p,
                    label: Text(p == AiProviderKind.gemini
                        ? 'Gemini'
                        : p == AiProviderKind.openrouter
                            ? 'OpenRouter'
                            : 'Azure')))
                .toList(),
            selected: {_provider},
            onSelectionChanged: (s) async {
              setState(() => _provider = s.first);
              await AiService().saveProvider(s.first);
            },
          ),
          const SizedBox(height: 16),
          if (_provider == AiProviderKind.gemini) ...[
            const Text('Google Gemini',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            const Text(
                'Paste a Gemini API key (free at aistudio.google.com → Get API key).\n\nIf items show "offline rules" even with a key, use Test key below.'),
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
              Card(child: Padding(padding: const EdgeInsets.all(12), child: Text(_testResult!))),
            ],
            const SizedBox(height: 16),
            const Text('Gemini model',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            const Text(
                'Picked first for every request; the others are automatic fallbacks. 3.6 is newest, lite is cheapest/fastest.'),
            const SizedBox(height: 8),
            DropdownButtonFormField<String>(
              initialValue: _model,
              decoration: const InputDecoration(
                  labelText: 'Preferred Gemini model',
                  border: OutlineInputBorder()),
              items: AiService.availableModels
                  .map((m) => DropdownMenuItem(value: m, child: Text(m)))
                  .toList(),
              onChanged: (v) async {
                if (v == null) return;
                setState(() => _model = v);
                await AiService().saveModel(v);
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('Model set to $v')));
                }
              },
            ),
          ],
          if (_provider == AiProviderKind.openrouter) ...[
            const Text('OpenRouter',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            const Text(
                'One key, 400+ models (openrouter.ai → Keys). You pick the model id yourself — e.g. google/gemini-2.5-flash, anthropic/claude-sonnet-5, deepseek/deepseek-chat. Billed by OpenRouter.'),
            const SizedBox(height: 12),
            TextField(
              controller: _orKey,
              obscureText: _orObscure,
              decoration: InputDecoration(
                labelText: 'OpenRouter API key (sk-or-…)',
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(
                  icon: Icon(_orObscure ? Icons.visibility : Icons.visibility_off),
                  onPressed: () => setState(() => _orObscure = !_orObscure),
                ),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _orModel,
              decoration: const InputDecoration(
                labelText: 'Model id',
                hintText: OpenRouterDefaults.model,
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: OpenRouterDefaults.suggestions
                  .take(4)
                  .map((m) => ActionChip(
                      label: Text(m.split('/').last,
                          style: const TextStyle(fontSize: 11)),
                      onPressed: () =>
                          setState(() => _orModel.text = m)))
                  .toList(),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton(
                  onPressed: () async {
                    final ai = AiService();
                    await ai.saveOpenRouterKey(_orKey.text);
                    await ai.saveOpenRouterModel(_orModel.text.isEmpty
                        ? OpenRouterDefaults.model
                        : _orModel.text);
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                              content: Text('OpenRouter saved')));
                    }
                  },
                  child: const Text('Save'),
                ),
                FilledButton.tonal(
                  onPressed: _testing ? null : _testKey,
                  child: _testing
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Text('Test key'),
                ),
              ],
            ),
            if (_testResult != null) ...[
              const SizedBox(height: 12),
              Card(
                  child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Text(_testResult!))),
            ],
          ],
          if (_provider == AiProviderKind.azure) ...[
            const Text('Azure OpenAI',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            const Text(
                'Your own Azure resource (portal.azure.com → Azure OpenAI → Keys + Deployments). The deployment name selects the model — configure it yourself in Azure, then paste here.'),
            const SizedBox(height: 12),
            TextField(
              controller: _azEndpoint,
              decoration: const InputDecoration(
                labelText: 'Endpoint',
                hintText: 'https://my-resource.openai.azure.com',
                border: OutlineInputBorder(),
              ),
              keyboardType: TextInputType.url,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _azDeployment,
              decoration: const InputDecoration(
                labelText: 'Deployment name (your model)',
                hintText: 'e.g. gpt-4o-mini',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _azVersion,
              decoration: const InputDecoration(
                labelText: 'API version',
                hintText: '2024-10-21',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _azKey,
              obscureText: _azObscure,
              decoration: InputDecoration(
                labelText: 'Azure API key',
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(
                  icon: Icon(
                      _azObscure ? Icons.visibility : Icons.visibility_off),
                  onPressed: () =>
                      setState(() => _azObscure = !_azObscure),
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
                    await AiService().saveAzure(
                      endpoint: _azEndpoint.text,
                      deployment: _azDeployment.text,
                      apiVersion: _azVersion.text,
                      apiKey: _azKey.text,
                    );
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                              content: Text('Azure saved')));
                    }
                  },
                  child: const Text('Save'),
                ),
                FilledButton.tonal(
                  onPressed: _testing ? null : _testKey,
                  child: _testing
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Text('Test key'),
                ),
              ],
            ),
            if (_testResult != null) ...[
              const SizedBox(height: 12),
              Card(
                  child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Text(_testResult!))),
            ],
          ],
          const SizedBox(height: 16),
          const Text('Content sources',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          const Card(
            child: Padding(
              padding: EdgeInsets.all(12),
              child: Text(
                  'Before AI tags an item, the app now pulls real content:\n'
                  '• YouTube — title, channel, description, keywords\n'
                  '• Reddit — post text + top 5 comments (PullPush API)\n'
                  '• Instagram — caption via embed page\n'
                  'Tags are based on this content, not just the title. '
                  'No setup needed — it runs automatically at save time. '
                  'Instagram often blocks anonymous access, so captions may be missing there.'),
            ),
          ),
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
          const SizedBox(height: 24),
          Row(
            children: [
              const Text('Auto-tag rules',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.add),
                tooltip: 'New rule',
                onPressed: () => _ruleDialog(context, ref, null),
              ),
            ],
          ),
          const Text(
              'Rules run before AI at save time. First matching rule wins — e.g. match "lexfridman" → Learn + podcast.'),
          const SizedBox(height: 8),
          if (rules.isEmpty)
            const Card(
                child: Padding(
                    padding: EdgeInsets.all(12),
                    child: Text('No rules yet. Add one for your favorite channels or sites.')))
          else
            ...rules.map((r) => Card(
                  child: ListTile(
                    leading: Icon(r.enabled
                        ? Icons.rule_outlined
                        : Icons.rule_folder_outlined),
                    title: Text('"${r.match}"'),
                    subtitle: Text(
                        '${r.category != null ? '→ ${r.category!.label}' : 'no category change'}${r.tags.isNotEmpty ? ' + ${r.tags.map((t) => '#$t').join(' ')}' : ''}'),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Switch(
                          value: r.enabled,
                          onChanged: (v) async {
                            await ref.read(dbProviderForRetry).upsertRule(TagRule(
                                id: r.id,
                                match: r.match,
                                category: r.category,
                                tags: r.tags,
                                enabled: v));
                            ref.invalidate(rulesProvider);
                          },
                        ),
                        IconButton(
                          icon: const Icon(Icons.edit_outlined, size: 18),
                          onPressed: () => _ruleDialog(context, ref, r),
                        ),
                        IconButton(
                          icon: const Icon(Icons.delete_outline,
                              size: 18, color: Colors.red),
                          onPressed: () async {
                            await ref.read(dbProviderForRetry).deleteRule(r.id);
                            ref.invalidate(rulesProvider);
                          },
                        ),
                      ],
                    ),
                  ),
                )),
        ],
      ),
    );
  }

  Future<void> _ruleDialog(BuildContext context, WidgetRef ref, TagRule? existing) async {
    final match = TextEditingController(text: existing?.match ?? '');
    final tags = TextEditingController(text: existing?.tags.join(', ') ?? '');
    Category? category = existing?.category;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          title: Text(existing == null ? 'New rule' : 'Edit rule'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                  controller: match,
                  autofocus: true,
                  decoration: const InputDecoration(
                      labelText: 'URL contains…',
                      hintText: 'e.g. lexfridman or nytimes.com',
                      border: OutlineInputBorder())),
              const SizedBox(height: 12),
              DropdownButtonFormField<Category?>(
                initialValue: category,
                decoration: const InputDecoration(
                    labelText: 'Force category (optional)',
                    border: OutlineInputBorder()),
                items: [
                  const DropdownMenuItem(value: null, child: Text('— AI decides —')),
                  ...Category.values.map((c) =>
                      DropdownMenuItem(value: c, child: Text(c.label))),
                ],
                onChanged: (v) => setState(() => category = v),
              ),
              const SizedBox(height: 12),
              TextField(
                  controller: tags,
                  decoration: const InputDecoration(
                      labelText: 'Extra tags (comma separated)',
                      hintText: 'e.g. podcast, longform',
                      border: OutlineInputBorder())),
            ],
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel')),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Save')),
          ],
        ),
      ),
    );
    if (ok == true && match.text.trim().isNotEmpty) {
      await ref.read(dbProviderForRetry).upsertRule(TagRule(
            id: existing?.id ?? const Uuid().v4(),
            match: match.text.trim(),
            category: category,
            tags: tags.text
                .split(',')
                .map((t) => t.trim().toLowerCase())
                .where((t) => t.isNotEmpty)
                .take(3)
                .toList(),
            enabled: existing?.enabled ?? true,
          ));
      ref.invalidate(rulesProvider);
    }
  }
}

extension<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
