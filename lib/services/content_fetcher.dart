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
      // /shorts/<id>, /embed/<id>, /live/<id>
      final segs = uri.pathSegments;
      for (var i = 0; i < segs.length - 1; i++) {
        if (['shorts', 'embed', 'live', 'v'].contains(segs[i])) {
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

  // ---------------------------------------------------------------- reddit
  /// Reddit blocks all unauthenticated .json access (403 www, login-wall
  /// old — verified 2026-09-20). Source of truth is the Arctic Shift public
  /// archive (arctic-shift.photon-reddit.com): post selftext + top comments
  /// by link_id. Falls back to legacy .json attempts in case Reddit opens up.
  static Future<String?> _reddit(String url) async {
    // 1. Arctic Shift: resolve post id from the URL, fetch post + comments.
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

  // ------------------------------------------------------------- instagram
  static Future<String?> _instagram(String url) async {
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
