import 'dart:convert';

import 'package:html/dom.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:http/http.dart' as http;

import '../models/saved_item.dart';

/// Rich metadata for a URL before AI enrichment.
/// v2: Reddit oEmbed-first + JSON enrichment, full OG/Twitter/JSON-LD/article
/// tags, readability-lite body extraction for AI context.
class LinkMeta {
  final String title;
  final ItemType type;
  final String? thumbnailUrl;
  final String? author;
  final String? description;

  // v2 extras
  final String? siteName;
  final String? excerpt;
  final int? readingMinutes;
  final String? subreddit;
  final int? redditScore;
  final int? redditComments;
  final bool? isVideo;
  final String? articleText; // first ~2k chars of body, AI context only (not stored)

  const LinkMeta({
    required this.title,
    required this.type,
    this.thumbnailUrl,
    this.author,
    this.description,
    this.siteName,
    this.excerpt,
    this.readingMinutes,
    this.subreddit,
    this.redditScore,
    this.redditComments,
    this.isVideo,
    this.articleText,
  });
}

class LinkParser {
  static final _yt = RegExp(r'(youtube\.com|youtu\.be|music\.youtube\.com)');
  static final _reddit = RegExp(r'(reddit\.com|redd\.it)');
  static final _x = RegExp(r'(twitter\.com|x\.com)');
  static final _tiktok = RegExp(r'tiktok\.com');
  static final _insta = RegExp(r'instagram\.com');
  static final _movieHint = RegExp(r'(imdb\.com|themoviedb\.org|letterboxd\.com)', caseSensitive: false);
  static final _podcastHint = RegExp(r'(podcasts\.apple\.com|open\.spotify\.com.*episode|overcast\.fm|pocketcasts\.com)',
      caseSensitive: false);
  static final _pdfHint = RegExp(r'\.pdf($|\?|#)', caseSensitive: false);

  static const _browserUa =
      'Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Mobile Safari/537.36';

  /// GET with graceful failure. On web the browser enforces CORS, so only
  /// CORS-open endpoints (oEmbed, Arctic Shift, Gemini) succeed there — page
  /// scrapes work on phone only. Never throws; null means "unavailable".
  static Future<http.Response?> _get(String url,
      {Map<String, String>? headers, Duration timeout = const Duration(seconds: 12)}) async {
    try {
      final res = await http.get(Uri.parse(url), headers: headers).timeout(timeout);
      if (res.statusCode == 200) return res;
    } catch (_) {}
    return null;
  }

  static ItemType detectType(String url, {String? ogType}) {
    final u = url.toLowerCase();
    if (_yt.hasMatch(u)) return ItemType.youtube;
    if (_reddit.hasMatch(u)) return ItemType.reddit;
    if (_x.hasMatch(u)) return ItemType.x;
    if (_tiktok.hasMatch(u)) return ItemType.tiktok;
    if (_insta.hasMatch(u)) return ItemType.instagram;
    if (_movieHint.hasMatch(u)) return ItemType.movie;
    if (_podcastHint.hasMatch(u)) return ItemType.generic;
    if (_pdfHint.hasMatch(u)) return ItemType.article;
    // Trust og:type when present: video.* -> watch bucket.
    final og = (ogType ?? '').toLowerCase();
    if (og.startsWith('video')) return ItemType.youtube;
    if (og.startsWith('music')) return ItemType.generic;
    if (og == 'article') return ItemType.article;
    return ItemType.generic;
  }

  /// Fetch best-effort metadata. Never throws — falls back to URL host.
  static Future<LinkMeta> fetchMeta(String url) async {
    final normalized = _normalize(url);
    try {
      if (_yt.hasMatch(normalized.toLowerCase())) {
        final meta = await _youtubeOembed(normalized);
        if (meta != null) return meta;
      }
      if (_reddit.hasMatch(normalized.toLowerCase())) {
        final meta = await _redditRich(normalized);
        if (meta != null) return meta;
      }
      if (_insta.hasMatch(normalized.toLowerCase())) {
        final meta = await _instagramRich(normalized);
        if (meta != null) return meta;
      }
      return await _richPage(normalized);
    } catch (_) {
      return LinkMeta(title: _fallbackTitle(normalized), type: detectType(normalized));
    }
  }

