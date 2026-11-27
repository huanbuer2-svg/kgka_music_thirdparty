import 'package:flutter/material.dart';

import '../../controllers/auth_controller.dart';
import '../../services/platform_accounts.dart';
import '../design_tokens.dart';

/// 账号登录页：管理各第三方平台的登录态。
///
/// 酷狗走 App 内已有的扫码登录；其余三家（网易云 / QQ / B 站）目前
/// 用「粘贴 Cookie」的方式接入——它们的扫码接口需要各家 appid 与签名，
/// 而 Cookie 在浏览器里是现成的，贴进来就能用。
class AccountsPage extends StatefulWidget {
  const AccountsPage({super.key, required this.auth});

  final AuthController auth;

  @override
  State<AccountsPage> createState() => _AccountsPageState();
}

class _AccountsPageState extends State<AccountsPage> {
  final _store = PlatformAccountStore.instance;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    await _store.ensureLoaded();
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _edit(PlatformAccount account) async {
    final controller = TextEditingController(
      text: _store.cookieOf(account) ?? '',
    );
    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('${account.label} · Cookie'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '在浏览器打开 ${account.label} 网页版并登录，'
              '按 F12 → Network → 任意请求 → 复制请求头里的 Cookie，'
              '整段粘到这里。',
              style: const TextStyle(fontSize: 12, height: 1.5),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              maxLines: 4,
              minLines: 3,
              style: const TextStyle(fontSize: 12),
              decoration: const InputDecoration(
                hintText: 'name1=value1; name2=value2; ...',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          if (_store.isLoggedIn(account))
            TextButton(
              onPressed: () async {
                await _store.clear(account);
                if (ctx.mounted) Navigator.pop(ctx, true);
              },
              child: const Text('清除'),
            ),
          FilledButton(
            onPressed: () async {
              await _store.save(account, controller.text);
              if (ctx.mounted) Navigator.pop(ctx, true);
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (saved == true && mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('账号登录')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 40),
              children: [
                Padding(
                  padding: const EdgeInsets.only(left: 4, bottom: 10),
                  child: Text(
                    '账号',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
                Container(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(AppRadius.lg),
                    color: scheme.surfaceContainerHighest.withValues(
                      alpha: 0.4,
                    ),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: Column(
                    children: [
                      for (var i = 0;
                          i < PlatformAccount.values.length;
                          i++) ...[
                        if (i > 0)
                          Divider(
                            height: 1,
                            indent: 64,
                            color: scheme.outlineVariant.withValues(
                              alpha: 0.3,
                            ),
                          ),
                        AnimatedBuilder(
                          animation: widget.auth,
                          builder: (context, _) {
                            final account = PlatformAccount.values[i];
                            return _AccountTile(
                              account: account,
                              loggedIn: account == PlatformAccount.kugou
                                  ? widget.auth.isLoggedIn
                                  : _store.isLoggedIn(account),
                              onTap: () => _edit(account),
                            );
                          },
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 18),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  child: Text(
                    '说明：酷狗是主账号，在「设置 → 账号」里扫码登录；'
                    '其余平台的 Cookie 只保存在本机，用来给你的搜索请求带上登录态。',
                    style: TextStyle(
                      fontSize: 11.5,
                      height: 1.6,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
    );
  }
}

class _AccountTile extends StatelessWidget {
  const _AccountTile({
    required this.account,
    required this.loggedIn,
    required this.onTap,
  });

  final PlatformAccount account;
  final bool loggedIn;
  final VoidCallback onTap;

  static const Map<PlatformAccount, Color> _colors = {
    PlatformAccount.netease: Color(0xFFE60026),
    PlatformAccount.qq: Color(0xFF31C27C),
    PlatformAccount.kugou: Color(0xFF2CA2F0),
    PlatformAccount.bilibili: Color(0xFFFB7299),
  };

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = _colors[account] ?? scheme.primary;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        child: Row(
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: color,
                borderRadius: BorderRadius.circular(11),
              ),
              child: Icon(
                account == PlatformAccount.bilibili
                    ? Icons.live_tv_rounded
                    : Icons.music_note_rounded,
                size: 20,
                color: Colors.white,
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    account.label,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    loggedIn ? '已登录' : account.hint,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11.5,
                      color: loggedIn ? scheme.primary : scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            Text(
              loggedIn ? '退出' : '登录',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: loggedIn ? scheme.error : scheme.primary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
