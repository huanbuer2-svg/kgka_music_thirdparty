import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 默认搜索平台偏好。
///
/// 首页右上角的「平台切换」改的就是它，搜索页打开时会按这里的值预选平台。
/// 只收录**真正能搜到内容**的平台：汽水音乐没有公开搜索接口，不在列表里。
class PlatformPreference extends ChangeNotifier {
  PlatformPreference._();

  static final PlatformPreference instance = PlatformPreference._();

  static const String _key = 'settings.default_search_platform';

  /// 平台键 → 展示名。键与搜索页的 `_SearchPlatform.name` 保持一致。
  static const Map<String, String> labels = {
    'kugou': '酷狗',
    'netease': '网易云',
    'qq': 'QQ音乐',
    'qishui': '汽水',
  };

  String _platform = 'kugou';
  bool _initialized = false;

  String get platform => _platform;

  bool get isInitialized => _initialized;

  String get label => labels[_platform] ?? _platform;

  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final stored = prefs.getString(_key);
      if (stored != null && labels.containsKey(stored)) {
        _platform = stored;
        notifyListeners();
      }
    } catch (error) {
      debugPrint('[KA Music][platform] 读取默认平台失败: $error');
    }
  }

  Future<void> set(String value) async {
    if (!labels.containsKey(value) || value == _platform) return;
    _platform = value;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_key, value);
    } catch (error) {
      debugPrint('[KA Music][platform] 保存默认平台失败: $error');
    }
  }
}