  // ---------------------------------------------------------------- youtube
  static Future<LinkMeta?> _youtubeOembed(String url) async {
    final endpoint = 'https://www.youtube.com/oembed?url=${Uri.encodeComponent(url)}&format=json';
    try {
      final res = await _get(endpoint, timeout: const Duration(seconds: 10));
      if (res != null && res.statusCode == 200) {
        final j = jsonDecode(res.body) as Map<String, dynamic>;
        final videoId = _extractYoutubeId(url);
        final author = j['author_name'] as String?;
        return LinkMeta(
          title: (j['title'] as String?) ?? _fallbackTitle(url),
          type: ItemType.youtube,
          author: author,
          thumbnailUrl: videoId != null ? 'https://i.ytimg.com/vi/$videoId/hqdefault.jpg' : null,
          // oEmbed has no description — leave it null so AI writes a real
          // topic summary from the title instead of "Open to watch" filler.
          description: null,
          siteName: 'YouTube',
          isVideo: true,
        );
      }
    } catch (_) {}
    // oEmbed blocked/failed (embeds disabled, no network): try the
    // watch-page <title> ("Real Title - YouTube") so cards/AI never show
    // just "youtube.com". Thumbnail works from the id alone.
    final videoId = _extractYoutubeId(url);
    final thumb = videoId != null ? 'https://i.ytimg.com/vi/$videoId/hqdefault.jpg' : null;
    if (videoId != null) {
      try {
        final res = await _get(
            'https://www.youtube.com/watch?v=$videoId&hl=en',
            headers: {'User-Agent': _browserUa, 'Accept-Language': 'en-US,en;q=0.9'},
            timeout: const Duration(seconds: 10));
        final m = res == null
            ? null
            : RegExp(r'<title>(.*?)</title>', caseSensitive: false, dotAll: true)
                .firstMatch(res.body)
                ?.group(1);
        var t = m == null ? null : _clean(m.replaceAll(RegExp(r'\s+'), ' '));
        if (t != null && t.toLowerCase().endsWith(' - youtube')) {
          t = t.substring(0, t.length - ' - youtube'.length).trim();
        }
        if (t != null && t.isNotEmpty && t.toLowerCase() != 'youtube') {
          return LinkMeta(
            title: t,
            type: ItemType.youtube,
            thumbnailUrl: thumb,
            description: null,
            siteName: 'YouTube',
            isVideo: true,
          );
        }
      } catch (_) {}
    }
    return LinkMeta(
      title: videoId != null ? 'YouTube video ($videoId)' : _fallbackTitle(url),
      type: ItemType.youtube,
      thumbnailUrl: thumb,
      description: null,
      siteName: 'YouTube',
      isVideo: true,
    );
  }

