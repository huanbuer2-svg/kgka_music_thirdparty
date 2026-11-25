import 'package:flutter/material.dart';

import '../../controllers/auth_controller.dart';
import '../../services/platform_preference.dart';

/// 平台首页的统一头部。
///
/// 左边是当前平台的徽标（点一下切平台），右边是用户头像，
/// 下面接问候语与副标题——跟各家原生 App 的首页顶部一个路子。
///
/// 之所以要单独抽出来：各平台首页都是独立页面，头部却长得一样，
/// 而且必须自己处理状态栏 inset（父级是 ListView，不带 SafeArea）。
class PlatformHomeHeader extends StatelessWidget {
  const PlatformHomeHeader({
    super.key,
    required this.platformKey,
    required this.auth,
    this.subtitle,
    this.onSwitchPlatform,
    this.onTapAvatar,
  });

  final String platformKey;
  final AuthController auth;
  final String? subtitle;
  final VoidCallback? onSwitchPlatform;
  final VoidCallback? onTapAvatar;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            _PlatformBadge(platformKey: platformKey, onTap: onSwitchPlatform),
            const Spacer(),
            _AvatarButton(auth: auth, onTap: onTapAvatar),
          ],
        ),
        const SizedBox(height: 26),
        Text(
          _greeting(),
          style: Theme.of(context).textTheme.headlineMedium?.copyWith(
            fontWeight: FontWeight.w900,
            letterSpacing: -0.6,
          ),
        ),
        if (subtitle != null && subtitle!.isNotEmpty) ...[
          const SizedBox(height: 5),
          Text(
            subtitle!,
            style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant),
          ),
        ],
      ],
    );
  }

  String _greeting() {
    final hour = DateTime.now().hour;
    if (hour < 6) return '夜深了';
    if (hour < 12) return '早上好';
    if (hour < 18) return '下午好';
    return '晚上好';
  }
}

/// 平台徽标：圆角方块 + 平台色 + 图标，点一下就是切换入口。
class _PlatformBadge extends StatelessWidget {
  const _PlatformBadge({required this.platformKey, this.onTap});

  final String platformKey;
  final VoidCallback? onTap;

  static const Map<String, Color> _colors = {
    'kugou': Color(0xFF2CA2F0),
    'netease': Color(0xFFE60026),
    'qq': Color(0xFF31C27C),
    'qishui': Color(0xFF1A1A1E),
  };

  static const Map<String, IconData> _icons = {
    'kugou': Icons.music_note_rounded,
    'netease': Icons.cloud_rounded,
    'qq': Icons.album_rounded,
    'qishui': Icons.waves_rounded,
  };

  @override
  Widget build(BuildContext context) {
    final color = _colors[platformKey] ?? Theme.of(context).colorScheme.primary;
    final icon = _icons[platformKey] ?? Icons.music_note_rounded;
    return Tooltip(
      message: onTap == null ? '' : '切换平台（当前 ${PlatformPreference.labels[platformKey] ?? platformKey}）',
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Container(
          width: 38,
          height: 38,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(12),
            boxShadow: [
              BoxShadow(
                color: color.withValues(alpha: 0.32),
                blurRadius: 12,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Icon(icon, size: 21, color: Colors.white),
        ),
      ),
    );
  }
}

class _AvatarButton extends StatelessWidget {
  const _AvatarButton({required this.auth, this.onTap});

  final AuthController auth;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AnimatedBuilder(
      animation: auth,
      builder: (context, _) {
        final url = auth.profile?.avatarUrl;
        return GestureDetector(
          onTap: onTap,
          behavior: HitTestBehavior.opaque,
          child: Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: scheme.surfaceContainerHighest,
              border: Border.all(
                color: scheme.outlineVariant.withValues(alpha: 0.5),
              ),
            ),
            clipBehavior: Clip.antiAlias,
            child: (url == null || url.isEmpty)
                ? Icon(Icons.person_rounded,
                    size: 20, color: scheme.onSurfaceVariant)
                : Image.network(
                    url,
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => Icon(
                      Icons.person_rounded,
                      size: 20,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
          ),
        );
      },
    );
  }
}
