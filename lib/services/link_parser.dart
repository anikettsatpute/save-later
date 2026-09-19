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
      return await _richPage(normalized);
    } catch (_) {
      return LinkMeta(title: _fallbackTitle(normalized), type: detectType(normalized));
    }
  }

  // ---------------------------------------------------------------- youtube
  static Future<LinkMeta?> _youtubeOembed(String url) async {
    final endpoint = 'https://www.youtube.com/oembed?url=${Uri.encodeComponent(url)}&format=json';
    final res = await http.get(Uri.parse(endpoint)).timeout(const Duration(seconds: 10));
    if (res.statusCode != 200) return null;
    final j = jsonDecode(res.body) as Map<String, dynamic>;
    final videoId = _extractYoutubeId(url);
    return LinkMeta(
      title: (j['title'] as String?) ?? _fallbackTitle(url),
      type: ItemType.youtube,
      author: j['author_name'] as String?,
      thumbnailUrl: videoId != null ? 'https://i.ytimg.com/vi/$videoId/hqdefault.jpg' : null,
      siteName: 'YouTube',
      isVideo: true,
    );
  }

  // ----------------------------------------------------------------- reddit
  /// oEmbed first (works without auth, gives title/author/thumbnail), then
  /// .json for subreddit/score/comments/selftext. Either can fail alone.
  static Future<LinkMeta?> _redditRich(String url) async {
    final canonical = _canonicalReddit(url);
    LinkMeta? base;
    try {
      final oembed = await http
          .get(Uri.parse('https://www.reddit.com/oembed?url=${Uri.encodeComponent(canonical)}'))
          .timeout(const Duration(seconds: 10));
      if (oembed.statusCode == 200) {
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
      // fall through to base
    }
    return base;
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
          final res = await http
              .get(Uri.parse('$c.json'), headers: {'User-Agent': ua, 'Accept': 'application/json'})
              .timeout(const Duration(seconds: 10));
          if (res.statusCode != 200) continue;
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

  // ------------------------------------------------------------- rich page
  /// Full OG + Twitter cards + JSON-LD + article: tags + body excerpt.
  static Future<LinkMeta> _richPage(String url) async {
    final res = await http
        .get(Uri.parse(url), headers: {'User-Agent': _browserUa, 'Accept-Language': 'en-US,en;q=0.9'})
        .timeout(const Duration(seconds: 12));
    if (res.statusCode != 200) {
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
    if (uri.host.contains('youtu.be')) return uri.pathSegments.isNotEmpty ? uri.pathSegments.first : null;
    if (uri.host.contains('music.youtube')) return uri.queryParameters['v'];
    return uri.queryParameters['v'];
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