  // ----------------------------------------------------------------- reddit
  /// PullPush first (direct id lookup, verified 2026-09-20): real
  /// title/author/subreddit/score/comments/selftext. Arctic Shift second,
  /// legacy oEmbed + .json last (both currently walled). Slug fallback so
  /// the title is never the bare host.
  static Future<LinkMeta?> _redditRich(String url) async {
    final canonical = _canonicalReddit(url);
    // 1. PullPush: title + author + subreddit + score + selftext by id.
    try {
      final pp = await _pullPushPost(canonical);
      if (pp != null) return pp;
    } catch (_) {}
    // 2. Arctic Shift: title + author + subreddit + score + selftext.
    try {
      final arctic = await _arcticPost(canonical);
      if (arctic != null) return arctic;
    } catch (_) {}
    LinkMeta? base;
    try {
      final oembed = await _get(
          'https://www.reddit.com/oembed?url=${Uri.encodeComponent(canonical)}',
          timeout: const Duration(seconds: 10));
      if (oembed != null && oembed.statusCode == 200) {
        final j = jsonDecode(oembed.body) as Map<String, dynamic>;
        base = LinkMeta(
          title: (j['title'] as String?) ?? _fallbackTitle(url),
          type: ItemType.reddit,
          author: j['author_name'] as String?,
          thumbnailUrl: _validThumb(j['thumbnail_url'] as String?),
          siteName: 'Reddit',
        );
      }
    } catch (_) {
      // fall through to JSON attempt
    }

    try {
      final post = await _redditPostJson(canonical);
      if (post != null) {
        final thumb = _validThumb(post['thumbnail'] as String?) ??
            _previewImage(post) ??
            base?.thumbnailUrl;
        final sub = post['subreddit'] as String?;
        final selftext = (post['selftext'] as String?)?.trim();
        return LinkMeta(
          title: (post['title'] as String?) ?? base?.title ?? _fallbackTitle(url),
          type: ItemType.reddit,
          author: (post['author'] as String?) ?? base?.author,
          thumbnailUrl: thumb,
          description: selftext?.isNotEmpty == true ? selftext : base?.description,
          siteName: 'Reddit',
          subreddit: sub,
          redditScore: (post['score'] as num?)?.toInt() ?? (post['ups'] as num?)?.toInt(),
          redditComments: (post['num_comments'] as num?)?.toInt(),
          articleText: selftext?.isNotEmpty == true ? _clip(selftext!, 2000) : null,
        );
      }
    } catch (_) {
      // fall through to slug/base below
    }
    if (base != null) return base;
    // Last resort — never return null: the URL slug carries the real title
    // ("/comments/<id>/ashneer_day_by_day/") so cards never read "reddit".
    final slug = _redditSlugTitle(canonical);
    final subM = RegExp(r'/r/([A-Za-z0-9_]+)').firstMatch(canonical);
    if (slug != null) {
      return LinkMeta(
        title: slug,
        type: ItemType.reddit,
        siteName: 'Reddit',
        subreddit: subM?.group(1),
      );
    }
    return null;
  }

  /// PullPush post lookup by direct id. Same shape as Arctic (title,
  /// author, subreddit, score, comments, selftext).
  static Future<LinkMeta?> _pullPushPost(String canonical) async {
    final idM = RegExp(r'/comments/([a-z0-9]+)', caseSensitive: false)
        .firstMatch(canonical);
    final subM = RegExp(r'/r/([A-Za-z0-9_]+)').firstMatch(canonical);
    final postId = idM?.group(1);
    final sub = subM?.group(1);
    if (postId == null) return null;
    try {
      final res = await _get(
          'https://api.pullpush.io/reddit/search/submission/?id=$postId',
          timeout: const Duration(seconds: 12));
      if (res == null) return null;
      final decoded = jsonDecode(res.body);
      final data = decoded is Map ? decoded['data'] as List? : null;
      if (data == null || data.isEmpty) return null;
      final post = data.first as Map<String, dynamic>;
      final selftext = ((post['selftext'] as String?) ?? '').trim();
      final title = ((post['title'] as String?) ?? '').trim();
      if (title.isEmpty) return null;
      return LinkMeta(
        title: title,
        type: ItemType.reddit,
        author: post['author'] as String?,
        thumbnailUrl: _validThumb(post['thumbnail'] as String?),
        description:
            selftext.isNotEmpty && selftext != '[removed]' && selftext != '[deleted]'
                ? selftext
                : null,
        siteName: 'Reddit',
        subreddit: (post['subreddit'] as String?) ?? sub,
        redditScore: (post['score'] as num?)?.toInt(),
        redditComments: (post['num_comments'] as num?)?.toInt(),
        articleText:
            selftext.isNotEmpty && selftext != '[removed]' && selftext != '[deleted]'
                ? _clip(selftext, 2000)
                : null,
      );
    } catch (_) {
      return null;
    }
  }

