import 'dart:convert';

import 'package:http/http.dart' as http;

/// Content fetchers: pull real post/video/caption text so AI tags come from
/// CONTENT, not just the title. All best-effort, never throw, short timeouts.
///
/// - YouTube: oEmbed (title/author) + noembed fallback + watch-page scrape
///   (og:description, keywords, caption tracks list).
/// - Reddit: public .json (selftext, top comments) via old.reddit first.
/// - Instagram: public ?__a=1 / embed caption scrape (login-walled often).
class ContentFetcher {
  static const _ua =
      'Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Mobile Safari/537.36';

  /// Same contract as LinkParser._get (direct-only; browser CORS blocks
  /// page scrapes on web, phone is unaffected). Kept local to avoid import.
  static Future<http.Response?> _get(String url,
      {Map<String, String>? headers, Duration timeout = const Duration(seconds: 12)}) async {
    try {
      final res = await http.get(Uri.parse(url), headers: headers).timeout(timeout);
      if (res.statusCode == 200) return res;
    } catch (_) {}
    return null;
  }

  /// Returns up to ~4k chars of content context, or null when unavailable.
  static Future<String?> fetchFor(String url, String typeName) async {
    try {
      final t = typeName.toLowerCase();
      if (t.contains('youtube')) return await _youtube(url);
      if (t.contains('reddit')) return await _reddit(url);
      if (t.contains('instagram')) return await _instagram(url);
      return null;
    } catch (_) {
      return null;
    }
  }

  // --------------------------------------------------------------- youtube
  static Future<String?> _youtube(String url) async {
    final out = <String>[];
    final videoId = _ytId(url);
    // 1. oEmbed title/author (fast, reliable).
    try {
      final res = await _get(
          'https://www.youtube.com/oembed?url=${Uri.encodeComponent(url)}&format=json',
          timeout: const Duration(seconds: 8));
      if (res != null && res.statusCode == 200) {
        final j = jsonDecode(res.body) as Map<String, dynamic>;
        if ((j['title'] as String?)?.isNotEmpty == true) {
          out.add('Video title: ${j['title']}');
        }
        if ((j['author_name'] as String?)?.isNotEmpty == true) {
          out.add('Channel: ${j['author_name']}');
        }
      }
    } catch (_) {}
    // 2. noembed fallback (different infra, sometimes works when oEmbed 403s).
    if (out.isEmpty) {
      try {
        final res = await _get(
            'https://noembed.com/embed?url=${Uri.encodeComponent(url)}',
            timeout: const Duration(seconds: 8));
        if (res != null && res.statusCode == 200) {
          final j = jsonDecode(res.body) as Map<String, dynamic>;
          if ((j['title'] as String?)?.isNotEmpty == true) {
            out.add('Video title: ${j['title']}');
          }
          if ((j['author_name'] as String?)?.isNotEmpty == true) {
            out.add('Channel: ${j['author_name']}');
          }
        }
      } catch (_) {}
    }
    // 3. Watch-page scrape: description, keywords, caption-track names.
    if (videoId != null) {
      try {
        final res = await _get(
          'https://www.youtube.com/watch?v=$videoId&hl=en',
          headers: {'User-Agent': _ua, 'Accept-Language': 'en-US,en;q=0.9'},
          timeout: const Duration(seconds: 10),
        );
        if (res != null && res.statusCode == 200) {
          final html = res.body;
          final desc = _ytMeta(html, 'description');
          if (desc != null && desc.length > 40) {
            out.add('Description: ${_clip(desc, 1500)}');
          }
          final keywords = _ytMeta(html, 'keywords');
          if (keywords != null && keywords.isNotEmpty) {
            out.add('Keywords: ${_clip(keywords, 400)}');
          }
          // Caption track languages hint that transcripts exist.
          final capMatch =
              RegExp(r'"captionTracks":\s*\[').firstMatch(html);
          if (capMatch != null) {
            final langs = RegExp(r'"languageCode":"([a-zA-Z-]+)"')
                .allMatches(html.substring(
                    capMatch.start, (capMatch.start + 4000).clamp(0, html.length)))
                .map((m) => m.group(1))
                .toSet()
                .take(5)
                .join(', ');
            if (langs.isNotEmpty) out.add('Captions available in: $langs');
          }
        }
      } catch (_) {}
    }
    // 4. Transcript via Piped API (free, no key, verified 2026-09-26).
    // Direct timedtext baseUrls are IP-locked (return 0 bytes server-side);
    // Piped's proxy re-signs them. English preferred, manual over auto.
    if (videoId != null) {
      try {
        final transcript = await _youtubeTranscript(videoId);
        if (transcript?.isNotEmpty == true) {
          out.add('Transcript: ${_clip(transcript!, 2500)}');
        }
      } catch (_) {}
    }
    if (out.isEmpty) return null;
    return _clip(out.join('\n'), 4000);
  }

