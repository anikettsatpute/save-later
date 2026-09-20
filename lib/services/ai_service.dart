import 'dart:convert';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../models/saved_item.dart';
import 'ai_providers.dart';
import 'content_fetcher.dart';
import 'link_parser.dart';

/// AI enrichment result: category + summary + tags.
class AiEnrichment {
  final Category category;
  final String summary;
  final List<String> tags;
  final String? error; // surfaced in UI when Gemini fails (no silent fallback)

  const AiEnrichment({required this.category, required this.summary, required this.tags, this.error});
}

/// Rules fallback so the app works with no key / offline.
/// Cloud path uses Gemini `generateContent` with rich context (site, author,
/// subreddit, score, excerpt, body). Failures return error text instead of
/// silently falling back, so users know the key/quota is the problem.
class AiService {
  static const _keyName = 'gemini_api_key';
  static const _modelName = 'gemini_model';
  // Provider selection + per-provider credentials (user configures).
  static const _providerName = 'ai_provider';
  static const _orKeyName = 'openrouter_api_key';
  static const _orModelName = 'openrouter_model';
  static const _azKeyName = 'azure_api_key';
  static const _azEndpointName = 'azure_endpoint';
  static const _azDeploymentName = 'azure_deployment';
  static const _azVersionName = 'azure_api_version';
  final FlutterSecureStorage _storage = const FlutterSecureStorage();

  /// User's preferred Gemini model, newest-first. Persisted per device.
  static const availableModels = [
    'gemini-3.6-flash',
    'gemini-2.5-flash',
    'gemini-2.5-flash-lite',
  ];

  Future<void> saveApiKey(String key) => _write(_keyName, key.trim());
  Future<String?> getApiKey() => _read(_keyName);
  Future<void> clearApiKey() => _delete(_keyName);

  Future<void> saveModel(String model) => _write(_modelName, model);
  Future<String> getModel() async {
    final m = await _read(_modelName);
    return availableModels.contains(m) ? m! : availableModels.first;
  }

  // ---- provider selection ----
  Future<AiProviderKind> getProvider() async =>
      AiProviderKindLabel.fromStorage(await _read(_providerName));
  Future<void> saveProvider(AiProviderKind p) => _write(_providerName, p.name);

  // ---- OpenRouter ----
  Future<void> saveOpenRouterKey(String k) => _write(_orKeyName, k.trim());
  Future<String?> getOpenRouterKey() => _read(_orKeyName);
  Future<void> saveOpenRouterModel(String m) => _write(_orModelName, m.trim());
  Future<String> getOpenRouterModel() async =>
      (await _read(_orModelName))?.trim().isNotEmpty == true
          ? (await _read(_orModelName))!.trim()
          : OpenRouterDefaults.model;

  // ---- Azure ----
  Future<void> saveAzure({
    required String endpoint,
    required String deployment,
    required String apiVersion,
    required String apiKey,
  }) async {
    await _write(_azEndpointName, endpoint.trim());
    await _write(_azDeploymentName, deployment.trim());
    await _write(_azVersionName, apiVersion.trim().isEmpty ? '2024-10-21' : apiVersion.trim());
    await _write(_azKeyName, apiKey.trim());
  }

  Future<AzureConfig> getAzure() async => AzureConfig(
        endpoint: (await _read(_azEndpointName)) ?? '',
        deployment: (await _read(_azDeploymentName)) ?? '',
        apiVersion: (await _read(_azVersionName)) ?? '2024-10-21',
        apiKey: (await _read(_azKeyName)) ?? '',
      );

  // flutter_secure_storage has no web implementation in this build (it
  // pulls platform channels the sandbox blocks). Web preview keeps the key
  // in shared_preferences (localStorage); mobile keeps secure storage.
  Future<void> _write(String k, String v) async {
    if (kIsWeb) {
      (await SharedPreferences.getInstance()).setString(k, v);
    } else {
      await _storage.write(key: k, value: v);
    }
  }

  Future<String?> _read(String k) async {
    if (kIsWeb) {
      return (await SharedPreferences.getInstance()).getString(k);
    }
    return _storage.read(key: k);
  }

  Future<void> _delete(String k) async {
    if (kIsWeb) {
      (await SharedPreferences.getInstance()).remove(k);
    } else {
      await _storage.delete(key: k);
    }
  }