  /// Arctic Shift post lookup: subreddit newest-100 scan, client-side id
  /// match. Returns full LinkMeta (title/author/subreddit/score/comments).
  /// Title slug in the URL is a last resort (underscores -> spaces).
  static Future<LinkMeta?> _arcticPost(String canonical) async {
    final idM = RegExp(r'/comments/([a-z0-9]+)', caseSensitive: false).firstMatch(canonical);
    final subM = RegExp(r'/r/([A-Za-z0-9_]+)').firstMatch(canonical);
    final postId = idM?.group(1);
    final sub = subM?.group(1);
    Map<String, dynamic>? post;
    if (postId != null && sub != null) {
      try {
        final res = await _get(
            'https://arctic-shift.photon-reddit.com/api/posts/search?subreddit=$sub&limit=100&sort=desc',
            timeout: const Duration(seconds: 15));
        if (res != null && res.statusCode == 200) {
          final decoded = jsonDecode(res.body);
          final data = decoded is Map ? decoded['data'] as List? : null;
          if (data != null) {
            for (final p in data) {
              if (p is Map<String, dynamic> && p['id'] == postId) {
                post = p;
                break;
              }
            }
          }
        }
      } catch (_) {}
    }
    if (post == null) {
      // Slug fallback: /comments/<id>/<title_with_underscores>/ carries the
      // real title — better than "reddit.com".
      final slug = _redditSlugTitle(canonical);
      if (slug == null) return null;
      return LinkMeta(
        title: slug,
        type: ItemType.reddit,
        siteName: 'Reddit',
        subreddit: sub,
      );
    }
    final selftext = ((post['selftext'] as String?) ?? '').trim();
    final title = ((post['title'] as String?) ?? '').trim();
    return LinkMeta(
      title: title.isNotEmpty ? title : (_redditSlugTitle(canonical) ?? _fallbackTitle(canonical)),
      type: ItemType.reddit,
      author: post['author'] as String?,
      thumbnailUrl: _validThumb(post['thumbnail'] as String?) ?? _previewImage(post),
      description: selftext.isNotEmpty && selftext != '[removed]' && selftext != '[deleted]' ? selftext : null,
      siteName: 'Reddit',
      subreddit: (post['subreddit'] as String?) ?? sub,
      redditScore: (post['score'] as num?)?.toInt(),
      redditComments: (post['num_comments'] as num?)?.toInt(),
      articleText: selftext.isNotEmpty && selftext != '[removed]' && selftext != '[deleted]' ? _clip(selftext, 2000) : null,
    );
  }

  /// "ashneer_day_by_day" -> "Ashneer Day By Day" from the URL slug.
  static String? _redditSlugTitle(String canonical) {
    try {
      final m = RegExp(r'/comments/[a-z0-9]+/([^/?#]+)', caseSensitive: false).firstMatch(canonical);
      final slug = m?.group(1);
      if (slug == null || slug.isEmpty) return null;
      final words = slug.split('_').where((w) => w.isNotEmpty).toList();
      if (words.isEmpty) return null;
      return words.map((w) => w[0].toUpperCase() + (w.length > 1 ? w.substring(1) : '')).join(' ');
    } catch (_) {
      return null;
    }
  }

  static Future<Map<String, dynamic>?> _redditPostJson(String canonical) async {
    // Try old.reddit (less bot-walled) then www with JSON-friendly UA.
    const uas = [
      'save-later/1.0 by u/savelaterapp',
      _browserUa,
    ];
    var jsonUrl = canonical.split('?').first;
    if (jsonUrl.endsWith('/')) jsonUrl = jsonUrl.substring(0, jsonUrl.length - 1);
    final candidates = [
      jsonUrl.replaceFirst('://www.reddit.com', '://old.reddit.com'),
      jsonUrl.replaceFirst('://old.reddit.com', '://www.reddit.com'),
    ];
    for (final c in candidates) {
      for (final ua in uas) {
        try {
          final res = await _get('$c.json',
              headers: {'User-Agent': ua, 'Accept': 'application/json'},
              timeout: const Duration(seconds: 10));
          if (res == null || res.statusCode != 200) continue;
          final decoded = jsonDecode(res.body);
          if (decoded is List && decoded.isNotEmpty) {
            final children = (decoded[0]['data']['children'] as List?);
            if (children != null && children.isNotEmpty) {
              return children[0]['data'] as Map<String, dynamic>;
            }
          }
        } catch (_) {
          continue;
        }
      }
    }
    return null;
  }

  static String? _previewImage(Map<String, dynamic> post) {
    try {
      final images = (post['preview']?['images'] as List?);
      if (images == null || images.isEmpty) return null;
      final src = images[0]['source']?['url'] as String?;
      if (src == null) return null;
      return src.replaceAll('&amp;', '&');
    } catch (_) {
      return null;
    }
  }

