/// Parses raw shared text into a usable (url, titleHint).
/// Handles: Google Feed / Discover shares (url wrapped in text or
/// google.com/url?q= redirect), YouTube/Reddit app shares (title + url on
/// separate lines), bare domains, multiple urls (takes first http url).
class ShareParseResult {
  final String? url;
  final String? titleHint;
  const ShareParseResult({this.url, this.titleHint});
}

class ShareParser {
  static final _urlRe = RegExp("https?://[^\\s<>\"'\\]\\)]+", caseSensitive: false);
  static final _trailingPunct = RegExp(r'[.,;:!?)\]]+$');

  static ShareParseResult parse(String raw) {
    final text = raw.trim();
    if (text.isEmpty) return const ShareParseResult();

    // 1. Direct URL match.
    final match = _urlRe.firstMatch(text);
    if (match != null) {
      var url = _clean(match.group(0)!);
      url = _unwrapGoogleRedirect(url);
      final hint = _hintFrom(text, url);
      return ShareParseResult(url: url, titleHint: hint);
    }

    // 2. Bare domain without scheme (e.g. "youtu.be/abc", "reddit.com/r/...").
    final bare = RegExp(r'^[\w-]+(\.[\w-]+)+(/[^\s]*)?$').firstMatch(text.split('\n').first.trim());
    if (bare != null) {
      return ShareParseResult(url: 'https://${bare.group(0)}');
    }

    return const ShareParseResult();
  }

  static String _clean(String u) {
    var out = u.replaceAll(_trailingPunct, '');
    // Google feed sometimes appends tracking after & — keep as-is except
    // unwrap redirect below.
    return out;
  }

  /// Unwrap https://www.google.com/url?q=<real>&... redirects that Google
  /// Discover / Feed shares sometimes produce.
  static String _unwrapGoogleRedirect(String url) {
    try {
      final uri = Uri.parse(url);
      if ((uri.host.contains('google.') || uri.host == 'google.com') &&
          uri.path == '/url' &&
          uri.queryParameters['q'] != null) {
        return uri.queryParameters['q']!;
      }
    } catch (_) {}
    return url;
  }

  /// If shared text has non-URL lines (app title), keep the longest as hint.
  static String? _hintFrom(String fullText, String url) {
    final lines = fullText
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty && !l.contains(url) && !_urlRe.hasMatch(l))
        .toList();
    if (lines.isEmpty) return null;
    lines.sort((a, b) => b.length.compareTo(a.length));
    final hint = lines.first;
    return hint.length > 200 ? hint.substring(0, 200) : hint;
  }
}