  static String? _ytId(String url) {
    try {
      final uri = Uri.parse(url);
      if (uri.host.contains('youtu.be') && uri.pathSegments.isNotEmpty) {
        return uri.pathSegments.first.split('?').first;
      }
      final v = uri.queryParameters['v'];
      if (v != null && v.isNotEmpty) return v;
      // /shorts/<id>, /embed/<id>, /live/<id> carry no ?v= param.
      final segs = uri.pathSegments;
      for (var i = 0; i < segs.length - 1; i++) {
        if (['shorts', 'embed', 'live', 'v'].contains(segs[i].toLowerCase())) {
          return segs[i + 1].split('?').first;
        }
      }
    } catch (_) {}
    return null;
  }

  static String? _ytMeta(String html, String name) {
    final m = RegExp(
      '<meta\\s+(?:name|property)=["\']$name["\']\\s+content=["\'](.*?)["\']',
      caseSensitive: false,
      dotAll: true,
    ).firstMatch(html);
    if (m == null) return null;
    return _unescape(m.group(1)!).trim();
  }

  /// Piped instances that proxy YouTube (federated, free, no key).
  /// First healthy instance wins; each call tries in order with short
  /// timeouts so a dead instance costs ~4s max.
  static const _pipedInstances = [
    'https://api.piped.private.coffee',
    'https://pipedapi.kavin.rocks',
    'https://pipedapi.reallyaweso.me',
    'https://pipedapi.adminforge.de',
  ];

  /// Full transcript text for a YouTube video id, or null.
  /// Flow: Piped /streams -> subtitles[] -> prefer manual English ->
  /// fetch VTT via Piped proxy -> strip timestamps. Best-effort, never
  /// throws. ~2 HTTP calls, each with a short timeout.
  static Future<String?> _youtubeTranscript(String videoId) async {
    for (final base in _pipedInstances) {
      try {
        final res = await _get('$base/streams/$videoId',
            timeout: const Duration(seconds: 8));
        if (res == null || res.statusCode != 200) continue;
        final decoded = jsonDecode(res.body);
        if (decoded is! Map) continue;
        final subs = decoded['subtitles'] as List?;
        if (subs == null || subs.isEmpty) continue;
        // Prefer manual English, then any English, then first track.
        Map<String, dynamic>? pick;
        Map<String, dynamic>? firstEn;
        for (final s in subs) {
          if (s is! Map<String, dynamic>) continue;
          final code = (s['code'] as String? ?? '').toLowerCase();
          final auto = s['autoGenerated'] == true;
          if (pick == null && code.startsWith('en') && !auto) {
            pick = s;
            break;
          }
          firstEn ??= code.startsWith('en') ? s : null;
        }
        pick ??= firstEn ??
            (subs.firstWhere((s) => s is Map, orElse: () => null)
                as Map<String, dynamic>?);
        var subUrl = pick?['url'] as String?;
        if (subUrl == null || subUrl.isEmpty) continue;
        // Force VTT (easiest to strip) — Piped honors fmt param.
        subUrl = subUrl.replaceAll('fmt=ttml', 'fmt=vtt');
        if (!subUrl.contains('fmt=')) subUrl = '$subUrl&fmt=vtt';
        final vtt = await _get(subUrl,
            headers: {'User-Agent': _ua},
            timeout: const Duration(seconds: 10));
        if (vtt == null || vtt.statusCode != 200 || vtt.body.isEmpty) {
          continue;
        }
        final text = _stripVtt(vtt.body);
        if (text.length > 100) return text;
      } catch (_) {
        continue;
      }
    }
    return null;
  }