  // -------------------------------------------------------------- instagram
  /// Instagram is login-walled: no oEmbed without a token, and page HTML is
  /// mostly JS. Strategy: parse the shortcode, try the public oEmbed with a
  /// browser UA (sometimes works), else rich-page scrape (caption sometimes
  /// in og:description), else a clean "Instagram post by @user" fallback with
  /// the shortcode as context for AI.
  static Future<LinkMeta?> _instagramRich(String url) async {
    final username = _instagramUsername(url);

    // 1. Public oEmbed (no key; verified 2026-09-26 returns title/author/thumb).
    try {
      final res = await _get(
          'https://www.instagram.com/api/v1/oembed/?url=${Uri.encodeComponent(url)}',
          headers: {'User-Agent': _browserUa},
          timeout: const Duration(seconds: 10));
      if (res != null && res.statusCode == 200) {
        final j = jsonDecode(res.body) as Map<String, dynamic>;
        final oembedTitle = (j['title'] as String?)?.trim();
        final oembedAuthor =
            (j['author_name'] as String?) ?? (username != null ? '@$username' : null);
        return LinkMeta(
          title: oembedTitle?.isNotEmpty == true
              ? oembedTitle!
              : (username != null ? 'Instagram post by @$username' : 'Instagram post'),
          type: ItemType.instagram,
          author: oembedAuthor,
          thumbnailUrl: _validThumb(j['thumbnail_url'] as String?),
          // oEmbed title IS the caption snippet — expose it as description
          // so the AI classifier sees it even when page scrape is blocked.
          description: oembedTitle?.isNotEmpty == true ? oembedTitle : null,
          excerpt: oembedTitle?.isNotEmpty == true ? _clip(oembedTitle!, 500) : null,
          siteName: 'Instagram',
          isVideo: (j['html'] as String?)?.contains('<video') == true ||
              url.contains('/reel'),
        );
      }
    } catch (_) {}

    // 2. Page scrape — caption occasionally in og:description.
    try {
      final page = await _richPage(url);
      final hasCaption = (page.description?.length ?? 0) > 30;
      if (hasCaption || page.thumbnailUrl != null) {
        return LinkMeta(
          title: hasCaption
              ? _clip(page.description!, 120)
              : (username != null ? 'Instagram post by @$username' : 'Instagram post'),
          type: ItemType.instagram,
          author: username != null ? '@$username' : page.author,
          thumbnailUrl: page.thumbnailUrl,
          description: page.description,
          siteName: 'Instagram',
          isVideo: url.contains('/reel') || (page.isVideo ?? false),
          articleText: page.articleText,
        );
      }
    } catch (_) {}

    // 3. Clean fallback — never put the shortcode id in the title (users
    // reported cards reading just an id). Kind-aware label instead.
    final isReel = url.contains('/reel');
    final label = username != null
        ? '${isReel ? 'Reel' : 'Post'} by @$username'
        : (isReel ? 'Instagram reel' : 'Instagram post');
    return LinkMeta(
      title: label,
      type: ItemType.instagram,
      author: username != null ? '@$username' : null,
      siteName: 'Instagram',
      isVideo: isReel,
      description: username != null
          ? 'Instagram ${isReel ? 'reel' : 'post'} by @$username. Open in Instagram to view.'
          : 'Instagram ${isReel ? 'reel' : 'post'}. Open in Instagram to view.',
    );
  }

  static String? _instagramUsername(String url) {
    try {
      final uri = Uri.parse(url);
      final segs = uri.pathSegments.where((s) => s.isNotEmpty).toList();
      // Profile links: instagram.com/<username>[/...]
      if (segs.isNotEmpty &&
          !['p', 'reel', 'reels', 'tv', 'explore', 'stories', 'direct', 'accounts'].contains(segs[0].toLowerCase())) {
        final name = segs[0];
        if (RegExp(r'^[A-Za-z0-9._]{1,30}$').hasMatch(name)) return name;
      }
    } catch (_) {}
    return null;
  }

