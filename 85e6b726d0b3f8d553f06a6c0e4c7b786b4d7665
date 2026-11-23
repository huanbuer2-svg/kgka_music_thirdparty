/// lx-music 自定义音源脚本的 JS 宿主垫片（bootstrap）。
///
/// 在 JS 引擎里执行本文件中的 [kLxBootstrapSource] 之后，脚本看到的
/// `globalThis.lx` 就是一个兼容 lx-music（桌面版 / 移动版）自定义源协议的
/// 宿主对象，包含：
///
/// - `EVENT_NAMES` / `on` / `send`：脚本向宿主注册处理器并上报初始化结果
/// - `request(url, options, callback)`：脚本发起 HTTP（由 Dart 侧真正执行）
/// - `utils.buffer` / `utils.crypto`：脚本常用的 Node 风格工具
/// - `env` / `version`：部分脚本会拼进 User-Agent
///
/// 通信协议（全部走 flutter_js 的 `sendMessage('lx', json)` 单通道）：
///
/// ```
/// JS -> Dart  { t: 'inited',      data: {...} }
/// JS -> Dart  { t: 'log',         level: 'log', msg: '...' }
/// JS -> Dart  { t: 'http',        id: 1, url: '...', options: {...} }
/// JS -> Dart  { t: 'updateAlert', data: {...} }
/// Dart -> JS  __lxHost.httpResult(id, responseJson)
/// Dart -> JS  __lxHost.dispatch(payloadJson, callId)
/// Dart -> JS  __lxHost.takeResult(callId) -> json | null
/// ```
///
/// 之所以用「Dart 主动轮询 takeResult」而不是让 JS 直接 await 宿主，是因为
/// flutter_js 的 `sendMessage` 通道由 JS 同步调用到 Dart、无法回传 Promise。
/// 轮询 + `executePendingJob()` 是 flutter_js 自身处理 Promise 的同款做法。
library;

