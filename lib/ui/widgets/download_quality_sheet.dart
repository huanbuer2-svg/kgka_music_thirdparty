import 'package:flutter/material.dart';

import '../../models/music_models.dart';
import '../../services/custom_source/lx_script.dart';
import '../design_tokens.dart';

/// 下载音质选项。
///
/// 官方接口只到无损，`FLAC 24 位 / Hi-Res / Atmos / Atmos+ / Master`
/// 这几档必须由第三方音源脚本提供，所以每项同时记录「官方兜底档位」和
/// 「第三方档位」：拿不到第三方地址时退回官方对应档位，而不是直接失败。
class DownloadQualityChoice {
  const DownloadQualityChoice(
    this.label, {
    required this.official,
    this.thirdParty,
    this.hint,
  });

  final String label;

  /// 官方接口用的档位（也是本地缓存归类用的档位）。
  final AudioQuality official;

  /// 第三方脚本音质档位；为空表示只用官方接口。
  final ThirdPartyQuality? thirdParty;

  final String? hint;

  bool get requiresThirdParty => thirdParty != null;
}

const List<DownloadQualityChoice> kDownloadQualityChoices = [
  DownloadQualityChoice('128k', official: AudioQuality.standard),
  DownloadQualityChoice('320k', official: AudioQuality.high),
  DownloadQualityChoice('无损 FLAC', official: AudioQuality.lossless),
  DownloadQualityChoice(
    'FLAC 24 位',
    official: AudioQuality.lossless,
    thirdParty: ThirdPartyQuality.bit24,
  ),
  DownloadQualityChoice(
    'Hi-Res',
    official: AudioQuality.lossless,
    thirdParty: ThirdPartyQuality.hiRes,
  ),
  DownloadQualityChoice(
    'Atmos',
    official: AudioQuality.lossless,
    thirdParty: ThirdPartyQuality.atmos,
  ),
  DownloadQualityChoice(
    'Atmos+',
    official: AudioQuality.lossless,
    thirdParty: ThirdPartyQuality.atmosPlus,
  ),
  DownloadQualityChoice(
    'Master',
    official: AudioQuality.lossless,
    thirdParty: ThirdPartyQuality.master,
  ),
];

/// 弹出下载音质选择（iOS ActionSheet 风格：标题 + 选项列表 + 取消）。
///
/// [thirdPartyAvailable] 为 false 时，需要第三方音源的档位置灰并说明原因。
Future<DownloadQualityChoice?> showDownloadQualitySheet({
  required BuildContext context,
  required String songTitle,
  required bool thirdPartyAvailable,
}) {
  return showModalBottomSheet<DownloadQualityChoice>(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    builder: (sheetContext) {
      final theme = Theme.of(sheetContext);
      final scheme = theme.colorScheme;
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                decoration: BoxDecoration(
                  color: scheme.surface,
                  borderRadius: BorderRadius.circular(AppRadius.lg),
                ),
                clipBehavior: Clip.antiAlias,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 14, 20, 12),
                      child: Text(
                        '下载《$songTitle》',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 12.5,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                    for (final choice in kDownloadQualityChoices) ...[
                      Divider(height: 1, color: scheme.outlineVariant.withValues(alpha: 0.4)),
                      _QualityRow(
                        choice: choice,
                        enabled: !choice.requiresThirdParty || thirdPartyAvailable,
                        onTap: () => Navigator.of(sheetContext).pop(choice),
                      ),
                    ],
                  ],
                ),
              ),
              if (!thirdPartyAvailable) ...[
                const SizedBox(height: 8),
                Text(
                  'FLAC 24 位及以上需要先在「设置 → 音源与音质」导入第三方音源',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 11.5,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: Material(
                  color: scheme.surface,
                  borderRadius: BorderRadius.circular(AppRadius.lg),
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(
                    onTap: () => Navigator.of(sheetContext).pop(),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      child: Text(
                        '取消',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          color: scheme.primary,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}

class _QualityRow extends StatelessWidget {
  const _QualityRow({
    required this.choice,
    required this.enabled,
    required this.onTap,
  });

  final DownloadQualityChoice choice;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = enabled ? scheme.primary : scheme.onSurfaceVariant.withValues(alpha: 0.45);
    return InkWell(
      onTap: enabled ? onTap : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 15, horizontal: 20),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              choice.label,
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w500,
                color: color,
              ),
            ),
            if (choice.requiresThirdParty) ...[
              const SizedBox(width: 6),
              Icon(Icons.auto_awesome_rounded, size: 13, color: color.withValues(alpha: 0.7)),
            ],
          ],
        ),
      ),
    );
  }
}
