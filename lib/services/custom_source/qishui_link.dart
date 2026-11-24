import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// 汽水音乐的一首歌引用。
class QishuiTrackRef {
  const QishuiTrackRef({required this.id, this.title, this.artist});

  /// 汽水的 trackId，直接作为脚本侧 `qs` 平台的 `songmid`。
  final String id;

  /// 从分享页 HTML 里顺带抓到的歌名，可能为空。
  final String? title;

  /// 分享页标题里的艺人（`《歌名》@艺人`），可能为空。
  final String? artist;
}

/// 汽水音乐没有公开搜索接口，任何音频解析都只能从「已知 trackId」出发。
///
/// 这个解析器负责把用户手动粘贴的内容变成 trackId，尽量兼容：
/// - 纯 ID（`7xxxxxxxxxxxxxxxxxx`）
/// - 完整分享链接（`https://qishui.douyin.com/s/xxxx/`）
/// - 整段分享文案（"分享单曲: xxx https://... "）
class QishuiLinkParser {
  QishuiLinkParser._();

  static const Duration _timeout = Duration(seconds: 15);

  /// 分享链接里可能承载 trackId 的参数名。
  static const List<String> _queryKeys = [
    'track_id',
    'trackId',
    'trackID',
    'item_id',
    'itemId',
    'music_id',
    'musicId',
    'id',
  ];

  /// 只由字母数字下划线横线组成的短串，直接当成 ID。
  static final RegExp _bareId = RegExp(r'^[A-Za-z0-9_-]{6,80}$');

  /// 文本里出现的第一个链接。
  static final RegExp _urlInText = RegExp(r'https?://[^\s，,、。）)】\]"<>]+');

  /// 页面/JSON 里内嵌的 ID 字段。
  static final RegExp _embeddedId = RegExp(
    r'"(?:track_?id|trackId|trackID|item_?id|itemId|music_?id|musicId)"\s*:\s*"?([A-Za-z0-9_-]{6,80})"?',
    caseSensitive: false,
  );

  /// 解析用户粘贴的内容。解析不出来返回 null。
  /// [fetchTitle] 为 false 时跳过抓歌名的网络请求（单测用）。
  static Future<QishuiTrackRef?> parse(String raw, {bool fetchTitle = true}) async {
    final text = raw.trim();
    if (text.isEmpty) return null;

    if (_bareId.hasMatch(text)) {
      return QishuiTrackRef(id: text);
    }

    final urlMatch = _urlInText.firstMatch(text);
    if (urlMatch == null) return null;
    final url = urlMatch.group(0)!;
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasScheme) return null;

    // 链接本身就带参数：id 有了，但仍去落地页抓一次歌名，
    // 否则播放列表里只能显示「汽水音乐」这个占位名
    final direct = _extractFromUri(uri);
    if (direct != null) {
      final meta = fetchTitle ? await _fetchMeta(uri) : null;
      return QishuiTrackRef(
        id: direct,
        title: meta?.title,
        artist: meta?.artist,
      );
    }