/// 垫片源码。用 raw string 保存，里面大量 `$`（正则 / 模板）不会被 Dart 插值。
const String kLxBootstrapSource = r'''
(function () {
  if (globalThis.__KG_LX_HOST__) return 'already';
  globalThis.__KG_LX_HOST__ = 'v1';

  var EVENT_NAMES = {
    request: 'request',
    inited: 'inited',
    updateAlert: 'updateAlert',
    log: 'log'
  };

  var handlers = Object.create(null);
  var httpPending = Object.create(null);
  var results = Object.create(null);
  var httpSeq = 0;
  var initedData = null;
  var groupDepth = 0;

  function errText(e) {
    if (e === null || e === undefined) return 'unknown error';
    if (typeof e === 'string') return e;
    if (e.message) return String(e.message);
    try { return JSON.stringify(e); } catch (_) { return String(e); }
  }

  function post(msg) {
    try { sendMessage('lx', JSON.stringify(msg)); } catch (e) { /* 通道关闭时忽略 */ }
  }

  // ---------------------------------------------------------------- console
  function stringify(v) {
    if (typeof v === 'string') return v;
    if (v === null || v === undefined) return String(v);
    try { return JSON.stringify(v); } catch (e) { return String(v); }
  }

  function formatArgs(args) {
    var out = [];
    for (var i = 0; i < args.length; i++) out.push(stringify(args[i]));
    var pad = groupDepth > 0 ? new Array(groupDepth + 1).join('  ') : '';
    return pad + out.join(' ');
  }

  var consoleObj = {};
  var levels = ['log', 'info', 'warn', 'error', 'debug', 'trace', 'dir'];
  for (var li = 0; li < levels.length; li++) {
    (function (level) {
      consoleObj[level] = function () {
        post({ t: 'log', level: level === 'warn' ? 'warn' : (level === 'error' ? 'error' : 'log'), msg: formatArgs(arguments) });
      };
    })(levels[li]);
  }
  consoleObj.group = function () {
    var msg = formatArgs(arguments);
    if (msg) post({ t: 'log', level: 'log', msg: msg });
    groupDepth += 1;
  };
  consoleObj.groupCollapsed = consoleObj.group;
  consoleObj.groupEnd = function () { if (groupDepth > 0) groupDepth -= 1; };
  consoleObj.table = function () { post({ t: 'log', level: 'log', msg: formatArgs(arguments) }); };
  consoleObj.time = function () {};
  consoleObj.timeEnd = function () {};
  consoleObj.assert = function (cond) {
    if (!cond) post({ t: 'log', level: 'error', msg: 'assert failed: ' + formatArgs(Array.prototype.slice.call(arguments, 1)) });
  };
  globalThis.console = consoleObj;

  if (typeof globalThis.clearTimeout !== 'function') {
    globalThis.clearTimeout = function () {};
  }
  if (typeof globalThis.setInterval !== 'function') {
    globalThis.setInterval = function () { return 0; };
    globalThis.clearInterval = function () {};
  }

  // ------------------------------------------------------------ base64 / utf8
  var B64C = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
  var B64MAP = {};
  for (var bi = 0; bi < B64C.length; bi++) B64MAP[B64C.charAt(bi)] = bi;

  function utf8Encode(str) {
    var out = [];
    for (var i = 0; i < str.length; i++) {
      var c = str.charCodeAt(i);
      if (c < 0x80) {
        out.push(c);
      } else if (c < 0x800) {
        out.push(0xc0 | (c >> 6), 0x80 | (c & 63));
      } else if (c >= 0xd800 && c <= 0xdbff && i + 1 < str.length) {
        var c2 = str.charCodeAt(i + 1);
        if (c2 >= 0xdc00 && c2 <= 0xdfff) {
          var cp = 0x10000 + ((c - 0xd800) << 10) + (c2 - 0xdc00);
          out.push(0xf0 | (cp >> 18), 0x80 | ((cp >> 12) & 63), 0x80 | ((cp >> 6) & 63), 0x80 | (cp & 63));
          i += 1;
        } else {
          out.push(0xe0 | (c >> 12), 0x80 | ((c >> 6) & 63), 0x80 | (c & 63));
        }
      } else {
        out.push(0xe0 | (c >> 12), 0x80 | ((c >> 6) & 63), 0x80 | (c & 63));
      }
    }
    return out;
  }

  function utf8Decode(bytes) {
    var out = '';
    var i = 0;
    while (i < bytes.length) {
      var b = bytes[i++];
      if (b < 0x80) {
        out += String.fromCharCode(b);
      } else if (b >= 0xc0 && b < 0xe0) {
        var b1 = bytes[i++];
        out += String.fromCharCode(((b & 31) << 6) | (b1 & 63));
      } else if (b >= 0xe0 && b < 0xf0) {
        var b2 = bytes[i++], b3 = bytes[i++];
        out += String.fromCharCode(((b & 15) << 12) | ((b2 & 63) << 6) | (b3 & 63));
      } else if (b >= 0xf0) {
        var b4 = bytes[i++], b5 = bytes[i++], b6 = bytes[i++];
        var cp2 = ((b & 7) << 18) | ((b4 & 63) << 12) | ((b5 & 63) << 6) | (b6 & 63);
        cp2 -= 0x10000;
        out += String.fromCharCode(0xd800 + (cp2 >> 10), 0xdc00 + (cp2 & 1023));
      }
    }
    return out;
  }

  function bytesToBase64(bytes) {
    var out = '';
    var i = 0;
    while (i + 2 < bytes.length) {
      var n = (bytes[i] << 16) | (bytes[i + 1] << 8) | bytes[i + 2];
      out += B64C.charAt((n >> 18) & 63) + B64C.charAt((n >> 12) & 63) + B64C.charAt((n >> 6) & 63) + B64C.charAt(n & 63);
      i += 3;
    }
    var rest = bytes.length - i;
    if (rest === 1) {
      var n1 = bytes[i] << 16;
      out += B64C.charAt((n1 >> 18) & 63) + B64C.charAt((n1 >> 12) & 63) + '==';
    } else if (rest === 2) {
      var n2 = (bytes[i] << 16) | (bytes[i + 1] << 8);
      out += B64C.charAt((n2 >> 18) & 63) + B64C.charAt((n2 >> 12) & 63) + B64C.charAt((n2 >> 6) & 63) + '=';
    }
    return out;
  }

  function base64ToBytes(str) {
    var clean = String(str).replace(/[^A-Za-z0-9+/=]/g, '');
    var out = [];
    var buffer = 0;
    var bits = 0;
    for (var i = 0; i < clean.length; i++) {
      var ch = clean.charAt(i);
      if (ch === '=') break;
      var v = B64MAP[ch];
      if (v === undefined) continue;
      buffer = (buffer << 6) | v;
      bits += 6;
      if (bits >= 8) {
        bits -= 8;
        out.push((buffer >> bits) & 0xff);
      }
    }
    return out;
  }

  function bytesToHex(bytes) {
    var hex = '0123456789abcdef';
    var out = '';
    for (var i = 0; i < bytes.length; i++) {
      out += hex.charAt((bytes[i] >> 4) & 15) + hex.charAt(bytes[i] & 15);
    }
    return out;
  }

  function hexToBytes(str) {
    var clean = String(str).replace(/[^0-9a-fA-F]/g, '');
    var out = [];
    for (var i = 0; i + 1 < clean.length; i += 2) {
      out.push(parseInt(clean.substr(i, 2), 16));
    }
    return out;
  }

  function toBytes(data) {
    if (data === null || data === undefined) return [];
    if (Object.prototype.toString.call(data) === '[object Array]') return data.slice();
    if (data && data._bytes) return data._bytes.slice();
    return utf8Encode(String(data));
  }

  function LxBuffer(bytes) {
    this._bytes = bytes || [];
    this.length = this._bytes.length;
    this.type = 'Buffer';
  }
  LxBuffer.prototype.toString = function (enc) { return bufToString(this, enc || 'utf-8'); };
  LxBuffer.prototype.toJSON = function () { return { type: 'Buffer', data: this._bytes }; };
  LxBuffer.prototype.slice = function (a, b) { return new LxBuffer(this._bytes.slice(a, b)); };

  function bufToString(buf, enc) {
    var bytes = (buf && buf._bytes) || [];
    enc = String(enc || 'utf-8').toLowerCase();
    if (enc === 'base64') return bytesToBase64(bytes);
    if (enc === 'hex') return bytesToHex(bytes);
    if (enc === 'binary' || enc === 'latin1') {
      var latin = '';
      for (var i = 0; i < bytes.length; i++) latin += String.fromCharCode(bytes[i]);
      return latin;
    }
    return utf8Decode(bytes);
  }

  var bufferUtil = {
    from: function (data, enc) {
      if (data instanceof LxBuffer) return new LxBuffer(data._bytes.slice());
      if (typeof data === 'string' && String(enc || '').toLowerCase() === 'base64') {
        return new LxBuffer(base64ToBytes(data));
      }
      if (typeof data === 'string' && String(enc || '').toLowerCase() === 'hex') {
        return new LxBuffer(hexToBytes(data));
      }
      if (typeof data === 'number') {
        var zeros = [];
        for (var i = 0; i < data; i++) zeros.push(0);
        return new LxBuffer(zeros);
      }
      return new LxBuffer(toBytes(data));
    },
    alloc: function (n) {
      var arr = [];
      for (var i = 0; i < n; i++) arr.push(0);
      return new LxBuffer(arr);
    },
    concat: function (list) {
      var out = [];
      for (var i = 0; i < list.length; i++) out = out.concat(toBytes(list[i]));
      return new LxBuffer(out);
    },
    isBuffer: function (v) { return v instanceof LxBuffer; },
    bufToString: bufToString
  };

  // -------------------------------------------------------------- basic md5
  // 部分音源脚本用 utils.crypto.md5 计算签名，这里给一个纯 JS 实现。
  var md5Table = null;
  function md5Init() {
    if (md5Table) return md5Table;
    var T = [];
    for (var i = 0; i < 64; i++) {
      T[i] = Math.floor(Math.abs(Math.sin(i + 1)) * 4294967296);
    }
    md5Table = T;
    return T;
  }
  function md5(str) {
    var T = md5Init();
    var bytes = utf8Encode(String(str));
    var bitLen = bytes.length * 8;
    bytes.push(0x80);
    while (bytes.length % 64 !== 56) bytes.push(0);
    // 小端 64 位长度
    for (var i = 0; i < 8; i++) bytes.push((bitLen >>> (8 * i)) & 0xff);

    var a0 = 0x67452301, b0 = 0xefcdab89, c0 = 0x98badcfe, d0 = 0x10325476;
    var S = [7, 12, 17, 22, 5, 9, 14, 20, 4, 11, 16, 23, 6, 10, 15, 21];

    for (var off = 0; off < bytes.length; off += 64) {
      var M = [];
      for (var j = 0; j < 16; j++) {
        M[j] = bytes[off + j * 4] | (bytes[off + j * 4 + 1] << 8) | (bytes[off + j * 4 + 2] << 16) | (bytes[off + j * 4 + 3] << 24);
      }
      var A = a0, B = b0, C = c0, D = d0;
      for (var k = 0; k < 64; k++) {
        var F, g;
        if (k < 16) { F = (B & C) | (~B & D); g = k; }
        else if (k < 32) { F = (D & B) | (~D & C); g = (5 * k + 1) % 16; }
        else if (k < 48) { F = B ^ C ^ D; g = (3 * k + 5) % 16; }
        else { F = C ^ (B | ~D); g = (7 * k) % 16; }
        var tmp = D;
        D = C;
        C = B;
        var sum = (A + F + T[k] + M[g]) | 0;
        var shift = S[(k >> 4) * 4 + (k % 4)];
        B = (B + ((sum << shift) | (sum >>> (32 - shift)))) | 0;
        A = tmp;
      }
      a0 = (a0 + A) | 0;
      b0 = (b0 + B) | 0;
      c0 = (c0 + C) | 0;
      d0 = (d0 + D) | 0;
    }

    function le(n) {
      var s = '';
      for (var i = 0; i < 4; i++) s += ('0' + ((n >>> (8 * i)) & 0xff).toString(16)).slice(-2);
      return s;
    }
    return le(a0) + le(b0) + le(c0) + le(d0);
  }

  var utils = {
    buffer: bufferUtil,
    crypto: {
      md5: md5,
      randomBytes: function (n) {
        var arr = [];
        for (var i = 0; i < n; i++) arr.push(Math.floor(Math.random() * 256));
        return new LxBuffer(arr);
      }
    }
  };

  // ------------------------------------------------------------------ lx API
  function httpRequest(url, options, callback) {
    if (typeof options === 'function') {
      callback = options;
      options = {};
    }
    if (typeof callback !== 'function') return;
    options = options || {};
    httpSeq += 1;
    var id = httpSeq;
    httpPending[id] = callback;
    var safeOptions = {
      method: String(options.method || 'GET').toUpperCase(),
      headers: options.headers || {},
      body: options.body === undefined ? null : String(options.body),
      timeout: options.timeout || 0
    };
    post({ t: 'http', id: id, url: String(url), options: safeOptions });
  }

  function on(name, fn) {
    if (typeof fn === 'function') handlers[name] = fn;
  }

  function send(name, data) {
    if (name === EVENT_NAMES.inited) {
      initedData = data;
      post({ t: 'inited', data: data });
    } else if (name === EVENT_NAMES.updateAlert) {
      post({ t: 'updateAlert', data: data });
    } else {
      post({ t: 'event', name: String(name), data: data });
    }
  }

  globalThis.lx = {
    EVENT_NAMES: EVENT_NAMES,
    env: 'mobile',
    version: '2.0.0',
    utils: utils,
    on: on,
    send: send,
    request: httpRequest
  };

  // Dart -> JS 的调用入口
  globalThis.__lxHost = {
    httpResult: function (id, payloadJson) {
      var cb = httpPending[id];
      if (!cb) return 0;
      delete httpPending[id];
      var payload;
      try { payload = JSON.parse(payloadJson); } catch (e) { payload = { error: 'bad payload' }; }
      if (payload && payload.error) {
        try {
          cb({ statusCode: 0, statusMessage: String(payload.error), body: null, error: String(payload.error) }, null);
        } catch (e) {}
      } else {
        try {
          cb(null, payload.response);
        } catch (e) {
          post({ t: 'log', level: 'error', msg: 'request callback threw: ' + errText(e) });
        }
      }
      return 1;
    },

    dispatch: function (payloadJson, callId) {
      var payload;
      try {
        payload = JSON.parse(payloadJson);
      } catch (e) {
        results[callId] = { ok: false, err: 'bad payload' };
        return 0;
      }
      var fn = handlers[EVENT_NAMES.request];
      if (typeof fn !== 'function') {
        results[callId] = { ok: false, err: 'script did not register a request handler' };
        return 0;
      }
      var out;
      try {
        out = fn(payload);
      } catch (e) {
        results[callId] = { ok: false, err: errText(e) };
        return 0;
      }
      Promise.resolve(out).then(function (v) {
        results[callId] = { ok: true, val: v };
      }, function (e) {
        results[callId] = { ok: false, err: errText(e) };
      });
      return 1;
    },

    takeResult: function (callId) {
      var r = results[callId];
      if (r === undefined) return null;
      delete results[callId];
      return JSON.stringify(r);
    },

    status: function () {
      var pendingHttp = 0;
      for (var k in httpPending) pendingHttp += 1;
      return JSON.stringify({
        inited: !!initedData,
        hasHandler: typeof handlers[EVENT_NAMES.request] === 'function',
        pendingHttp: pendingHttp
      });
    },

    sources: function () {
      return JSON.stringify((initedData && initedData.sources) || {});
    }
  };

  return 'ok';
})();
''';