  /// Returns (enrichment, usedAi). `usedAi` false means rules fallback.
  Future<({AiEnrichment enrichment, bool usedAi})> enrichWithFlag({
    required String url,
    required LinkMeta meta,
  }) async {
    final provider = await getProvider();
    final hasCreds = switch (provider) {
      AiProviderKind.gemini => (await getApiKey())?.isNotEmpty == true,
      AiProviderKind.openrouter => (await getOpenRouterKey())?.isNotEmpty == true,
      AiProviderKind.azure => (await getAzure()).isComplete,
    };
    if (!hasCreds) {
      return (enrichment: _rules(url, meta), usedAi: false);
    }
    try {
      final e = await _enrichVia(provider, url, meta);
      return (enrichment: e, usedAi: true);
    } catch (e) {
      final fallback = _rules(url, meta);
      return (
        enrichment: AiEnrichment(
          category: fallback.category,
          summary: fallback.summary,
          tags: fallback.tags,
          error: _friendlyError(e),
        ),
        usedAi: false,
      );
    }
  }

  Future<AiEnrichment> enrich({required String url, required LinkMeta meta}) async {
    final r = await enrichWithFlag(url: url, meta: meta);
    return r.enrichment;
  }

  String _friendlyError(Object e) {
    final s = e.toString();
    if (s.contains('400')) return 'AI rejected the request (key or model?). Check Settings.';
    if (s.contains('401') || s.contains('403')) return 'AI key invalid or expired. Check Settings.';
    if (s.contains('429')) return 'AI quota exceeded. Try again later.';
    if (s.contains('Timeout') || s.contains('Socket')) return 'Network timeout reaching AI. Saved with offline tags.';
    return 'AI unavailable ($s). Saved with offline tags.';
  }

