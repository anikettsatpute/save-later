/// AI provider abstraction: Gemini (direct) vs OpenRouter vs Azure OpenAI.
///
/// All three speak an OpenAI-compatible chat-completions shape except Gemini,
/// which uses generateContent. The app builds one system+user prompt and each
/// provider translates + calls + returns raw text. JSON parsing stays in
/// AiService (unchanged).
library;

import 'dart:convert';

import 'package:http/http.dart' as http;

/// Which backend to call. Stored as string in prefs ('gemini' default).
enum AiProviderKind { gemini, openrouter, azure }

extension AiProviderKindLabel on AiProviderKind {
  String get label => switch (this) {
        AiProviderKind.gemini => 'Google Gemini',
        AiProviderKind.openrouter => 'OpenRouter',
        AiProviderKind.azure => 'Azure OpenAI',
      };
  String get storage => name;
  static AiProviderKind fromStorage(String? s) =>
      AiProviderKind.values.where((v) => v.name == s).firstOrNull ??
      AiProviderKind.gemini;
}

/// User-tunable OpenRouter model id (free text — user configures himself).
/// Defaults cover cheap + capable picks (verified 2026-09-20 via /models).
class OpenRouterDefaults {
  static const model = 'google/gemini-2.5-flash';
  static const suggestions = [
    'google/gemini-2.5-flash',
    'google/gemini-2.5-flash-lite',
    'anthropic/claude-sonnet-5',
    'openai/gpt-5.6-luna-pro',
    'meta-llama/llama-3.3-70b-instruct',
    'deepseek/deepseek-chat',
  ];
}

/// Azure OpenAI connection: endpoint + api-version + deployment name.
/// The deployment name IS the model selector on Azure (user configures).
class AzureConfig {
  final String endpoint; // https://<resource>.openai.azure.com
  final String deployment; // deployment name
  final String apiVersion; // e.g. 2024-10-21
  final String apiKey;
  const AzureConfig({
    required this.endpoint,
    required this.deployment,
    required this.apiVersion,
    required this.apiKey,
  });
  bool get isComplete =>
      endpoint.isNotEmpty && deployment.isNotEmpty && apiKey.isNotEmpty;
}

