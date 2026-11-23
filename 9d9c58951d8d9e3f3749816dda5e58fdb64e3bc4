/**
 * lx 宿主垫片自检脚本（Node 环境，不依赖 Flutter）。
 *
 * 作用：把 `lib/services/custom_source/lx_js_bootstrap.dart` 里的 JS 垫片源码
 * 原样抽出来，在 Node 里跑真实的 lx-music 音源脚本，验证：
 *   1. 脚本能拿到 `globalThis.lx` 并完成 `send(EVENT_NAMES.inited)`
 *   2. `musicUrl` 请求能被 dispatch 并走通 `lx.request` 假响应回调
 *   3. 最终结果能被 takeResult 取回
 *
 * 用法：node tool/lx_host_check.cjs [脚本路径]
 */
const fs = require('fs');
const path = require('path');
const vm = require('vm');

const root = path.resolve(__dirname, '..');
const bootstrapDart = fs.readFileSync(
  path.join(root, 'lib/services/custom_source/lx_js_bootstrap.dart'),
  'utf8',
);
const start = bootstrapDart.indexOf("r'''") + 4;
const end = bootstrapDart.lastIndexOf("''';");
if (start < 4 || end < 0) throw new Error('未能在 dart 文件中定位垫片源码');
const bootstrap = bootstrapDart.slice(start, end);

const scriptPath = process.argv[2] || process.argv[1];
const candidates = [
  process.argv[2],
  path.join(root, '../src/KMusic-2026-main/新澜音源.js'),
  path.join(root, '../src/KMusic-2026-main/ikun音源.js'),
];
const target = candidates.find((p) => p && fs.existsSync(p));
if (!target) {
  throw new Error('用法：node tool/lx_host_check.cjs <音源脚本路径>');
}

// 垫片会接管 globalThis.console（模拟宿主日志通道），先留住 Node 自己的输出能力
const realLog = globalThis.console.log.bind(globalThis.console);

const events = [];
const httpLog = [];
let fakeUrl = 'https://cdn.example.com/fake.mp3';

globalThis.sendMessage = (channel, message) => {
  const msg = JSON.parse(message);
  events.push(msg);
  if (msg.t === 'http') {
    httpLog.push(msg);
    // 模拟 Dart 侧异步 HTTP：下一轮事件循环回填
    setTimeout(() => {
      // 不同音源脚本对成功码的定义不同（新澜 200 / 落雪 0），按目标地址给码
      const successCode = msg.url.includes('220.167.101.253') ? 0 : 200;
      const body = { code: successCode, url: fakeUrl, data: fakeUrl, msg: '' };
      const response = { statusCode: 200, headers: {}, body };
      globalThis.__lxHost.httpResult(
        msg.id,
        JSON.stringify({ response }),
      );
    }, 5);
  }
};

vm.runInThisContext(bootstrap, { filename: 'lx_bootstrap.js' });
vm.runInThisContext(fs.readFileSync(target, 'utf8'), { filename: path.basename(target) });

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

(async () => {
  await sleep(120);
  const inited = events.find((e) => e.t === 'inited');
  if (!inited) throw new Error('脚本未上报 inited');
  const sources = inited.data.sources || {};
  realLog('[ok] inited, sources =', Object.keys(sources).join(','));
  realLog('[ok] status =', globalThis.__lxHost.status());

  const sourceKey = Object.keys(sources)[0];
  const payload = {
    action: 'musicUrl',
    source: sourceKey,
    info: {
      type: (sources[sourceKey].qualitys || ['128k'])[0],
      musicInfo: {
        songmid: '0039MnYb0qxYhV',
        hash: 'ABCDEF0123456789ABCDEF0123456789',
        id: '12345678',
        name: '测试歌曲',
        singer: '测试歌手',
        albumName: '测试专辑',
        album: '测试专辑',
        source: sourceKey,
      },
    },
  };

  globalThis.__lxHost.dispatch(JSON.stringify(payload), 1);
  let result = null;
  for (let i = 0; i < 200; i++) {
    await sleep(10);
    const raw = globalThis.__lxHost.takeResult(1);
    if (raw !== null) {
      result = JSON.parse(raw);
      break;
    }
  }
  realLog('[ok] http requests =', httpLog.length, httpLog.map((h) => h.url).join('\n     '));
  if (!result) throw new Error('dispatch 无结果返回');
  if (!result.ok) throw new Error('脚本返回失败：' + result.err);
  if (typeof result.val !== 'string' || !result.val.startsWith('http')) {
    throw new Error('返回值不是 URL：' + JSON.stringify(result.val));
  }
  realLog('[ok] musicUrl =', result.val);
  realLog('[ok] log lines =', events.filter((e) => e.t === 'log').length);
  realLog('\nPASS:', path.basename(target));
})().catch((e) => {
  realLog('\nFAIL:', e.message);
  process.exit(1);
});
