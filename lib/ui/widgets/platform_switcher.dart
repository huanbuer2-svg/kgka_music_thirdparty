import 'package:flutter/material.dart';

import '../../services/platform_preference.dart';
import 'toast.dart';

/// 平台切换弹窗（首页右上角、汽水/网易云等平台首页共用）。
///
/// [onOpenSettings] 不为空时，底部会出现「打开设置」入口。
Future<void> showPlatformSwitcher(
  BuildContext context, {
  VoidCallback? onOpenSettings,
}) async {
  final picked = await showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    backgroundColor: Theme.of(context).colorScheme.surface,
    builder: (sheetContext) {
      final scheme = Theme.of(sheetContext).colorScheme;
      final preference = PlatformPreference.instance;
      return SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
              child: Text(
                '首页与搜索平台',
                style: Theme.of(sheetContext).textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w900,
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text(
                '切换后首页内容和搜索默认平台一起变',
                style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
              ),
            ),
            AnimatedBuilder(
              animation: preference,
              builder: (context, _) => Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final entry in PlatformPreference.labels.entries)
                    ListTile(
                      leading: Icon(
                        PlatformPreference.iconFor(entry.key),
                        color: scheme.primary,
                      ),
                      title: Text(entry.value),
                      trailing: preference.platform == entry.key
                          ? Icon(Icons.check_rounded, color: scheme.primary)
                          : null,
                      onTap: () => Navigator.of(sheetContext).pop(entry.key),
                    ),
                ],
              ),
            ),
            if (onOpenSettings != null) ...[
              const Divider(height: 1),
              ListTile(
                leading: Icon(Icons.settings_rounded,
                    color: scheme.onSurfaceVariant),
                title: const Text('打开设置'),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () => Navigator.of(sheetContext).pop('__settings__'),
              ),
            ],
          ],
        ),
      );
    },
  );
  if (!context.mounted || picked == null) return;
  if (picked == '__settings__') {
    onOpenSettings?.call();
    return;
  }
  await PlatformPreference.instance.set(picked);
  if (!context.mounted) return;
  Toast.success(
    '已切换到 ${PlatformPreference.labels[picked] ?? picked}',
  );
}