    return _resolveShortLink(uri);
  }

  /// 跟随跳转拿到真实地址后再提取；顺便从落地页 HTML 里找内嵌 ID。
  static Future<QishuiTrackRef?> _resolveShortLink(Uri uri) async {
    final client = http.Client();
    try {
      final response = await client
          .get(
            uri,
            headers: const {
              'User-Agent':
                  'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) '
                      'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 '
                      'Mobile/15E148 Safari/604.1',
            },
          )
          .timeout(_timeout);
      final finalUri = response.request?.url ?? uri;
      final fromUri = _extractFromUri(finalUri);
      if (fromUri != null) return QishuiTrackRef(id: fromUri);

      final body = utf8.decode(response.bodyBytes, allowMalformed: true);
      final embedded = _embeddedId.firstMatch(body);
      if (embedded != null) {
        final meta = _extractMetaFromHtml(body);
        return QishuiTrackRef(
          id: embedded.group(1)!,
          title: meta?.title,
          artist: meta?.artist,
        );
      }
      // 路径末段是长数字的情况（部分落地页形如 /share/track/7123456789）
      final pathId = _extractFromPath(finalUri);
      if (pathId != null) return QishuiTrackRef(id: pathId);
      return null;
    } catch (error) {
      debugPrint('[KA Music][qishui] 解析分享链接失败: $error');
      return null;
    } finally {
      client.close();
    }
  }

  /// 只为了拿歌名/艺人的一次请求；失败静默，不影响播放。
  static Future<({String? title, String? artist})?> _fetchMeta(Uri uri) async {
    final client = http.Client();
    try {
      final response = await client
          .get(
            uri,
            headers: const {
              'User-Agent':
                  'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) '
                      'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 '
                      'Mobile/15E148 Safari/604.1',
            },
          )
          .timeout(const Duration(seconds: 8));
      final body = utf8.decode(response.bodyBytes, allowMalformed: true);
      final finalUri = response.request?.url ?? uri;
      return _extractMetaFromHtml(body) ??
          _extractMetaFromUri(finalUri) ??
          _extractMetaFromUri(uri);
    } catch (error) {
      debugPrint('[KA Music][qishui] 抓取歌名失败: $error');
      return null;
    } finally {
      client.close();
    }
  }

  static String? _extractFromUri(Uri uri) {
    for (final key in _queryKeys) {
      final value = uri.queryParameters[key];
      if (value != null && value.trim().isNotEmpty) return value.trim();
    }
    // 有些链接把 ID 放在 fragment 里
    if (uri.fragment.isNotEmpty) {
      final fragmentUri = Uri.tryParse(uri.fragment);
      if (fragmentUri != null) {
        for (final key in _queryKeys) {
          final value = fragmentUri.queryParameters[key];
          if (value != null && value.trim().isNotEmpty) return value.trim();
        }
      }
    }
    return _extractFromPath(uri);
  }

  static String? _extractFromPath(Uri uri) {
    for (final segment in uri.pathSegments.reversed) {
      if (RegExp(r'^\d{8,}$').hasMatch(segment)) return segment;
    }
    return null;
  }

  /// 依次尝试 JSON 字段 → og:title → `<title>`。
  ///
  /// 汽水分享页的真实标题形如 `《晴天》@周杰伦`，
  /// 猜错格式会把「@汽水音乐」一起抓进歌名，所以要按实际页面来解析。
  static ({String? title, String? artist})? _extractMetaFromHtml(String html) {
    final jsonMatch = RegExp(
      r'"(?:track_?name|song_?name|title|name)"\s*:\s*"([^"]{1,80})"',
      caseSensitive: false,
    ).firstMatch(html);
    if (jsonMatch != null) {
      final meta = _parseShareTitle(jsonMatch.group(1)!);
      if (meta != null) return meta;
    }

    final ogMatch = RegExp(
      r'<meta[^>]+(?:property|name)=["\x27]og:title["\x27][^>]+content=["\x27]([^"\x27]{1,100})',
      caseSensitive: false,
    ).firstMatch(html);
    if (ogMatch != null) {
      final meta = _parseShareTitle(ogMatch.group(1)!);
      if (meta != null) return meta;
    }

    final titleMatch = RegExp(
      r'<title[^>]*>([^<]{1,100})</title>',
      caseSensitive: false,
    ).firstMatch(html);
    if (titleMatch != null) return _parseShareTitle(titleMatch.group(1)!);
    return null;
  }

  /// 把 `《歌名》@艺人` / `歌名 - 汽水音乐` 这类站点标题拆成歌名 + 艺人。
  static ({String? title, String? artist})? _parseShareTitle(String raw) {
    var text = raw.trim();
    if (text.isEmpty) return null;
    text = text
        .replaceAll('&quot;', '"')
        .replaceAll('&amp;', '&')
        .replaceAll('&#39;', "'");

    final bracketed = RegExp(
      r'《\s*([^》]{1,60}?)\s*》\s*(?:@\s*([^@\s]{1,40}))?',
    ).firstMatch(text);
    if (bracketed != null) {
      final title = bracketed.group(1)?.trim();
      var artist = bracketed.group(2)?.trim();
      if (artist == null || artist.isEmpty || artist == '汽水音乐') {
        artist = null;
      }
      if (title == null ||
          title.isEmpty ||
          title == '-' ||
          title == '汽水音乐') {
        return null;
      }
      return (title: title, artist: artist);
    }

    // 没有书名号的退化格式
    text = text.replaceAll(RegExp(r'\s*[@\-_|—·]\s*汽水音乐.*$'), '').trim();
    if (text.isEmpty || text == '汽水音乐' || text == '-') return null;
    return (
      title: text.length > 60 ? text.substring(0, 60) : text,
      artist: null,
    );
  }

  static ({String? title, String? artist})? _extractMetaFromUri(Uri uri) {
    for (final key in const ['title', 'name', 'song_name', 'songName']) {
      final value = uri.queryParameters[key];
      if (value != null && value.trim().isNotEmpty) {
        return _parseShareTitle(Uri.decodeComponent(value));
      }
    }
    return null;
  }

}