  // ------------------------------------------------------------- rich page
  /// Full OG + Twitter cards + JSON-LD + article: tags + body excerpt.
  static Future<LinkMeta> _richPage(String url) async {
    final res = await _get(url,
        headers: {'User-Agent': _browserUa, 'Accept-Language': 'en-US,en;q=0.9'},
        timeout: const Duration(seconds: 12));
    if (res == null || res.statusCode != 200) {
      return LinkMeta(title: _fallbackTitle(url), type: detectType(url));
    }
    final doc = html_parser.parse(res.body);

    String? metaProp(String prop) =>
        doc.querySelector('meta[property="$prop"]')?.attributes['content']?.trim();
    String? metaName(String name) =>
        doc.querySelector('meta[name="$name"]')?.attributes['content']?.trim();

    final jsonLd = _parseJsonLd(doc);
    final ogType = metaProp('og:type');
    final type = detectType(url, ogType: ogType);

    var title = metaProp('og:title') ??
        metaName('twitter:title') ??
        jsonLd['headline'] ??
        doc.querySelector('title')?.text.trim();
    title = (title?.isNotEmpty == true) ? title! : _fallbackTitle(url);

    var image = metaProp('og:image') ??
        metaProp('og:image:secure_url') ??
        metaName('twitter:image') ??
        metaName('twitter:image:src') ??
        jsonLd['image'];
    image = _absUrl(image, url);

    var desc = metaProp('og:description') ??
        metaName('twitter:description') ??
        metaName('description') ??
        jsonLd['description'];
    desc = _clean(desc);

    final author = metaProp('article:author') ??
        metaName('author') ??
        metaProp('og:article:author') ??
        jsonLd['author'];

    final siteName = metaProp('og:site_name') ?? jsonLd['siteName'] ?? Uri.tryParse(url)?.host.replaceFirst('www.', '');

    final isVideo = (ogType?.toLowerCase().startsWith('video') == true) ||
        metaProp('og:video') != null ||
        metaName('twitter:player') != null ||
        metaName('twitter:card') == 'player';

    // Readability-lite: biggest <article>/<main> or paragraph cluster.
    final bodyText = _extractBodyText(doc);
    final minutes = bodyText == null ? null : _readingMinutes(bodyText);

    return LinkMeta(
      title: title,
      type: type,
      thumbnailUrl: _validThumb(image),
      author: _clean(author),
      description: desc,
      siteName: siteName,
      excerpt: desc,
      readingMinutes: minutes,
      isVideo: isVideo,
      articleText: bodyText == null ? null : _clip(bodyText, 2000),
    );
  }

  /// Schema.org JSON-LD (NewsArticle/Article/BlogPosting/WebPage) — many
  /// news/blog sites have better data here than in OG tags.
  static Map<String, String?> _parseJsonLd(Document doc) {
    final out = <String, String?>{};
    for (final el in doc.querySelectorAll('script[type="application/ld+json"]')) {
      try {
        final raw = jsonDecode(el.text);
        final graphs = raw is Map && raw['@graph'] is List ? raw['@graph'] as List : [raw];
        for (final g in graphs) {
          if (g is! Map) continue;
          final t = (g['@type'] ?? '').toString().toLowerCase();
          if (!t.contains('article') && !t.contains('webpage') && !t.contains('blogposting') && !t.contains('newsarticle')) {
            continue;
          }
          out['headline'] ??= _str(g['headline']);
          out['description'] ??= _str(g['description']);
          final img = g['image'];
          out['image'] ??= img is Map ? _str(img['url']) : img is List && img.isNotEmpty ? _str(img.first is Map ? img.first['url'] : img.first) : _str(img);
          final auth = g['author'];
          out['author'] ??= auth is Map ? _str(auth['name']) : auth is List && auth.isNotEmpty ? _str(auth.first is Map ? auth.first['name'] : auth.first) : _str(auth);
          final pub = g['publisher'];
          out['siteName'] ??= pub is Map ? _str(pub['name']) : null;
          if (out['headline'] != null) return out;
        }
      } catch (_) {
        continue;
      }
    }
    return out;
  }

  static String? _str(dynamic v) {
    if (v == null) return null;
    final s = v.toString().trim();
    return s.isEmpty ? null : s;
  }