/// Thin HTTP clients. Each returns the assistant's raw text or throws.
class ProviderClients {
  /// Gemini generateContent (existing behavior).
  /// NOTE: thinking is disabled (thinkingBudget 0) — gemini-3 models spend
  /// ~600 hidden thought tokens per call, which starves maxOutputTokens and
  /// returns truncated prose instead of JSON (verified 2026-09-27).
  /// responseMimeType=json is NOT set — it burns the whole budget on the
  /// thoughtSignature and returns MAX_TOKENS with empty content.
  static Future<String> gemini({
    required String apiKey,
    required String model,
    required String prompt,
    int maxTokens = 600,
    double temperature = 0.2,
  }) async {
    final res = await http
        .post(
          Uri.parse(
              'https://generativelanguage.googleapis.com/v1beta/models/$model:generateContent?key=$apiKey'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'contents': [
              {
                'parts': [
                  {'text': prompt}
                ]
              }
            ],
            'generationConfig': {
              'temperature': temperature,
              'maxOutputTokens': maxTokens,
              'thinkingConfig': {'thinkingBudget': 0},
            },
          }),
        )
        .timeout(const Duration(seconds: 25));
    if (res.statusCode != 200) {
      throw _httpErr('Gemini', res);
    }
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    final candidates = body['candidates'] as List?;
    if (candidates == null || candidates.isEmpty) {
      throw Exception(
          'Gemini blocked the request (${body['promptFeedback'] ?? 'no reason'})');
    }
    // gemini-3 puts the answer in parts WITHOUT thoughtSignature; thought
    // parts carry the signature. Old code read parts.first, which is the
    // thought — take the first part with real text and no signature.
    final parts = (candidates.first['content']?['parts'] as List?);
    if (parts == null || parts.isEmpty) {
      throw Exception(
          'Gemini returned no text (finish: ${candidates.first['finishReason'] ?? 'unknown'})');
    }
    String text = '';
    for (final p in parts) {
      final m = p as Map<String, dynamic>?;
      final t = (m?['text'] as String? ?? '').trim();
      if (t.isEmpty) continue;
      if (m?.containsKey('thoughtSignature') == true && text.isEmpty) {
        // Thought part that happens to contain text — keep as fallback
        // only; prefer a clean non-thought part below.
        text = t;
        continue;
      }
      text = t;
      break;
    }
    text = text.trim();
    if (text.isEmpty) throw Exception('Gemini returned empty response');
    return text;
  }

  /// OpenRouter chat completions (OpenAI-compatible). Model is user-picked.
  static Future<String> openRouter({
    required String apiKey,
    required String model,
    required String prompt,
    int maxTokens = 400,
    double temperature = 0.2,
  }) async {
    final res = await http
        .post(
          Uri.parse('https://openrouter.ai/api/v1/chat/completions'),
          headers: {
            'Content-Type': 'application/json',
            'Authorization': 'Bearer $apiKey',
            'HTTP-Referer': 'https://github.com/anikettsatpute/save-later',
            'X-Title': 'Save Later',
          },
          body: jsonEncode({
            'model': model,
            'messages': [
              {'role': 'user', 'content': prompt},
            ],
            'temperature': temperature,
            'max_tokens': maxTokens,
          }),
        )
        .timeout(const Duration(seconds: 30));
    if (res.statusCode != 200) {
      throw _httpErr('OpenRouter', res);
    }
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    final choices = body['choices'] as List?;
    final text =
        (choices?.firstOrNull?['message']?['content'] as String? ?? '')
            .trim();
    if (text.isEmpty) throw Exception('OpenRouter returned empty response');
    return text;
  }

  /// Azure OpenAI chat completions on the user's deployment.
  static Future<String> azure({
    required AzureConfig config,
    required String prompt,
    int maxTokens = 400,
    double temperature = 0.2,
  }) async {
    final base = config.endpoint.endsWith('/')
        ? config.endpoint.substring(0, config.endpoint.length - 1)
        : config.endpoint;
    final res = await http
        .post(
          Uri.parse(
              '$base/openai/deployments/${config.deployment}/chat/completions?api-version=${config.apiVersion}'),
          headers: {
            'Content-Type': 'application/json',
            'api-key': config.apiKey,
          },
          body: jsonEncode({
            'messages': [
              {'role': 'user', 'content': prompt},
            ],
            'temperature': temperature,
            'max_tokens': maxTokens,
          }),
        )
        .timeout(const Duration(seconds: 30));
    if (res.statusCode != 200) {
      throw _httpErr('Azure', res);
    }
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    final choices = body['choices'] as List?;
    final text =
        (choices?.firstOrNull?['message']?['content'] as String? ?? '')
            .trim();
    if (text.isEmpty) throw Exception('Azure returned empty response');
    return text;
  }

  /// Azure/OpenRouter/OpenAI-style chat for Ask-AI (multi-turn messages).
  static Future<String> chatOpenAiCompatible({
    required Uri url,
    required Map<String, String> headers,
    required List<Map<String, dynamic>> messages,
    int maxTokens = 800,
    double temperature = 0.4,
  }) async {
    final res = await http
        .post(
          url,
          headers: {'Content-Type': 'application/json', ...headers},
          body: jsonEncode({
            'messages': messages,
            'temperature': temperature,
            'max_tokens': maxTokens,
          }),
        )
        .timeout(const Duration(seconds: 30));
    if (res.statusCode != 200) {
      throw _httpErr('AI', res);
    }
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    final choices = body['choices'] as List?;
    final text =
        (choices?.firstOrNull?['message']?['content'] as String? ?? '')
            .trim();
    if (text.isEmpty) throw Exception('AI returned empty response');
    return text;
  }

  static Exception _httpErr(String who, http.Response res) {
    String detail = '';
    try {
      final err = jsonDecode(res.body) as Map<String, dynamic>;
      final msg = err['error'] is Map
          ? (err['error'] as Map)['message']
          : err['error'];
      detail = ': ${msg ?? res.body}'.toString().substring(0, 200);
    } catch (_) {
      detail =
          ': ${res.body.substring(0, res.body.length.clamp(0, 120))}';
    }
    return Exception('$who ${res.statusCode}$detail');
  }
}

extension<T> on List<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