  AiEnrichment _rules(String url, LinkMeta meta) {
    final type = meta.type;
    final category = switch (type) {
      ItemType.youtube || ItemType.tiktok || ItemType.instagram => Category.watch,
      ItemType.reddit || ItemType.x => Category.read,
      ItemType.movie => Category.moviesShows,
      _ => _guessFromText('${meta.title} ${meta.description ?? ''} ${meta.siteName ?? ''}'),
    };
    // Never leave the summary empty: fall back to a human sentence built
    // from whatever the parser did get (fixes "Saved link" cards).
    var summary = (meta.excerpt ?? meta.description ?? '').trim();
    if (summary.isEmpty) {
      summary = _describeFromMeta(url, meta);
    }
    final tags = <String>{type.name};
    if (meta.subreddit != null) tags.add('r/${meta.subreddit}');
    if (meta.siteName != null && meta.siteName!.isNotEmpty) {
      tags.add(meta.siteName!.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), ''));
    }
    return AiEnrichment(
      category: category,
      summary: summary.length > 220 ? '${summary.substring(0, 220)}…' : summary,
      tags: tags.take(3).toList(),
    );
  }

  /// Human fallback when the parser found no excerpt/description at all
  /// (YouTube oEmbed fail, Google Feed redirect, JS-heavy pages).
  /// Topic-first: never "Open to watch" filler — the AI prompt now forbids
  /// that, and this offline path matches.
  String _describeFromMeta(String url, LinkMeta meta) {
    final host = Uri.tryParse(url)?.host.replaceFirst('www.', '') ?? '';
    final who = meta.author?.isNotEmpty == true ? ' by ${meta.author}' : '';
    return switch (meta.type) {
      ItemType.youtube => '“${meta.title}”$who.',
      ItemType.reddit => '“${meta.title}”${meta.subreddit != null ? ' (r/${meta.subreddit})' : ''}.',
      ItemType.instagram => 'Instagram post$who: “${meta.title}”.',
      ItemType.tiktok => 'TikTok$who: “${meta.title}”.',
      ItemType.movie => '“${meta.title}” ($host).',
      _ => host.isNotEmpty ? '“${meta.title}” ($host).' : '“${meta.title}”.',
    };
  }

  Category _guessFromText(String text) {
    final t = text.toLowerCase();
    if (RegExp(r'\b(recipe|buy|price|deal|discount|coupon|sale)\b').hasMatch(t)) return Category.shopping;
    if (RegExp(r'\b(tutorial|learn|course|guide|how to|explained|documentation|docs)\b').hasMatch(t)) return Category.learn;
    if (RegExp(r'\b(podcast|song|album|music|audio|episode|playlist)\b').hasMatch(t)) return Category.listen;
    if (RegExp(r'\b(movie|film|series|show|episode|trailer|imdb|netflix)\b').hasMatch(t)) return Category.moviesShows;
    if (RegExp(r'\b(idea|startup|thought|essay|opinion|thread|discussion)\b').hasMatch(t)) return Category.ideas;
    if (RegExp(r'\b(video|watch|vlog|documentary|livestream)\b').hasMatch(t)) return Category.watch;
    return Category.read;
  }

  Future<AiEnrichment> _enrichVia(
      AiProviderKind provider, String url, LinkMeta meta) async {
    final prompt = await _categorizePrompt(url, meta);
    final raw = await _complete(prompt, maxTokens: 400, temperature: 0.2);
    return _parseEnrichment(raw, url, meta);
  }

  /// Single completion through the active provider. Gemini tries the
  /// preferred model then fallbacks; OpenRouter/Azure use the user's config.
  Future<String> _complete(String prompt,
      {int maxTokens = 400, double temperature = 0.2}) async {
    final provider = await getProvider();
    switch (provider) {
      case AiProviderKind.openrouter:
        final key = (await getOpenRouterKey()) ?? '';
        final model = await getOpenRouterModel();
        return ProviderClients.openRouter(
            apiKey: key,
            model: model,
            prompt: prompt,
            maxTokens: maxTokens,
            temperature: temperature);
      case AiProviderKind.azure:
        final az = await getAzure();
        return ProviderClients.azure(
            config: az,
            prompt: prompt,
            maxTokens: maxTokens,
            temperature: temperature);
      case AiProviderKind.gemini:
        final key = (await getApiKey()) ?? '';
        // Preferred model first, then the rest as fallbacks.
        // gemini-2.0-flash is SHUT DOWN (verified 2026-09-20).
        final preferred = await getModel();
        final models = [
          preferred,
          ...availableModels.where((m) => m != preferred)
        ];
        Object? lastErr;
        for (final model in models) {
          try {
            return await ProviderClients.gemini(
                apiKey: key,
                model: model,
                prompt: prompt,
                maxTokens: maxTokens,
                temperature: temperature);
          } catch (e) {
            lastErr = e;
            if (e.toString().contains('400') ||
                e.toString().contains('401') ||
                e.toString().contains('403')) rethrow;
          }
        }
        throw lastErr ?? Exception('Gemini request failed');
    }
  }

  Future<String> _categorizePrompt(String url, LinkMeta meta) async {
    const categories = 'Watch, Read, Listen, Movies & Shows, Learn, Ideas, Shopping, Other';
    final context = StringBuffer()
      ..writeln('URL: $url')
      ..writeln('Title: ${meta.title}')
      ..writeln('Site: ${meta.siteName ?? 'unknown'}')
      ..writeln('Author: ${meta.author ?? 'unknown'}')
      ..writeln('Detected type: ${meta.type.name}');
    if (meta.subreddit != null) {
      context.writeln('Subreddit: r/${meta.subreddit} (score ${meta.redditScore ?? '?'}, comments ${meta.redditComments ?? '?'})');
    }
    if (meta.readingMinutes != null) context.writeln('Reading time: ~${meta.readingMinutes} min');
    if (meta.excerpt?.isNotEmpty == true) context.writeln('Excerpt: ${meta.excerpt}');
    if (meta.articleText?.isNotEmpty == true) {
      context.writeln('Article start: ${meta.articleText!.substring(0, meta.articleText!.length.clamp(0, 1500))}');
    } else if (meta.description?.isNotEmpty == true) {
      context.writeln('Description: ${meta.description!.substring(0, meta.description!.length.clamp(0, 800))}');
    }
    // Content fetchers (YouTube/Reddit/Instagram): real post text so tags
    // come from CONTENT, not just the title. Best-effort, skipped on failure.
    try {
      final content = await ContentFetcher.fetchFor(url, meta.type.name);
      if (content?.isNotEmpty == true) {
        context.writeln('Page content: ${content!.substring(0, content.length.clamp(0, 3000))}');
      }
    } catch (_) {}
    final prompt = '''
You categorize saved links for a read-it-later app. Reply with ONLY valid JSON, no markdown fences:
{"category": "<one of: $categories>", "summary": "<1-2 line plain-language summary of what this is ABOUT (its topic/content — never describe the act of saving or opening the link)>", "tags": ["<up to 3 lowercase topic tags>"]}

Rules: YouTube/music videos -> Watch. Podcasts/audio -> Listen. Movies/series/IMDb -> Movies & Shows. Tutorials/docs/courses -> Learn. Products/deals -> Shopping. Reddit threads/discussions/opinion -> Ideas or Read based on content. News/articles/blogs -> Read. Default Other only if nothing fits.

Summary rules: describe WHAT the content is about using Title + Page content. NEVER write "Open to watch", "Saved link", "YouTube video by X" or any meta-commentary about saving/opening — the user already knows they saved it. If content is thin, infer the topic from the title (e.g. a video titled "X" is about X).

Tags: content topics (technologies, people, subjects named in Page content) — never "youtube", "video", "reddit", "post", "watch", "saved".

Base tags on the Page content when present (topics, people, tech named there) — not just the title.

${context}''';
    return prompt;
  }

  /// Parses the model's raw text into an enrichment (shared by all providers).
  AiEnrichment _parseEnrichment(String raw, String url, LinkMeta meta) {
    var text = raw.trim();
    if (text.isEmpty) throw Exception('AI returned empty response');
    // Strip accidental markdown fences.
    if (text.startsWith('```')) {
      text = text.replaceFirst(RegExp(r'^```[a-zA-Z]*\n?'), '').replaceAll(RegExp(r'\n?```\s*$'), '');
      text = text.trim();
    }
    // Gemini 3.x often wraps JSON in prose ("Here is the categorization: {...}").
    // Extract the largest {...} block; if braces are unbalanced (truncated),
    // repair by closing them before parsing.
    final extracted = _extractJsonObject(text);
    if (extracted == null) {
      // Last resort: derive a usable enrichment from the raw text instead of
      // failing the whole save.
      return AiEnrichment(
        category: _guessFromText('$url-fallback $text'),
        summary: _cleanProse(text, url, meta),
        tags: const [],
      );
    }
    Map<String, dynamic> parsed;
    try {
      parsed = jsonDecode(extracted) as Map<String, dynamic>;
    } catch (_) {
      return AiEnrichment(
        category: Category.read,
        summary: _cleanProse(text, url, meta),
        tags: const [],
      );
    }
    // Guard: model echoed keys but left values empty, or returned the schema
    // itself (summary literally "..." or containing "category:"). Fall back to
    // cleaned prose instead of storing raw JSON in the summary field.
    var summary = ((parsed['summary'] as String?) ?? '').trim();
    if (summary.isEmpty ||
        summary == '...' ||
        RegExp(r'^\{.*"category"').hasMatch(summary) ||
        summary.contains('"summary"')) {
      summary = _cleanProse(text, url, meta);
    }
    return AiEnrichment(
      category: _parseCategory(parsed['category'] as String?),
      summary: summary,
      tags: ((parsed['tags'] as List?) ?? []).map((e) => e.toString().toLowerCase()).take(3).toList(),
    );
  }

  /// Finds the first balanced {...} block in [text]. If the block is cut off
  /// (unbalanced open braces from truncation), appends the missing closers.
  /// Returns null when no '{' exists at all.
  String? _extractJsonObject(String text) {
    final start = text.indexOf('{');
    if (start < 0) return null;
    var depth = 0;
    var inString = false;
    var escape = false;
    for (var i = start; i < text.length; i++) {
      final ch = text[i];
      if (inString) {
        if (escape) {
          escape = false;
        } else if (ch == '\\') {
          escape = true;
        } else if (ch == '"') {
          inString = false;
        }
        continue;
      }
      if (ch == '"') {
        inString = true;
      } else if (ch == '{') {
        depth++;
      } else if (ch == '}') {
        depth--;
        if (depth == 0) return text.substring(start, i + 1);
      }
    }
    // Unbalanced: repair by closing all open braces (truncation case).
    if (depth > 0) {
      return '${text.substring(start)}${'}' * depth}';
    }
    return null;
  }

  /// Strips JSON scaffolding from prose so the summary field never shows raw
  /// `{"category": ...}` text to the user.
  String _cleanProse(String text, String url, LinkMeta? meta) {
    var t = text.trim();
    // Remove a leading prose intro up to the JSON block.
    final js = t.indexOf('{');
    if (js > 0) t = t.substring(0, js).trim();
    // Remove leftover JSON-ish fragments.
    t = t.replaceAll(RegExp(r'```[a-zA-Z]*'), '').replaceAll('```', '');
    t = t.replaceAll(RegExp(r'\{"category".*$', dotAll: true), '').trim();
    t = t.replaceAll(RegExp(r'\s+'), ' ').trim();
    // Never return the bare placeholder: callers pass url/meta context so
    // we can at least describe the link (fixes "Saved link" summaries).
    if (t.isEmpty || t == 'Saved link') {
      if (meta != null) return _describeFromMeta(url, meta);
      return 'Saved link — $url';
    }
    return t.length > 220 ? '${t.substring(0, 220)}…' : t;
  }

  Category _parseCategory(String? raw) {
    final t = (raw ?? '').toLowerCase();
    if (t.contains('movie') || t.contains('show')) return Category.moviesShows;
    if (t.contains('watch')) return Category.watch;
    if (t.contains('listen')) return Category.listen;
    if (t.contains('learn')) return Category.learn;
    if (t.contains('idea')) return Category.ideas;
    if (t.contains('shop')) return Category.shopping;
    if (t.contains('read')) return Category.read;
    return Category.other;
  }

  // ------------------------------------------------------------ ask AI chat
  /// Builds the shared item context block used for Q&A. Highlights and the
  /// user's own note are included — Obsidian-style: your words anchor the AI.
  String itemContext(SavedItem item, {List<Highlight> highlights = const []}) {
    final b = StringBuffer()
      ..writeln('URL: ${item.url}')
      ..writeln('Title: ${item.title}')
      ..writeln('Site: ${item.siteName ?? 'unknown'}')
      ..writeln('Author: ${item.author ?? 'unknown'}')
      ..writeln('Type: ${item.type.name}, Category: ${item.category.label}');
    if (item.subreddit != null) {
      b.writeln(
          'Subreddit: r/${item.subreddit} (score ${item.redditScore ?? '?'}, comments ${item.redditComments ?? '?'})');
    }
    if (item.readingMinutes != null) b.writeln('Reading time: ~${item.readingMinutes} min');
    if (item.summary?.isNotEmpty == true) b.writeln('Summary: ${item.summary}');
    if (item.excerpt?.isNotEmpty == true && item.excerpt != item.summary) {
      b.writeln('Page excerpt: ${item.excerpt}');
    }
    if (item.userNote?.isNotEmpty == true) {
      b.writeln('MY NOTE (pay special attention, this is what I care about): ${item.userNote}');
    }
    if (highlights.isNotEmpty) {
      b.writeln('MY HIGHLIGHTS:');
      for (final h in highlights.take(10)) {
        b.writeln('- "${h.text}"${h.note?.isNotEmpty == true ? ' [my note: ${h.note}]' : ''}');
      }
    }
    return b.toString();
  }

  /// Ask a question about a saved item. Returns the answer text or throws
  /// with a friendly message. History is (question, answer) pairs.
  /// Routes through the active provider (Gemini native, others OpenAI-chat).
  Future<String> askAboutItem({
    required SavedItem item,
    required String question,
    List<({String q, String a})> history = const [],
    String? articleText,
    List<Highlight> highlights = const [],
  }) async {
    final provider = await getProvider();
    final hasCreds = switch (provider) {
      AiProviderKind.gemini => (await getApiKey())?.isNotEmpty == true,
      AiProviderKind.openrouter => (await getOpenRouterKey())?.isNotEmpty == true,
      AiProviderKind.azure => (await getAzure()).isComplete,
    };
    if (!hasCreds) {
      throw Exception('No AI key for ${provider.label}. Add one in Settings first.');
    }
    // Prefer the stored full body (saved at capture) over a live refetch.
    final body = articleText?.isNotEmpty == true
        ? articleText
        : item.bodyText?.isNotEmpty == true
            ? item.bodyText
            : null;
    final context = StringBuffer(itemContext(item, highlights: highlights));
    if (body?.isNotEmpty == true) {
      context.writeln(
          'Article content (may be truncated): ${body!.substring(0, body!.length.clamp(0, 6000))}');
    }
    const system =
        'You are a helpful reading companion inside a read-it-later app. Answer questions about the saved item below using its context. If the context lacks the answer, say what you can infer and what is missing. Keep answers concise.';
    if (provider == AiProviderKind.gemini) {
      return _askGemini(system, context.toString(), question, history);
    }
    final messages = <Map<String, dynamic>>[
      {'role': 'system', 'content': '$system\n\n$context'},
    ];
    for (final h in history.take(6)) {
      messages.add({'role': 'user', 'content': h.q});
      messages.add({'role': 'assistant', 'content': h.a});
    }
    messages.add({'role': 'user', 'content': question});
    try {
      if (provider == AiProviderKind.openrouter) {
        return await ProviderClients.chatOpenAiCompatible(
          url: Uri.parse('https://openrouter.ai/api/v1/chat/completions'),
          headers: {
            'Authorization': 'Bearer ${(await getOpenRouterKey()) ?? ''}',
            'HTTP-Referer':
                'https://github.com/anikettsatpute/save-later',
            'X-Title': 'Save Later',
          },
          messages: messages,
        );
      } else {
        final az = await getAzure();
        final base = az.endpoint.endsWith('/')
            ? az.endpoint.substring(0, az.endpoint.length - 1)
            : az.endpoint;
        return await ProviderClients.chatOpenAiCompatible(
          url: Uri.parse(
              '$base/openai/deployments/${az.deployment}/chat/completions?api-version=${az.apiVersion}'),
          headers: {'api-key': az.apiKey},
          messages: messages,
        );
      }
    } catch (e) {
      throw Exception(_friendlyError(e));
    }
  }

  /// Gemini-native multi-turn chat (existing behavior, preferred-model first).
  Future<String> _askGemini(
    String system,
    String context,
    String question,
    List<({String q, String a})> history,
  ) async {
    final key = (await getApiKey()) ?? '';
    final contents = <Map<String, dynamic>>[
      {
        'role': 'user',
        'parts': [
          {'text': '$system\n\n$context'}
        ]
      },
    ];
    for (final h in history.take(6)) {
      contents.add({
        'role': 'user',
        'parts': [
          {'text': h.q}
        ]
      });
      contents.add({
        'role': 'model',
        'parts': [
          {'text': h.a}
        ]
      });
    }
    contents.add({
      'role': 'user',
      'parts': [
        {'text': question}
      ]
    });

    final preferred = await getModel();
    final models = [preferred, ...availableModels.where((m) => m != preferred)];
    Object? lastErr;
    for (final model in models) {
      try {
        final res = await http
            .post(
              Uri.parse(
                  'https://generativelanguage.googleapis.com/v1beta/models/$model:generateContent?key=$key'),
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode({
                'contents': contents,
                'generationConfig': {'temperature': 0.4, 'maxOutputTokens': 800},
              }),
            )
            .timeout(const Duration(seconds: 30));
        if (res.statusCode != 200) {
          String detail = '';
          try {
            final err = jsonDecode(res.body) as Map<String, dynamic>;
            detail = ': ${(err['error'] as Map?)?['message'] ?? res.body}'.toString().substring(0, 200);
          } catch (_) {}
          final ex = Exception('Gemini ${res.statusCode}$detail');
          if (res.statusCode == 400 || res.statusCode == 401 || res.statusCode == 403) {
            throw Exception(_friendlyError(ex));
          }
          lastErr = ex;
          continue;
        }
        final body = jsonDecode(res.body) as Map<String, dynamic>;
        final candidates = body['candidates'] as List?;
        if (candidates == null || candidates.isEmpty) throw Exception('Gemini returned no answer');
        final parts = (candidates.first['content']?['parts'] as List?);
        if (parts == null || parts.isEmpty) throw Exception('Gemini returned an empty answer');
        return (parts.first['text'] as String? ?? '').trim();
      } catch (e) {
        lastErr = e;
      }
    }
    throw Exception(_friendlyError(lastErr ?? Exception('request failed')));
  }
}
