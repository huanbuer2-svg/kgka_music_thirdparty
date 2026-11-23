import 'dart:async';
import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../services/custom_source/custom_source_manager.dart';
import '../../services/custom_source/lx_runtime.dart';
import '../../services/custom_source/lx_script.dart';
import '../design_tokens.dart';
import '../widgets/toast.dart';

/// 第三方音源（lx-music 自定义源）管理页。
///
/// 结构对应 lx-music 桌面版的「自定义源」：导入脚本 → 看到它声明支持哪些
/// 平台 → 在播放时按优先级挑一个能用的脚本取地址。
class CustomSourcePage extends StatefulWidget {
  const CustomSourcePage({super.key});

  @override
  State<CustomSourcePage> createState() => _CustomSourcePageState();
}

class _CustomSourcePageState extends State<CustomSourcePage> {
  final CustomSourceManager _manager = CustomSourceManager.instance;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    unawaited(_manager.init());
  }

  // ------------------------------------------------------------------- 导入
  Future<void> _runImport(
    Future<Object?> Function() action,
    String successText,
  ) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
      if (!mounted) return;
      Toast.success(successText);
    } catch (error) {
      if (!mounted) return;
      Toast.error(error is LxRuntimeException ? error.message : '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _importFromUrl() async {
    final controller = TextEditingController();
    final url = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('从链接导入'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '支持 lx-music 格式的音源脚本地址，GitHub / Gitee / GitLab 的网页链接会自动转成下载地址。',
              style: TextStyle(fontSize: 12.5),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              autofocus: true,
              maxLines: 3,
              minLines: 1,
              decoration: const InputDecoration(
                hintText: 'https://github.com/user/repo/blob/main/xxx.js',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(controller.text.trim()),
            child: const Text('导入'),
          ),
        ],
      ),
    );
    if (url == null || url.isEmpty) return;
    await _runImport(() => _manager.importFromUrl(url), '音源已导入');
  }

  Future<void> _importFromFile() async {
    final picked = await FilePicker.pickFile(
      dialogTitle: '选择音源脚本',
      type: FileType.any,
    );
    if (picked == null) return;
    try {
      final bytes = await picked.readAsBytes();
      final text = utf8.decode(bytes, allowMalformed: true);
      if (!text.contains('lx') && !text.contains('EVENT_NAMES')) {
        throw LxRuntimeException('文件内容不像 lx-music 音源脚本');
      }
      await _runImport(
        () => _manager.importFromText(text, fallbackName: picked.name),
        '音源已导入',
      );
    } catch (error) {
      if (!mounted) return;
      Toast.error(error is LxRuntimeException ? error.message : '$error');
    }
  }

  Future<void> _importFromPaste() async {
    final controller = TextEditingController();
    final code = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('粘贴脚本内容'),
        content: SizedBox(
          width: 520,
          child: TextField(
            controller: controller,
            maxLines: 12,
            minLines: 6,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            decoration: const InputDecoration(
              hintText: '把 xxx音源.js 的全部内容粘贴到这里',
              border: OutlineInputBorder(),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(controller.text),
            child: const Text('导入'),
          ),
        ],
      ),
    );
    if (code == null || code.trim().isEmpty) return;
    await _runImport(() => _manager.importFromText(code), '音源已导入');
  }

  Future<void> _confirmDelete(CustomSourceScript script) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('删除「${script.name}」？'),
        content: const Text('删除后需要重新导入才能使用这个音源。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(dialogContext).colorScheme.error,
            ),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _manager.remove(script.id);
    if (!mounted) return;
    Toast.info('已删除 ${script.name}');
  }

  void _showLogs() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      builder: (sheetContext) => SizedBox(
        height: MediaQuery.of(sheetContext).size.height * 0.7,
        child: AnimatedBuilder(
          animation: _manager,
          builder: (context, _) {
            final logs = _manager.recentLogs;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 12, 8),
                  child: Row(
                    children: [
                      Text(
                        '音源运行日志',
                        style: Theme.of(sheetContext).textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                      const Spacer(),
                      TextButton(
                        onPressed: _manager.clearLogs,
                        child: const Text('清空'),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: logs.isEmpty
                      ? const Center(child: Text('还没有日志，播放一首歌试试'))
                      : ListView.builder(
                          padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
                          itemCount: logs.length,
                          itemBuilder: (context, index) {
                            final line = logs[logs.length - 1 - index];
                            return Padding(
                              padding: const EdgeInsets.symmetric(vertical: 3),
                              child: Text(
                                line,
                                style: TextStyle(
                                  fontSize: 12,
                                  fontFamily: 'monospace',
                                  color: line.contains('失败')
                                      ? Theme.of(context).colorScheme.error
                                      : Theme.of(context).colorScheme.onSurfaceVariant,
                                ),
                              ),
                            );
                          },
                        ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  // --------------------------------------------------------------------- UI
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('第三方音源'),
        actions: [
          IconButton(
            tooltip: '运行日志',
            onPressed: _showLogs,
            icon: const Icon(Icons.receipt_long_rounded),
          ),
        ],
      ),
      body: AnimatedBuilder(
        animation: _manager,
        builder: (context, _) {
          final scripts = _manager.scripts;
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
            children: [
              if (_busy) const LinearProgressIndicator(minHeight: 2),
              _buildModeCard(context),
              const SizedBox(height: AppSpacing.lg),
              _buildImportRow(context),
              const SizedBox(height: AppSpacing.lg),
              Row(
                children: [
                  Text(
                    '已导入音源',
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '${scripts.length}',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const Spacer(),
                  if (scripts.length > 1)
                    Text(
                      '长按拖动可调优先级',
                      style: TextStyle(
                        fontSize: 11,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                ],
              ),
              const SizedBox(height: AppSpacing.sm),
              if (scripts.isEmpty)
                _buildEmptyCard(context)
              else
                ReorderableListView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  buildDefaultDragHandles: false,
                  itemCount: scripts.length,
                  onReorder: (oldIndex, newIndex) =>
                      _manager.reorder(oldIndex, newIndex),
                  itemBuilder: (context, index) {
                    final script = scripts[index];
                    return Padding(
                      key: ValueKey(script.id),
                      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                      child: _buildScriptCard(context, script, index),
                    );
                  },
                ),
              const SizedBox(height: AppSpacing.lg),
              Text(
                '说明\n'
                '· 音源脚本来自第三方，是否可用取决于脚本作者的服务端，与 App 无关。\n'
                '· 「官方优先」只在官方接口取不到播放地址时才使用第三方音源；'
                '「第三方优先」则相反，适合网易云歌曲想要更高音质的场景。\n'
                '· 脚本运行在 App 内置的 JS 引擎里，只能通过脚本自带的请求接口联网，'
                '不会读写你的本地文件。\n'
                '· 请自行确认脚本来源合法，音乐版权归各平台与原作者所有。',
                style: TextStyle(
                  fontSize: 11.5,
                  height: 1.7,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildModeCard(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      elevation: 0,
      color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.extension_rounded, color: scheme.primary, size: 20),
                const SizedBox(width: 8),
                Text(
                  '启用的音源',
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              _modeDescription(_manager.mode),
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final mode in CustomSourceMode.values)
                  ChoiceChip(
                    label: Text(mode.label),
                    selected: _manager.mode == mode,
                    onSelected: (selected) {
                      if (!selected) return;
                      unawaited(_manager.setMode(mode));
                    },
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  String _modeDescription(CustomSourceMode mode) {
    switch (mode) {
      case CustomSourceMode.off:
        return '不使用任何第三方音源，全部走官方接口。';
      case CustomSourceMode.fallback:
        return '官方接口拿不到播放地址时，才用第三方音源兜底。';
      case CustomSourceMode.prefer:
        return '先问第三方音源，成功了就用它；失败再回退官方接口。';
      case CustomSourceMode.only:
        return '只用第三方音源，解析失败直接报错（不影响已下载的歌曲）。';
    }
  }

  Widget _buildImportRow(BuildContext context) {
    return Wrap(
      spacing: AppSpacing.sm,
      runSpacing: AppSpacing.sm,
      children: [
        FilledButton.tonalIcon(
          onPressed: _busy ? null : _importFromUrl,
          icon: const Icon(Icons.link_rounded, size: 18),
          label: const Text('从链接导入'),
        ),
        FilledButton.tonalIcon(
          onPressed: _busy ? null : _importFromFile,
          icon: const Icon(Icons.folder_open_rounded, size: 18),
          label: const Text('从文件导入'),
        ),
        FilledButton.tonalIcon(
          onPressed: _busy ? null : _importFromPaste,
          icon: const Icon(Icons.content_paste_rounded, size: 18),
          label: const Text('粘贴脚本'),
        ),
      ],
    );
  }

  Widget _buildEmptyCard(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      elevation: 0,
      color: scheme.surfaceContainerHighest.withValues(alpha: 0.4),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            Icon(Icons.extension_off_rounded, size: 36, color: scheme.onSurfaceVariant),
            const SizedBox(height: 10),
            Text(
              '还没有导入音源',
              style: TextStyle(fontWeight: FontWeight.w700, color: scheme.onSurface),
            ),
            const SizedBox(height: 6),
            Text(
              '支持 lx-music 格式的自定义源脚本，导入后可在官方接口取不到地址时兜底播放。',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildScriptCard(
    BuildContext context,
    CustomSourceScript script,
    int index,
  ) {
    final scheme = Theme.of(context).colorScheme;
    final failed = script.loadError != null;
    final labels = script.sourceLabels;

    final subtitle = StringBuffer();
    if (failed) {
      subtitle.write('加载失败：${script.loadError}');
    } else if (labels.isEmpty) {
      subtitle.write('未声明可用平台');
    } else {
      subtitle.write('支持 ${labels.join(' / ')}');
    }
    final meta = <String>[
      if (script.version.isNotEmpty) 'v${script.version.replaceFirst('v', '')}',
      if (script.author.isNotEmpty) script.author,
      '${(script.sizeInBytes / 1024).toStringAsFixed(1)} KB',
    ];
    if (meta.isNotEmpty) subtitle.write(' · ${meta.join(' · ')}');

    return Card(
      elevation: 0,
      color: scheme.surfaceContainerHighest.withValues(alpha: 0.35),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 6, 12),
        child: Row(
          children: [
            ReorderableDragStartListener(
              index: index,
              child: Padding(
                padding: const EdgeInsets.only(right: 6),
                child: Icon(Icons.drag_indicator_rounded, color: scheme.outline),
              ),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          script.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                      ),
                      if (failed) ...[
                        const SizedBox(width: 6),
                        Icon(Icons.error_outline_rounded, size: 16, color: scheme.error),
                      ],
                    ],
                  ),
                  const SizedBox(height: 3),
                  Text(
                    subtitle.toString(),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11.5,
                      height: 1.45,
                      color: failed ? scheme.error : scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            Switch(
              value: script.enabled,
              onChanged: (value) => _manager.setEnabled(script.id, value),
            ),
            PopupMenuButton<String>(
              tooltip: '更多',
              onSelected: (action) {
                switch (action) {
                  case 'reload':
                    unawaited(_reload(script));
                    break;
                  case 'delete':
                    unawaited(_confirmDelete(script));
                    break;
                }
              },
              itemBuilder: (context) => [
                const PopupMenuItem(value: 'reload', child: Text('重新加载')),
                const PopupMenuItem(value: 'delete', child: Text('删除')),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _reload(CustomSourceScript script) async {
    setState(() => _busy = true);
    try {
      await _manager.reload(script.id);
      final latest = _manager.scripts.firstWhere(
        (item) => item.id == script.id,
        orElse: () => script,
      );
      if (!mounted) return;
      if (latest.loadError != null) {
        Toast.error('加载失败：${latest.loadError}');
      } else {
        Toast.success('${latest.name} 已重新加载');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}
