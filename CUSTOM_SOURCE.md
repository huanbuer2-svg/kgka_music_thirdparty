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
| `pubspec.yaml` | 增加 `flutter_js: ^0.8.7`（JS 引擎）、`connectivity_plus`（网络类型） |
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
4. 在「设置 → 音源与音质」里选播放来源（默认「自动」）：
   - **自动**：官方接口优先，官方报错或没地址时自动换第三方
   - **官方**：只用官方接口
   - **第三方**：只用已启用的第三方音源
5. 同一张卡片里还能调：
   - **播放音质**：更高 / 极高 / 无损 / Hi-Res / Master（官方接口）
   - **第三方音源音质**：24位 / Hi-Res / Atmos / Atmos+ / Master（脚本侧，独立于官方音质）
   - **按网络类型选择音质**：蜂窝网络下自动降一档，省流量
   - **播放失败时切换平台**：当前平台取不到地址时，按歌名换一首同名歌曲再解析一次
6. 播一首该平台的歌，右上角 📋 看运行日志

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

## MusicFree 插件

支持 MusicFree 格式（CommonJS 模块）：执行后 `module.exports` 直接暴露
`search` / `getMediaSource` / `getLyric` / `getTopLists` 等方法。

运行时：`lib/services/custom_source/musicfree_runtime.dart` +
`lib/assets/custom_sources/musicfree/musicfree-shim.js`（补齐 QuickJS 缺的
`fetch` / `setTimeout` / `AbortController`，HTTP 走 `__mfSend` 桥接）。

平台键从插件的 `platform` 名字推断（含「汽水」→ `qs`、「网易」→ `wy` …），
这样能和官方歌曲的平台键对上，播放时按同一个键选插件。

已实测的插件：`星海音乐源 - 汽水音乐 (qs) v1.3.0` —— 搜索、取播放地址、榜单都正常。

## 内置音源

`kBuiltinCustomSources` 里的脚本会在首次启动时自动安装：

| id | 文件 | 平台 |
|---|---|---|
| `linglan` | `lib/assets/custom_sources/linglan.js` | kg / kw / mg / qs / tx / wy |

自检：`node tool/lx_host_check.cjs lib/assets/custom_sources/linglan.js`

### 关于汽水（qs）

内置的汽水直连已移除。原因：抖音接口需要签名，第三方聚合后端返回的
`source_url` 会 302 到一个防盗链中转域名，iOS 播放器处理不好；
改用聆澜音源后，它的服务端对 qs 也返回
`汽水音乐未返回可直接播放的音质（缺失、过期或加密）`（所有档位 500）。

结论：**汽水目前没有可靠链路**，要等上游解决。

## ceru 插件（manifestVersion 3）

除了 lx 传统单文件脚本，现在还支持 **ceru-js@1** 的模块化插件包
（形如 `exports.manifest = { manifestVersion: 3, engines: { hostApi: '^3.0.0',
logicRuntime: 'ceru-js@1' } }`）。

区别：

| | lx 脚本 | ceru 插件 |
|---|---|---|
| 入口 | 执行即 `send(inited)` | 导出 `activate(ctx)` |
| 能力 | `on(EVENT_NAMES.request)` 事件 | `ctx.providers.register(id, {tracks})` |
| 平台声明 | `sources` 字段 | `manifest.provides.providers[]`（带音质档位） |

运行时实现在 `lib/services/custom_source/ceru_runtime.dart`，
QuickJS 里注入三份 JS（`lib/assets/custom_sources/ceru/`）：

- `crypto-js.js` —— QuickJS 没有原生 crypto，摘要/AES 靠它
- `pako-inflate.min.js` —— 服务端 gzip 响应的解压
- `ceru-shim.js` —— 宿主垫片（ctx / `__ceruRequire` / Buffer / HTTP 桥）

`ceru-shim.js` 是**宿主无关**的，Node 侧可以用同一份文件驱动插件做调试：
`node ceru_node_test.js <插件.js> tx 晴天`。

### 这类插件通常需要配置

很多 ceru 插件（例如「聆澜音源」）把解析逻辑放在作者自己的服务器上，
manifest 的 `entry.share.configKeys` 会声明 `apiUrl` / `apiKey`。
不填的话插件会抛 `Invalid URL`，界面上会提示「需要先填写接口地址」，
在音源卡片的「⋯ → 配置」里填即可。

## 内置音源

安装包内置 **星澜音乐源**（`lib/assets/custom_sources/xinglan.js`），首次启动自动导入并启用，
支持 QQ / 网易云 / 酷我 / 酷狗 / 咪咕 五个平台。删掉后不会再次自动装回
（记在 `removedBuiltins` 里）。

内置前会用 `tool/lx_host_check.cjs` 过一遍宿主自检，跑不通的脚本不会进包。

## 多平台与下载

**搜索平台**：搜索页顶部可切 酷狗 / 网易云 / QQ音乐。
QQ 音乐用的是公开搜索接口，返回的 `mid` 直接作为脚本侧 `tx` 平台的
`songmid`，所以**播放 QQ 歌曲必须装有支持 tx 的音源脚本**，否则点播放会提示。

**汽水音乐**：没有公开搜索接口，本项目不内置抓取。若音源脚本声明了 `qs` 平台
（例如「星海音乐源」），App 会在音源卡片和设置页把它显示为「汽水音乐」，
并按脚本声明的 `spatial`（空间音频）/ `hires` 等档位解析地址；但 App 内仍无法搜索汽水曲库。

**下载**：播放器右上角「…」→ 下载歌曲，可选 8 档音质：

| 档位 | 来源 |
|---|---|
| 128k / 320k / 无损 FLAC | 官方接口 |
| FLAC 24 位 / Hi-Res / Atmos / Atmos+ / Master | 第三方音源脚本（拿不到时回退官方无损） |

## 音质体系

| 界面档位 | 官方接口 quality | 说明 |
|---|---|---|
| 更高 | `128` | 默认 |
| 极高 | `320` | |
| 无损 | `flac` | |
| Hi-Res | `hires` | 服务端不支持时按「智能音质」自动降级 |
| Master | `master` | 同上 |

第三方音源音质是另一套档位（写进脚本 `info.type`）：
`flac24bit` / `hires` / `atmos` / `atmos_plus` / `master`。
脚本没声明所选档位时会退到它自己声明的可用档位，不会因为档位不匹配直接失败。

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
