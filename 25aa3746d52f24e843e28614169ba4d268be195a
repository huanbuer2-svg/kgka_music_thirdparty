# 第三方音源（从 KMusic-2026 移植）

在 **kgka_Music_hl（Flutter 酷狗客户端）** 上增加 **lx-music 自定义音源脚本** 能力，
对应 [lover520f/KMusic-2026](https://github.com/lover520f/KMusic-2026) 里的「自定义源」功能。

## 为什么不是直接抄代码

| | KMusic-2026 | 本项目 |
|---|---|---|
| 语言 / 框架 | Swift + SwiftUI | Dart + Flutter |
| 音源脚本执行 | JavaScriptCore（系统框架） | QuickJS / JavaScriptCore（`flutter_js`） |
| 可复用的东西 | **脚本格式、事件协议、字段约定** | 需要按同样协议重新实现宿主 |

KMusic 仓库里真正构成「第三方音源功能」的是 4 个 lx-music 格式脚本
（`ikun音源.js` / `新澜音源.js` / `溯音音源.js` / `落雪音源.js`）。
它们依赖宿主提供 `globalThis.lx`（`EVENT_NAMES` / `on` / `send` / `request` / `utils`），
所以移植的本质是：**在 Flutter 里实现一个和 lx-music 等价的 JS 宿主**，
并把脚本返回的播放地址接进现有播放链路。

## 新增 / 改动的文件

```
lib/services/custom_source/
├── lx_js_bootstrap.dart       # JS 宿主垫片（在引擎里执行的 globalThis.lx 实现）
├── lx_script.dart             # 脚本元信息解析、音源声明、音质档位映射
├── lx_runtime.dart            # 引擎封装：加载脚本、dispatch、HTTP 桥、Promise 泵
└── custom_source_manager.dart # 脚本管理/持久化/优先级/缓存，对外 resolve()
lib/ui/pages/custom_source_page.dart   # 管理界面
test/fixtures/lx_smoke.js              # 不联网的自测音源
test/custom_source_test.dart           # 纯逻辑单测（18 例）
test/custom_source_page_test.dart      # 界面单测（3 例）
test/lx_engine_smoke_test.dart         # 引擎端到端（3 例，无 DLL 时自动跳过）
tool/lx_host_check.cjs                 # Node 侧协议自检（不需要 Flutter）
```

改动点（共 4 处，都很小）：

| 文件 | 改动 |
|---|---|
| `pubspec.yaml` | 增加 `flutter_js: ^0.8.7` |
| `lib/main.dart` | 启动时 `await CustomSourceManager.instance.init()` |
| `lib/ui/pages/settings_page.dart` | 「播放」区新增「第三方音源」入口 + 摘要 |
| `lib/controllers/player_controller.dart` | `_resolvePlayUrl` 拆成「策略包装 + `_resolveOfficialPlayUrl`」，切音质重载也复用同一套解析 |
| `ios/Runner/Info.plist` | 放开 ATS（部分音源只有 http 接口） |
| `macos/Runner/*.entitlements` | 补 `com.apple.security.network.client` |

## 工作原理

```
播放一首歌
   ↓
PlayerController._resolvePlayUrl
   ↓  按策略决定顺序
CustomSourceManager.resolve(song, appQuality)
   ↓  按 order 遍历启用的脚本，找声明了 kg / wy 的那一个
LxRuntime.fetchMusicUrl(source, musicInfo, quality)
   ↓  evaluate: __lxHost.dispatch(payload, callId)
脚本 on(EVENT_NAMES.request) 收到 { action:'musicUrl', source, info }
   ↓  脚本内部 lx.request(url, options, cb)
JS -- sendMessage('lx', {t:'http'}) --> Dart
   ↓  Dart 用 http 包真正发请求（UTF-8 解码、20s 超时）
Dart -- __lxHost.httpResult(id, json) --> JS 回调
   ↓  脚本解析响应、返回播放 URL
Dart 每 20ms executePendingJob() + takeResult(callId) 轮询取结果
   ↓
just_audio 播放（与官方地址完全同一条路径，缓存/下载/歌词都不受影响）
```

### 为什么是「轮询」而不是让 JS `await` 宿主

`flutter_js` 的 `sendMessage` 是 JS 同步调用到 Dart 的单向通道，**无法把 Future 传回 JS**。
`flutter_js` 自己处理 Promise 也是靠定时 `executePendingJob()` 轮询，这里沿用了同样的办法：
结果先写进 JS 侧的 `__lxHost` 槽位，Dart 轮询取走。
好处是不依赖引擎的异步扩展，QuickJS 与 JavaScriptCore 两个实现行为一致。

### 一道必须隔离的坑

脚本普遍在顶层写 `const { EVENT_NAMES, request, on, send } = globalThis.lx`。
同一个 JS 上下文里执行第二个脚本会因**重复声明 const** 直接语法报错，
所以**一个脚本一个 runtime**，`LxRuntime` 与脚本一一对应。

## 使用

1. 设置 → 播放 → **第三方音源**
2. 三种导入方式任一：
   - **从链接导入**：填 lx-music 音源脚本地址；GitHub / Gitee / GitLab 的 `blob` 网页链接会自动转 raw
   - **从文件导入**：选本地 `.js`
   - **粘贴脚本**：直接贴内容
3. 导入时会立刻试跑一次，列表里能看到「支持 酷狗 / 网易云」这种能力声明；失败会标红并给出原因
4. 选策略（默认「官方优先」）：
   - **官方优先**：官方接口取不到地址时才用第三方
   - **第三方优先**：先问第三方，失败回退官方（网易云歌曲想要高音质时用这个）
   - **仅第三方**：只认第三方，失败报错
   - **关闭**：完全不走第三方
5. 播一首该平台的歌，右上角 📋 看运行日志

> 云盘歌曲、本地歌曲不会经过第三方音源。

## 平台与构建依赖

| 平台 | JS 引擎 | 额外要求 |
|---|---|---|
| Android | QuickJS | 插件通过 jitpack 拉 `fastdev-jsruntimes-quickjs`，构建机需能访问 jitpack.io |
| iOS / macOS | 系统 JavaScriptCore | 无 |
| Windows | QuickJS | 插件自带 `quickjs_c_bridge.dll`，`flutter build windows` 会装到 exe 旁边 |
| Linux | QuickJS | 插件自带 `.so` |

```bash
flutter pub get
flutter run        # Android / iOS / macOS / Windows / Linux
```

Android 明文 HTTP 已由现有 `android:usesCleartextTraffic="true"` 放行；
iOS 的 ATS 与 macOS 沙盒网络权限已在本次改动里补上。

## 验证记录

| 检查 | 结果 |
|---|---|
| `flutter analyze` | 0 error / 0 warning（仅剩项目原有的 material deprecation info） |
| `flutter test` | 218 例全绿（含新增 24 例） |
| Node 协议自检 `node tool/lx_host_check.cjs <脚本>` | 4 个真实音源脚本全部通过：能 `inited`、能 dispatch、能拿到 URL |
| 引擎端到端（Windows + QuickJS） | 通过：Dart 发真实 HTTP（连不上时错误回传 JS）→ 脚本兜底 → Dart 取回 URL |

引擎端到端用例在 `flutter test` 下会先尝试加载 `quickjs_c_bridge.dll`，
加载不到就自动 skip（CI 里不会红）。

## 已知限制

- **脚本会不会一直可用取决于脚本作者的服务端**，与 App 无关；失效时日志里会写明原因
- 只接了 `musicUrl` 动作；`lyric` / `pic` 有对应实现但当前播放链路仍用官方歌词
- 第三方返回的地址如果过期/被防盗链，播放会失败一次，不会自动换源重试（可手动重播，命中缓存会复用）
- 脚本调用 `utils.zlib` / `utils.crypto.aesEncrypt` 等未实现的工具时会报错——目前只实现了
  `utils.buffer`（utf-8/base64/hex）和 `utils.crypto.md5` / `randomBytes`，这 4 个脚本都不依赖其余能力
- 未在真机验证过 iOS/Android 的引擎初始化（本机无对应工具链），代码路径与 Windows 一致

## 调协议、加音源时

```bash
# 不装 Flutter 也能验证宿主协议（直接用 Node 跑真实脚本）
node tool/lx_host_check.cjs "路径/xxx音源.js"

# 只跑这批用例
flutter test test/custom_source_test.dart test/custom_source_page_test.dart
```

想给某个平台补字段（脚本读的 `musicInfo` 字段五花八门），改
`CustomSourceManager.buildMusicInfo`；想改请求行为（代理、UA、超时），改
`LxRuntime._performHttp`。

## 免责

音源脚本均为第三方来源，本仓库不内置、不分发任何音源服务。脚本内容与可用性由作者负责，
音乐版权归各平台与原作者所有，请在合规范围内使用。