  /// Strips WEBVTT headers, timestamps, cue settings and dup lines.
  static String _stripVtt(String vtt) {
    final lines = vtt.split('\n');
    final buf = <String>[];
    String? last;
    for (var line in lines) {
      line = line.trim();
      if (line.isEmpty ||
          line == 'WEBVTT' ||
          line.startsWith('Kind:') ||
          line.startsWith('Language:') ||
          line.startsWith('NOTE') ||
          RegExp(r'^\d{2}:\d{2}').hasMatch(line) ||
          RegExp(r'-->').hasMatch(line)) {
        continue;
      }
      // Strip cue settings + inline tags like <c>, <00:00:01.000>.
      line = line.replaceAll(RegExp(r'<[^>]*>'), '').trim();
      if (line.isEmpty || line == last) continue;
      last = line;
      buf.add(line);
    }
    return _unescape(buf.join(' ')).replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  // ---------------------------------------------------------------- reddit
  /// PullPush (api.pullpush.io, ex-Pushshift): direct post-by-id + comments
  /// by link_id, no auth, CORS-open. Verified 2026-09-20: real selftext +
  /// real comments for 1wl83mb. Arctic Shift kept as fallback (its comments
  /// endpoint returns [] for fresh posts), legacy .json last.
  static Future<String?> _reddit(String url) async {
    // 1. PullPush: direct id lookup, no subreddit scan needed.
    try {
      final postId = _redditPostId(url);
      if (postId != null) {
        final pp = await _pullPush(postId);
        if (pp?.isNotEmpty == true) return pp;
      }
    } catch (_) {}
    // 2. Arctic Shift fallback.
    try {
      final postId = _redditPostId(url);
      if (postId != null) {
        final arctic = await _arcticShift(postId, url);
        if (arctic?.isNotEmpty == true) return arctic;
      }
    } catch (_) {}
    // 2. Legacy direct .json (currently walled, kept as fallback).
    var jsonUrl = url.split('?').first;
    if (jsonUrl.endsWith('/')) {
      jsonUrl = jsonUrl.substring(0, jsonUrl.length - 1);
    }
    final candidates = [
      jsonUrl.replaceFirst('://www.reddit.com', '://old.reddit.com'),
      jsonUrl.replaceFirst('://old.reddit.com', '://www.reddit.com'),
    ];
    const uas = ['save-later/1.0 by u/savelaterapp', _ua];
    for (final c in candidates) {
      for (final ua in uas) {
        try {
          final res = await _get('$c.json',
              headers: {'User-Agent': ua, 'Accept': 'application/json'},
              timeout: const Duration(seconds: 10));
          if (res == null || res.statusCode != 200) continue;
          final decoded = jsonDecode(res.body);
          if (decoded is! List || decoded.isEmpty) continue;
          final out = <String>[];
          // Post selftext.
          try {
            final children = decoded[0]['data']['children'] as List?;
            if (children != null && children.isNotEmpty) {
              final post = children[0]['data'] as Map<String, dynamic>;
              final selftext = (post['selftext'] as String?)?.trim() ?? '';
              if (selftext.isNotEmpty &&
                  selftext != '[removed]' &&
                  selftext != '[deleted]') {
                out.add('Post text: ${_clip(selftext, 2000)}');
              }
              final flair = (post['link_flair_text'] as String?)?.trim();
              if (flair?.isNotEmpty == true) out.add('Flair: $flair');
            }
          } catch (_) {}
          // Top comments (up to 5, each clipped).
          try {
            final comments = decoded.length > 1
                ? decoded[1]['data']['children'] as List?
                : null;
            var taken = 0;
            if (comments != null) {
              for (final cm in comments) {
                if (taken >= 5) break;
                final d = (cm as Map)['data'] as Map<String, dynamic>?;
                final body = (d?['body'] as String?)?.trim() ?? '';
                final score = (d?['score'] as num?)?.toInt() ?? 0;
                if (body.isEmpty ||
                    body == '[removed]' ||
                    body == '[deleted]' ||
                    body.length < 30) {
                  continue;
                }
                out.add('Top comment (▲$score): ${_clip(body, 400)}');
                taken++;
              }
            }
          } catch (_) {}
          if (out.isNotEmpty) return _clip(out.join('\n\n'), 4000);
        } catch (_) {
          continue;
        }
      }
    }
    return null;
  }

  /// Extracts the base-36 post id from /comments/<id>/ URLs.
  static String? _redditPostId(String url) {
    try {
      final m = RegExp(r'/comments/([a-z0-9]+)', caseSensitive: false)
          .firstMatch(url);
      return m?.group(1);
    } catch (_) {
      return null;
    }
  }

  /// Extracts subreddit name from /r/<name>/ URLs.
  static String? _redditSubreddit(String url) {
    try {
      final m =
          RegExp(r'/r/([A-Za-z0-9_]+)', caseSensitive: false).firstMatch(url);
      return m?.group(1);
    } catch (_) {
      return null;
    }
  }

  /// Arctic Shift public archive: full post record (selftext, flair, score)
  /// + top comments for the post. No auth needed. Post lookup has no
  /// id-param, so we scan the subreddit's newest 100 and match client-side
  /// (single 500KB call, ~2s). Falls back to legacy .json below.
  static Future<String?> _arcticShift(String postId, String url) async {
    final out = <String>[];
    // Post record: subreddit scan + id match.
    final sub = _redditSubreddit(url);
    if (sub == null) return null;
    Map<String, dynamic>? post;
    try {
      final res = await _get(
          'https://arctic-shift.photon-reddit.com/api/posts/search?subreddit=$sub&limit=100&sort=desc',
          timeout: const Duration(seconds: 15));
      if (res == null || res.statusCode != 200) return null;
      final decoded = jsonDecode(res.body);
      final data = decoded is Map ? decoded['data'] as List? : null;
      if (data == null) return null;
      for (final p in data) {
        if (p is Map<String, dynamic> && p['id'] == postId) {
          post = p;
          break;
        }
      }
      if (post == null) return null;
      final selftext = (post['selftext'] as String?)?.trim() ?? '';
      if (selftext.isNotEmpty &&
          selftext != '[removed]' &&
          selftext != '[deleted]') {
        out.add('Post text: ${_clip(selftext, 2000)}');
      }
      final flair = (post['link_flair_text'] as String?)?.trim();
      if (flair?.isNotEmpty == true) out.add('Flair: $flair');
      final ratio = post['upvote_ratio'];
      if (ratio != null) out.add('Upvote ratio: $ratio');
    } catch (_) {
      return null;
    }
    // Top comments: search subreddit-agnostic by link_id, sort by score.
    try {
      final res = await _get(
          'https://arctic-shift.photon-reddit.com/api/comments/search?link_id=t3_$postId&limit=25&sort=desc',
          timeout: const Duration(seconds: 12));
      if (res != null && res.statusCode == 200) {
        final decoded = jsonDecode(res.body);
        final data = decoded is Map ? decoded['data'] as List? : null;
        if (data != null) {
          final scored = <Map<String, dynamic>>[];
          for (final c in data) {
            if (c is! Map<String, dynamic>) continue;
            final body = (c['body'] as String?)?.trim() ?? '';
            if (body.isEmpty ||
                body == '[removed]' ||
                body == '[deleted]' ||
                body.length < 30) {
              continue;
            }
            scored.add(c);
          }
          scored.sort((a, b) =>
              ((b['score'] as num?) ?? 0).compareTo((a['score'] as num?) ?? 0));
          for (final c in scored.take(5)) {
            final score = (c['score'] as num?)?.toInt() ?? 0;
            out.add('Top comment (▲$score): ${_clip(c['body'] as String, 400)}');
          }
        }
      }
    } catch (_) {}
    if (out.isEmpty) return null;
    return _clip(out.join('\n\n'), 4000);
  }

  /// PullPush post + comments by direct id. Post record carries selftext,
  /// comments carry body+score. Both verified live 2026-09-20.
  static Future<String?> _pullPush(String postId) async {
    final out = <String>[];
    try {
      final res = await _get(
          'https://api.pullpush.io/reddit/search/submission/?id=$postId',
          timeout: const Duration(seconds: 12));
      if (res == null) return null;
      final decoded = jsonDecode(res.body);
      final data = decoded is Map ? decoded['data'] as List? : null;
      if (data == null || data.isEmpty) return null;
      final post = data.first as Map<String, dynamic>;
      final selftext = (post['selftext'] as String?)?.trim() ?? '';
      if (selftext.isNotEmpty &&
          selftext != '[removed]' &&
          selftext != '[deleted]') {
        out.add('Post text: ${_clip(selftext, 2000)}');
      }
      final flair = (post['link_flair_text'] as String?)?.trim();
      if (flair?.isNotEmpty == true) out.add('Flair: $flair');
    } catch (_) {
      return null;
    }
    try {
      final res = await _get(
          'https://api.pullpush.io/reddit/search/comment/?link_id=$postId&size=25&sort=desc',
          timeout: const Duration(seconds: 12));
      if (res != null) {
        final decoded = jsonDecode(res.body);
        final data = decoded is Map ? decoded['data'] as List? : null;
        if (data != null) {
          final scored = <Map<String, dynamic>>[];
          for (final c in data) {
            if (c is! Map<String, dynamic>) continue;
            final body = (c['body'] as String?)?.trim() ?? '';
            if (body.isEmpty ||
                body == '[removed]' ||
                body == '[deleted]' ||
                body.length < 30) {
              continue;
            }
            scored.add(c);
          }
          scored.sort((a, b) =>
              ((b['score'] as num?) ?? 0).compareTo((a['score'] as num?) ?? 0));
          for (final c in scored.take(5)) {
            final score = (c['score'] as num?)?.toInt() ?? 0;
            out.add('Top comment (▲$score): ${_clip(c['body'] as String, 400)}');
          }
        }
      }
    } catch (_) {}
    if (out.isEmpty) return null;
    return _clip(out.join('\n\n'), 4000);
  }

  // ------------------------------------------------------------- instagram
  static Future<String?> _instagram(String url) async {
    // 0. api/v1/oembed (no key, verified 2026-09-26): title/author.
    try {
      final res = await _get(
          'https://www.instagram.com/api/v1/oembed/?url=${Uri.encodeComponent(url)}',
          headers: {'User-Agent': _ua},
          timeout: const Duration(seconds: 10));
      if (res != null && res.statusCode == 200) {
        final j = jsonDecode(res.body) as Map<String, dynamic>;
        final out = <String>[];
        final author = (j['author_name'] as String?)?.trim();
        final title = (j['title'] as String?)?.trim();
        if (author?.isNotEmpty == true) out.add('Post by: $author');
        if (title?.isNotEmpty == true) {
          out.add('Caption: ${_clip(title!, 2000)}');
        }
        // Don't return yet — embed scrape below may add more caption text.
        // Fall through and merge when both succeed.
        if (out.isNotEmpty) {
          final embedExtra = await _instagramEmbedCaption(url);
          if (embedExtra?.isNotEmpty == true) {
            return _clip('${out.join('\n')}\n$embedExtra', 4000);
          }
          return _clip(out.join('\n'), 2500);
        }
      }
    } catch (_) {}
    // 1. Embed page often exposes og:description caption without login.
    final embedOnly = await _instagramEmbedCaption(url);
    if (embedOnly?.isNotEmpty == true) return embedOnly;
    return null;
  }

  static Future<String?> _instagramEmbedCaption(String url) async {
    // 1. Embed page often exposes og:description caption without login.
    try {
      var embed = url.split('?').first;
      if (!embed.endsWith('/')) embed = '$embed/';
      final res = await _get('${embed}embed/captioned/',
          headers: {'User-Agent': _ua, 'Accept-Language': 'en-US,en;q=0.9'},
          timeout: const Duration(seconds: 10));
      if (res != null && res.statusCode == 200) {
        final html = res.body;
        final desc = RegExp(
          '<meta\\s+property=["\']og:description["\']\\s+content=["\'](.*?)["\']',
          caseSensitive: false,
          dotAll: true,
        ).firstMatch(html)?.group(1);
        final title = RegExp(
          '<meta\\s+property=["\']og:title["\']\\s+content=["\'](.*?)["\']',
          caseSensitive: false,
          dotAll: true,
        ).firstMatch(html)?.group(1);
        final out = <String>[];
        if (title?.isNotEmpty == true) {
          out.add('Post by: ${_clip(_unescape(title!), 200)}');
        }
        if (desc?.isNotEmpty == true && desc!.length > 20) {
          out.add('Caption: ${_clip(_unescape(desc), 2000)}');
        }
        if (out.isNotEmpty) return _clip(out.join('\n'), 2500);
      }
    } catch (_) {}
    return null;
  }

  // ---------------------------------------------------------------- helpers
  static String _clip(String s, int max) =>
      s.length > max ? '${s.substring(0, max)}…' : s;

  static String _unescape(String s) => s
      .replaceAll('&amp;', '&')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll(RegExp(r'\s+'), ' ');
}
