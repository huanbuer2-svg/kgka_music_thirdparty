import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 第三方平台账号（除主账号酷狗外的那些）。
///
/// 目前这四家都走「粘贴 Cookie」这一条路：
/// 各家扫码登录的接口都要额外的 appid / 签名，而 Cookie 是浏览器里现成的，
/// 粘进来就能直接用（请求时带上即可）。
enum PlatformAccount {
  netease('netease', '网易云音乐', '用于网易云歌单搜索、私人漫游'),
  qq('qq', 'QQ 音乐', '用于 QQ 歌单搜索（搜索接口需要登录态）'),
  kugou('kugou', '酷狗音乐', '主账号，可在上方直接扫码登录'),
  bilibili('bilibili', '哔哩哔哩', '用于同步收藏夹');

  const PlatformAccount(this.key, this.label, this.hint);

  final String key;
  final String label;
  final String hint;
}

/// 账号 Cookie 的读写。只存字符串，key 形如 `ka_account_qq`。
class PlatformAccountStore {
  PlatformAccountStore._();
  static final PlatformAccountStore instance = PlatformAccountStore._();

  static const _prefix = 'ka_account_';
  final Map<String, String> _cache = {};
  bool _loaded = false;

  Future<void> ensureLoaded() async {
    if (_loaded) return;
    final prefs = await SharedPreferences.getInstance();
    for (final account in PlatformAccount.values) {
      final value = prefs.getString('$_prefix${account.key}');
      if (value != null && value.isNotEmpty) {
        _cache[account.key] = value;
      }
    }
    _loaded = true;
  }

  String? cookieOf(PlatformAccount account) => _cache[account.key];

  bool isLoggedIn(PlatformAccount account) {
    final value = _cache[account.key];
    return value != null && value.trim().isNotEmpty;
  }

  Future<void> save(PlatformAccount account, String cookie) async {
    final trimmed = cookie.trim();
    final prefs = await SharedPreferences.getInstance();
    if (trimmed.isEmpty) {
      _cache.remove(account.key);
      await prefs.remove('$_prefix${account.key}');
    } else {
      _cache[account.key] = trimmed;
      await prefs.setString('$_prefix${account.key}', trimmed);
    }
  }

  Future<void> clear(PlatformAccount account) => save(account, '');

  /// 从整段浏览器 Cookie 里挑出某个 key 的值（QQ 音乐搜索要的是 qm_keyst）。
  static String? pickCookieValue(String rawCookie, String key) {
    for (final part in rawCookie.split(';')) {
      final trimmed = part.trim();
      if (trimmed.startsWith('$key=')) {
        return trimmed.substring(key.length + 1);
      }
    }
    return null;
  }
}

/// 调试用：把 cookie 打码后写日志，避免明文进 logcat。
String maskCookie(String cookie) {
  if (cookie.length <= 12) return '***';
  return '${cookie.substring(0, 6)}...${cookie.substring(cookie.length - 4)}'
      '（${cookie.length} 字符）';
}

/// 保留：将来接扫码登录时用。
@visibleForTesting
String encodeAccountPayload(Map<String, String> data) => jsonEncode(data);

/// 简单判断当前是不是桌面端（Cookie 粘贴主要在桌面/手机浏览器里取）。
bool get isMobilePlatform => Platform.isAndroid || Platform.isIOS;