  /// Heuristic body extraction: prefer <article>, else <main>, else the
  /// <div>/<section> with the most <p> text. Strips nav/script/style.
  static String? _extractBodyText(Document doc) {
    for (final bad in doc.querySelectorAll('script, style, nav, header, footer, aside, form, noscript')) {
      bad.remove();
    }
    Element? root = doc.querySelector('article') ?? doc.querySelector('main');
    root ??= _biggestTextBlock(doc);
    if (root == null) return null;
    final paras = root.querySelectorAll('p').map((e) => e.text.trim()).where((t) => t.length > 40).toList();
    final text = paras.isNotEmpty ? paras.join('\n\n') : root.text.trim();
    final cleaned = text.replaceAll(RegExp(r'\n{3,}'), '\n\n').trim();
    return cleaned.length > 200 ? cleaned : null;
  }

  static Element? _biggestTextBlock(Document doc) {
    Element? best;
    var bestLen = 0;
    for (final el in doc.querySelectorAll('div, section')) {
      final len = el.text.trim().length;
      if (len > bestLen && len < 200000) {
        bestLen = len;
        best = el;
      }
    }
    return bestLen > 500 ? best : null;
  }

  static int _readingMinutes(String text) {
    final words = text.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).length;
    return (words / 200).ceil().clamp(1, 300);
  }

  // ---------------------------------------------------------------- helpers
  static String _normalize(String url) {
    var u = url.trim();
    // Bare reddit share links like "r/flutterdev/comments/abc" without scheme.
    if (!u.contains('://') && (u.startsWith('r/') || u.contains('reddit.com/') || u.contains('redd.it/'))) {
      u = 'https://$u';
    }
    // Expand redd.it short links to www.reddit.com for oEmbed/JSON.
    final uri = Uri.tryParse(u);
    if (uri != null && uri.host == 'redd.it' && uri.pathSegments.isNotEmpty) {
      u = 'https://www.reddit.com/comments/${uri.pathSegments.first}';
    }
    return u;
  }

  static String _canonicalReddit(String url) {
    var c = url.split('?').first;
    // Strip trailing comment permalink: /comments/<id>/.../<commentId> -> post URL.
    final m = RegExp(r'(https?://[^/]*reddit\.com/r/[^/]+/comments/[^/]+/[^/]+)').firstMatch(c);
    if (m != null) return m.group(1)!;
    return c;
  }

  static String? _extractYoutubeId(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return null;
    if (uri.host.contains('youtu.be')) {
      return uri.pathSegments.isNotEmpty ? uri.pathSegments.first.split('?').first : null;
    }
    final v = uri.queryParameters['v'];
    if (v != null && v.isNotEmpty) return v;
    // /shorts/<id>, /live/<id>, /embed/<id>, /v/<id> carry no ?v= param.
    final segs = uri.pathSegments;
    for (var i = 0; i < segs.length - 1; i++) {
      if (['shorts', 'live', 'embed', 'v'].contains(segs[i].toLowerCase())) {
        return segs[i + 1].split('?').first;
      }
    }
    return null;
  }

  static String? _validThumb(String? t) {
    if (t == null || t.isEmpty) return null;
    if (['self', 'default', 'nsfw', 'spoiler', 'image'].contains(t)) return null;
    if (!(t.startsWith('http') || t.startsWith('//'))) return null;
    return t.startsWith('//') ? 'https:$t' : t;
  }

  static String? _absUrl(String? src, String pageUrl) {
    if (src == null || src.isEmpty) return null;
    if (src.startsWith('http') || src.startsWith('//')) {
      return src.startsWith('//') ? 'https:$src' : src;
    }
    try {
      return Uri.parse(pageUrl).resolve(src).toString();
    } catch (_) {
      return null;
    }
  }

  static String? _clean(String? s) {
    if (s == null) return null;
    final t = s.replaceAll(RegExp(r'\s+'), ' ').trim();
    return t.isEmpty ? null : t;
  }

  static String _clip(String s, int max) => s.length > max ? '${s.substring(0, max)}…' : s;

  static String _fallbackTitle(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return url;
    final host = uri.host.replaceFirst('www.', '').replaceFirst('old.', '');
    return host.isEmpty ? url : host;
  }
}
