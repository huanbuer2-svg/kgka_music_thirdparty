/**
 * ceru-js 运行时垫片（hostApi 3.0）
 * ============================================================================
 * 宿主无关的一份实现：Flutter(QuickJS) 与 Node(测试) 加载同一份文件，
 * 只在启动时注入 `__ceruSend` / `__ceruLog` 两个桥函数。
 *
 * 对外只暴露 `__ceru` 一个对象，方法全部同步返回字符串，异步能力靠
 * "启动 → 宿主轮询 → 取结果槽位" 的模式驱动，原因和 lx 音源一致：
 * sendMessage 是 JS→Dart 单向同步通道，Dart 拿不到 JS 的 Promise。
 *
 * 依赖注入（由宿主在加载本文件之前准备好）：
 *   globalThis.CryptoJS  —— crypto-js 的 UMD 构建
 *   globalThis.pako      —— pako_inflate 构建
 * ============================================================================
 */
(function (global) {
  'use strict';

  var sendBridge = global.__ceruSend || function () {};
  var logBridge = global.__ceruLog || function () {};

  function safeJson(value) {
    try {
      return JSON.stringify(value);
    } catch (e) {
      return 'null';
    }
  }

  // ---------------------------------------------------------------- Buffer
  // 插件里只在 typeof Buffer !== 'undefined' 时才用，这里给个够用的实现，
  // 免得 crypto/encoding 里出现未定义分支。
  function CBuffer(bytes) {
    if (!(this instanceof CBuffer)) return new CBuffer(bytes);
    var u8 = bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes || 0);
    this._u8 = u8;
    this.length = u8.length;
    for (var i = 0; i < u8.length; i++) this[i] = u8[i];
  }
  CBuffer.prototype.toString = function (enc) {
    switch ((enc || 'utf8').toLowerCase()) {
      case 'base64':
        return bytesToBase64(this._u8);
      case 'base64url':
        return bytesToBase64(this._u8).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
      case 'hex':
        return bytesToHex(this._u8);
      case 'latin1':
      case 'binary':
        return String.fromCharCode.apply(null, Array.prototype.slice.call(this._u8));
      default:
        return utf8Decode(this._u8);
    }
  };
  CBuffer.from = function (input, enc) {
    if (input instanceof CBuffer) return new CBuffer(input._u8);
    if (input instanceof Uint8Array) return new CBuffer(input);
    if (Array.isArray(input)) return new CBuffer(new Uint8Array(input));
    var text = String(input == null ? '' : input);
    switch ((enc || 'utf8').toLowerCase()) {
      case 'base64':
        return new CBuffer(base64ToBytes(text));
      case 'hex':
        return new CBuffer(hexToBytes(text));
      case 'latin1':
      case 'binary':
        var arr = new Uint8Array(text.length);
        for (var i = 0; i < text.length; i++) arr[i] = text.charCodeAt(i) & 0xff;
        return new CBuffer(arr);
      default:
        return new CBuffer(utf8Encode(text));
    }
  };
  CBuffer.alloc = function (n, fill) {
    var arr = new Uint8Array(n);
    if (fill) arr.fill(typeof fill === 'number' ? fill : 0);
    return new CBuffer(arr);
  };
  CBuffer.isBuffer = function (obj) {
    return obj instanceof CBuffer || obj instanceof Uint8Array;
  };
  CBuffer.concat = function (list) {
    var total = 0;
    for (var i = 0; i < list.length; i++) total += list[i].length;
    var out = new Uint8Array(total);
    var offset = 0;
    for (var j = 0; j < list.length; j++) {
      out.set(list[j]._u8 || list[j], offset);
      offset += list[j].length;
    }
    return new CBuffer(out);
  };
  CBuffer.prototype.toUint8Array = function () {
    return this._u8;
  };
  Object.defineProperty(CBuffer.prototype, 'constructor', { value: CBuffer });

  // --- 字节工具 ---
  var B64 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
  function bytesToBase64(bytes) {
    var out = '';
    for (var i = 0; i < bytes.length; i += 3) {
      var b0 = bytes[i], b1 = bytes[i + 1], b2 = bytes[i + 2];
      out += B64[b0 >> 2];
      out += B64[((b0 & 3) << 4) | ((b1 || 0) >> 4)];
      out += i + 1 < bytes.length ? B64[((b1 & 15) << 2) | ((b2 || 0) >> 6)] : '=';
      out += i + 2 < bytes.length ? B64[(b2 || 0) & 63] : '=';
    }
    return out;
  }
  function base64ToBytes(text) {
    var clean = String(text).replace(/[^A-Za-z0-9+/=]/g, '');
    var out = [];
    for (var i = 0; i < clean.length; i += 4) {
      var c0 = B64.indexOf(clean[i]), c1 = B64.indexOf(clean[i + 1]);
      var c2 = B64.indexOf(clean[i + 2]), c3 = B64.indexOf(clean[i + 3]);
      out.push((c0 << 2) | (c1 >> 4));
      if (c2 >= 0) out.push(((c1 & 15) << 4) | (c2 >> 2));
      if (c3 >= 0) out.push(((c2 & 3) << 6) | c3);
    }
    return new Uint8Array(out);
  }
  function bytesToHex(bytes) {
    var s = '';
    for (var i = 0; i < bytes.length; i++) s += (bytes[i] < 16 ? '0' : '') + bytes[i].toString(16);
    return s;
  }
  function hexToBytes(text) {
    var clean = String(text).replace(/[^0-9a-fA-F]/g, '');
    var out = new Uint8Array(Math.floor(clean.length / 2));
    for (var i = 0; i < out.length; i++) out[i] = parseInt(clean.substr(i * 2, 2), 16);
    return out;
  }
  function utf8Encode(text) {
    if (typeof TextEncoder !== 'undefined') return new TextEncoder().encode(text);
    var s = unescape(encodeURIComponent(text));
    var arr = new Uint8Array(s.length);
    for (var i = 0; i < s.length; i++) arr[i] = s.charCodeAt(i);
    return arr;
  }
  function utf8Decode(bytes) {
    if (typeof TextDecoder !== 'undefined') return new TextDecoder('utf-8').decode(bytes);
    var s = '';
    for (var i = 0; i < bytes.length; i++) s += String.fromCharCode(bytes[i]);
    try { return decodeURIComponent(escape(s)); } catch (e) { return s; }
  }

  global.Buffer = global.Buffer || CBuffer;

  // ------------------------------------------------------- 内置模块（crypto）
  function requireCryptoJs() {
    if (!global.CryptoJS) {
      throw new Error('缺少 CryptoJS：ceru 的 @ceru/crypto 依赖它，请先注入 crypto-js');
    }
    return global.CryptoJS;
  }

  function toWordArray(input) {
    var CJ = requireCryptoJs();
    if (input && input.__wordArray) return input.__wordArray;
    if (typeof input === 'string') return CJ.enc.Utf8.parse(input);
    var buf = input instanceof CBuffer ? input._u8 : input;
    if (buf instanceof Uint8Array) {
      var words = [];
      for (var i = 0; i < buf.length; i++) {
        words[i >>> 2] |= buf[i] << (24 - (i % 4) * 8);
      }
      return CJ.lib.WordArray.create(words, buf.length);
    }
    return CJ.enc.Utf8.parse(String(input == null ? '' : input));
  }

  function bytesFromWordArray(wa) {
    var buf = new CBuffer(new Uint8Array(wa.sigBytes));
    for (var i = 0; i < wa.sigBytes; i++) {
      buf._u8[i] = (wa.words[i >>> 2] >>> (24 - (i % 4) * 8)) & 0xff;
      buf[i] = buf._u8[i];
    }
    return buf;
  }

  function hashApi(algoName) {
    var CJ = requireCryptoJs();
    // CryptoJS.SHA256 是可直接调用的函数，只有 algo.SHA256 才有 create()
    var algo = CJ.algo && CJ.algo[algoName];
    if (!algo || typeof algo.create !== 'function') {
      throw new Error('不支持的摘要算法: ' + algoName);
    }
    return algo;
  }

  var cryptoModule = {
    createHash: function (algo) {
      var name = String(algo).toUpperCase().replace(/-/g, '');
      var factory = hashApi(name === 'SHA256' ? 'SHA256' : name);
      var chunks = [];
      return {
        update: function (data) {
          chunks.push(toWordArray(data));
          return this;
        },
        digest: function (enc) {
          var wa = factory.create();
          for (var i = 0; i < chunks.length; i++) wa.update(chunks[i]);
          var out = wa.finalize();
          if (!enc || enc === 'buffer') return bytesFromWordArray(out);
          if (enc === 'hex') return out.toString(CJ.enc.Hex);
          if (enc === 'base64') return out.toString(CJ.enc.Base64);
          return out.toString(CJ.enc.Utf8);
        },
      };
    },
    createHmac: function (algo, key) {
      var CJ = requireCryptoJs();
      var name = String(algo).toUpperCase().replace(/-/g, '');
      var hashAlgo = CJ.algo && CJ.algo[name];
      if (!hashAlgo) throw new Error('不支持的 HMAC 算法: ' + algo);
      var chunks = [];
      return {
        update: function (data) {
          chunks.push(toWordArray(data));
          return this;
        },
        digest: function (enc) {
          var merged = chunks.length === 1 ? chunks[0] : (function () {
            var acc = chunks[0].clone();
            for (var i = 1; i < chunks.length; i++) acc.concat(chunks[i]);
            return acc;
          })();
          var hmac = CJ.algo.HMAC.create(hashAlgo, toWordArray(key));
          var out = hmac.finalize(merged);
          if (!enc || enc === 'buffer') return bytesFromWordArray(out);
          if (enc === 'hex') return out.toString(CJ.enc.Hex);
          if (enc === 'base64') return out.toString(CJ.enc.Base64);
          return out.toString(CJ.enc.Utf8);
        },
      };
    },
    createCipheriv: function (algo, key, iv) {
      var CJ = requireCryptoJs();
      var name = String(algo).toUpperCase();
      var mode, pad = true, isCBC = /-CBC$/.test(name), isCTR = /-CTR$/.test(name);
      mode = (isCTR ? CJ.mode.CTR : CJ.mode.CBC);
      var base = name.replace(/-.*$/, '');
      var enc = base === 'AES' ? 'AES' : base;
      var chunks = [];
      return {
        update: function (data) {
          chunks.push(toWordArray(data));
          return this;
        },
        final: function () {
          var merged = chunks.length ? chunks[0].clone() : requireCryptoJs().lib.WordArray.create();
          for (var i = 1; i < chunks.length; i++) merged.concat(chunks[i]);
          var cfg = { iv: toWordArray(iv), mode: mode, padding: CJ.pad.Pkcs7 };
          var out = CJ[enc].encrypt(merged, toWordArray(key), cfg).ciphertext;
          return bytesFromWordArray(out);
        },
      };
    },
    createDecipheriv: function (algo, key, iv) {
      var CJ = requireCryptoJs();
      var name = String(algo).toUpperCase();
      var isCTR = /-CTR$/.test(name);
      var base = name.replace(/-.*$/, '');
      var chunks = [];
      return {
        update: function (data) {
          chunks.push(toWordArray(data));
          return this;
        },
        final: function () {
          var CJs = requireCryptoJs();
          var merged = chunks.length ? chunks[0].clone() : CJs.lib.WordArray.create();
          for (var i = 1; i < chunks.length; i++) merged.concat(chunks[i]);
          var cfg = {
            iv: toWordArray(iv),
            mode: isCTR ? CJs.mode.CTR : CJs.mode.CBC,
            padding: CJs.pad.Pkcs7,
          };
          var params = CJs.lib.CipherParams.create({ ciphertext: merged });
          var out = CJs[base === 'AES' ? 'AES' : base].decrypt(params, toWordArray(key), cfg);
          return bytesFromWordArray(out);
        },
      };
    },
    randomBytes: function (n) {
      var arr = new Uint8Array(n);
      for (var i = 0; i < n; i++) arr[i] = Math.floor(Math.random() * 256);
      return new CBuffer(arr);
    },
    randomUUID: function () {
      var s = bytesToHex(cryptoModule.randomBytes(16)._u8);
      return s.slice(0, 8) + '-' + s.slice(8, 12) + '-4' + s.slice(13, 16) + '-a' + s.slice(17, 20) + '-' + s.slice(20);
    },
    timingSafeEqual: function (a, b) {
      var x = a instanceof CBuffer ? a._u8 : a, y = b instanceof CBuffer ? b._u8 : b;
      if (!x || !y || x.length !== y.length) return false;
      var diff = 0;
      for (var i = 0; i < x.length; i++) diff |= x[i] ^ y[i];
      return diff === 0;
    },
  };

  // -------------------------------------------------- 内置模块（encoding）
  var encodingModule = {
    from: function (str, enc) { return CBuffer.from(str, enc); },
    to: function (buf, enc) { return CBuffer.from(buf).toString(enc); },
    encode: function (str, enc) { return CBuffer.from(str).toString(enc); },
    decode: function (str, enc) { return CBuffer.from(str, enc).toString('utf8'); },
    base64Encode: function (v) { return CBuffer.from(v).toString('base64'); },
    base64Decode: function (v) { return CBuffer.from(v, 'base64'); },
    hexEncode: function (v) { return CBuffer.from(v).toString('hex'); },
    hexDecode: function (v) { return CBuffer.from(v, 'hex'); },
    utf8Encode: function (v) { return CBuffer.from(String(v)); },
    utf8Decode: function (v) { return CBuffer.from(v).toString('utf8'); },
    Buffer: CBuffer,
  };

  // ----------------------------------------------- 内置模块（compression）
  function requirePako() {
    if (!global.pako) throw new Error('缺少 pako：ceru 的 @ceru/compression 依赖它，请先注入 pako');
    return global.pako;
  }
  var compressionModule = {
    inflate: function (v) { return requirePako().inflate(toU8(v)); },
    inflateRaw: function (v) { return requirePako().inflateRaw(toU8(v)); },
    gunzip: function (v) { return requirePako().ungzip(toU8(v)); },
    deflate: function (v) {
      var p = requirePako();
      if (!p.deflate) throw new Error('当前 pako 构建不含 deflate');
      return p.deflate(toU8(v));
    },
    gzip: function (v) {
      var p = requirePako();
      if (!p.gzip) throw new Error('当前 pako 构建不含 gzip');
      return p.gzip(toU8(v));
    },
  };
  function toU8(v) {
    if (v instanceof Uint8Array) return v;
    if (v && v._u8) return v._u8;
    if (typeof v === 'string') return utf8Encode(v);
    return new Uint8Array(v || 0);
  }

  var builtinModules = {
    '@ceru/crypto': cryptoModule,
    '@ceru/encoding': encodingModule,
    '@ceru/compression': compressionModule,
  };
  global.__ceruRequire = function (id) {
    var mod = builtinModules[id];
    if (!mod) throw new Error('未实现的 ceru 内置模块: ' + id);
    return mod;
  };

  // ------------------------------------------------------------------ HTTP
  var httpSeq = 0;
  var pendingHttp = new Map();

  function httpRequest(opts) {
    return new Promise(function (resolve, reject) {
      var id = 'h' + ++httpSeq;
      pendingHttp.set(id, { resolve: resolve, reject: reject });
      try {
        sendBridge(
          'ceru',
          safeJson({
            type: 'http',
            id: id,
            url: opts && opts.url,
            method: (opts && opts.method) || 'GET',
            headers: (opts && opts.headers) || {},
            body: opts && opts.body,
            timeoutMs: (opts && opts.timeoutMs) || 20000,
          })
        );
      } catch (e) {
        pendingHttp.delete(id);
        reject(e);
      }
    });
  }

  /// QuickJS 不一定有 URLSearchParams，自己拼。
  function buildQueryString(query) {
    if (!query || typeof query !== 'object') return '';
    var parts = [];
    for (var key in query) {
      if (!Object.prototype.hasOwnProperty.call(query, key)) continue;
      var value = query[key];
      if (value == null) continue;
      parts.push(encodeURIComponent(key) + '=' + encodeURIComponent(String(value)));
    }
    return parts.join('&');
  }

  function withQuery(url, query) {
    var qs = buildQueryString(query);
    if (!qs) return url;
    return url + (url.indexOf('?') >= 0 ? '&' : '?') + qs;
  }

  /// 兼容两种调用约定：
  /// - SDK/legacy 桥：`request({ permissionKey, url, method, ... })`
  /// - 插件业务代码：`request(url, { method, headers, ... })`
  /// 只认对象形式会导致拼接好的 query 丢失（服务端拿不到 songId 直接 403）。
  function universalRequest(first, second) {
    var opts = typeof first === 'string'
      ? Object.assign({}, second || {}, { url: first })
      : Object.assign({}, first || {});
    opts.url = withQuery(opts.url || '', opts.query);
    return httpRequest(opts);
  }

  function deliverHttp(id, payloadJson) {
    var entry = pendingHttp.get(id);
    if (!entry) return false;
    pendingHttp.delete(id);
    var payload;
    try {
      payload = JSON.parse(payloadJson);
    } catch (e) {
      entry.reject(new Error('HTTP 回执解析失败'));
      return true;
    }
    if (payload && payload.error) {
      entry.reject(new Error(String(payload.error)));
      return true;
    }
    // 插件 SDK 读 response.data，ours 读 body，两个都给
    entry.resolve({
      status: payload.status,
      statusCode: payload.status,
      headers: payload.headers || {},
      body: payload.body,
      data: payload.body,
      text: payload.text,
      url: payload.url,
    });
    return true;
  }

  // ------------------------------------------------------------------- ctx
  var providers = new Map();
  var actions = new Map();
  var lyricConverters = new Map();
  var effects = [];
  var configValues = {};
  var manifestRef = null;

  function makeOperation() {
    var cancelled = false;
    var signal = {
      aborted: false,
      reason: undefined,
      onabort: null,
      throwIfAborted: function () {
        if (cancelled) throw new Error('操作已取消');
      },
      addEventListener: function () {},
      removeEventListener: function () {},
    };
    return {
      id: 'op' + Math.random().toString(36).slice(2, 8),
      signal: signal,
      isCancelled: function () { return cancelled; },
      throwIfCancelled: function () {},
      cancel: function () { cancelled = true; signal.aborted = true; },
    };
  }

  function createHttpClient(options) {
    var opts = options || {};
    var baseURL = opts.baseURL || '';
    function join(url) {
      if (!url) return baseURL;
      if (/^https?:\/\//i.test(url)) return url;
      if (!baseURL) return url;
      return baseURL.replace(/\/+$/, '') + '/' + String(url).replace(/^\/+/, '');
    }
    function call(url, extra) {
      var merged = extra || {};
      var target = join(typeof url === 'string' ? url : (url && url.url));
      // 插件把查询参数放在 options.query 里，不拼进去服务端就收不到 songId
      target = withQuery(target, merged.query || opts.query);
      return httpRequest({
        url: target,
        method: merged.method || opts.method || 'GET',
        headers: Object.assign({}, opts.headers || {}, merged.headers || {}),
        body: merged.body,
        timeoutMs: merged.timeoutMs || opts.timeoutMs,
      });
    }
    return {
      baseURL: baseURL,
      request: function (url, extra) { return call(url, extra); },
      get: function (url, extra) { return call(url, Object.assign({}, extra, { method: 'GET' })); },
      post: function (url, body, extra) { return call(url, Object.assign({}, extra, { method: 'POST', body: body })); },
      put: function (url, body, extra) { return call(url, Object.assign({}, extra, { method: 'PUT', body: body })); },
      delete: function (url, extra) { return call(url, Object.assign({}, extra, { method: 'DELETE' })); },
    };
  }

  /// 插件常把 Error / 对象直接丢进 log，不序列化会只剩 [object Object]，
  /// 排查网络失败时等于没日志。
  function formatLogArgs(args) {
    var parts = [];
    for (var i = 0; i < args.length; i++) {
      var item = args[i];
      if (item instanceof Error) {
        parts.push((item.message || '') + (item.stack ? '\n' + item.stack.split('\n').slice(1, 3).join('\n') : ''));
      } else if (item && typeof item === 'object') {
        try { parts.push(safeJson(item)); } catch (e) { parts.push(String(item)); }
      } else {
        parts.push(String(item));
      }
    }
    return parts.join(' ');
  }

  function createCtx() {
    var ctx = {
      ns: (manifestRef && manifestRef.id) || 'ceru.plugin',
      plugin: {
        get id() { return (manifestRef && manifestRef.id) || ''; },
        get version() { return (manifestRef && manifestRef.version) || ''; },
        get manifest() { return manifestRef || {}; },
      },
      config: {
        get: function (key) {
          if (key == null) return configValues;
          return configValues[key];
        },
        getAll: function () { return configValues; },
        get apiUrl() { return configValues.apiUrl || ''; },
        get apiKey() { return configValues.apiKey || ''; },
      },
      log: {
        debug: function () {},
        info: function () {},
        warn: function () { logBridge('warn', formatLogArgs(arguments)); },
        error: function () { logBridge('error', formatLogArgs(arguments)); },
      },
      http: {
        create: function (opts) { return createHttpClient(opts); },
        request: universalRequest,
      },
      request: universalRequest,
      permissions: {
        query: function () { return Promise.resolve({ status: 'granted' }); },
        request: function () { return Promise.resolve({ status: 'granted' }); },
      },
      lifecycle: {
        onUpdate: function () { return { dispose: function () {} }; },
        onThemeChange: function () { return { dispose: function () {} }; },
        onLocaleChange: function () { return { dispose: function () {} }; },
        onIdle: function () { return { dispose: function () {} }; },
        onActivate: function () { return { dispose: function () {} }; },
        onDeactivate: function () { return { dispose: function () {} }; },
        onConfigChange: function () { return { dispose: function () {} }; },
        onPermissionChange: function () { return { dispose: function () {} }; },
      },
      ui: {
        toast: function (m) { logBridge('toast', String(m)); },
        playlistImport: { open: function () { return Promise.resolve(null); } },
        pluginUpdate: { prompt: function () { return Promise.resolve(false); } },
        confirm: function () { return Promise.resolve(true); },
        input: function () { return Promise.resolve(null); },
      },
      effects: {
        add: function (effect) { effects.push(effect); return effect; },
      },
      providers: {
        register: function (id, impl) {
          providers.set(String(id), impl);
          return { dispose: function () { providers.delete(String(id)); } };
        },
      },
      actions: {
        register: function (id, handler) {
          actions.set(String(id), handler);
          return { dispose: function () { actions.delete(String(id)); } };
        },
      },
      lyricConverters: {
        register: function (id, impl) {
          lyricConverters.set(String(id), impl);
          return { dispose: function () { lyricConverters.delete(String(id)); } };
        },
      },
      playback: {
        failure: function (info) {
          logBridge('playback', safeJson(info));
          return Promise.resolve(null);
        },
        report: function () { return Promise.resolve(null); },
      },
      playlistImporters: {
        register: function () { return { dispose: function () {} }; },
      },
    };
    return ctx;
  }

  // ----------------------------------------------------------- 宿主接口
  var state = { activated: false, error: null, providers: [] };

  function providerSummary() {
    var list = [];
    providers.forEach(function (impl, id) {
      var tracks = (impl && impl.tracks) || {};
      list.push({
        id: id,
        actions: Object.keys(tracks),
        hasSearch: typeof tracks.search === 'function',
        hasResolve: typeof tracks.resolve === 'function',
        hasLyrics: typeof tracks.lyrics === 'function',
        hasArtwork: typeof tracks.artworkHires === 'function',
      });
    });
    return list;
  }

  var resultSlots = Object.create(null);

  var api = {
    version: 'ceru-js@1',
    /** 载入插件源码，返回 manifest JSON（同步）。 */
    load: function (code) {
      providers.clear();
      actions.clear();
      lyricConverters.clear();
      effects.length = 0;
      state.activated = false;
      state.error = null;
      state.providers = [];

      global.exports = {};
      global.module = { exports: global.exports };
      (0, eval)(code);
      var exp = global.exports && global.exports.exports ? global.exports.exports : global.exports;
      global.__ceruPluginExports = exp;
      manifestRef = (exp && exp.manifest) || {};
      configValues = {};
      // 插件 manifest 里通常自带 config 默认值（apiUrl/apiKey 等），先用它兜底，
      // 用户再在界面上覆盖
      var defaults = manifestRef.config;
      if (defaults && typeof defaults === 'object') {
        for (var dk in defaults) {
          if (Object.prototype.hasOwnProperty.call(defaults, dk)) {
            configValues[dk] = defaults[dk];
          }
        }
      }
      var shareKeys = ((manifestRef.entry || {}).share || {}).configKeys || [];
      for (var i = 0; i < shareKeys.length; i++) {
        if (configValues[shareKeys[i]] == null) configValues[shareKeys[i]] = '';
      }
      return safeJson({ manifest: manifestRef, package: (exp && exp.package) || null });
    },

    /** 配置项（如 apiUrl / apiKey）。 */
    setConfig: function (json) {
      try {
        var parsed = JSON.parse(json);
        if (parsed && typeof parsed === 'object') {
          for (var k in parsed) {
            if (Object.prototype.hasOwnProperty.call(parsed, k)) configValues[k] = parsed[k];
          }
        }
        return safeJson({ ok: true, config: configValues });
      } catch (e) {
        return safeJson({ ok: false, error: String(e) });
      }
    },

    /** 启动插件（异步），宿主轮询 activateStatus()。 */
    beginActivate: function () {
      var exp = global.__ceruPluginExports;
      if (!exp || typeof exp.activate !== 'function') {
        state.error = '插件没有导出 activate()';
        return false;
      }
      try {
        Promise.resolve(exp.activate(createCtx())).then(
          function () {
            state.activated = true;
            state.providers = providerSummary();
          },
          function (err) {
            state.error = (err && err.message) || String(err);
          }
        );
      } catch (err) {
        state.error = (err && err.message) || String(err);
      }
      return true;
    },

    /** 激活状态：pending / ok / error。 */
    activateStatus: function () {
      if (state.error) return safeJson({ status: 'error', error: state.error });
      if (state.activated) return safeJson({ status: 'ok', providers: state.providers });
      return safeJson({ status: 'pending' });
    },

    providerList: function () {
      return safeJson(providerSummary());
    },

    /** 启动一个异步调用，结果写进槽位（宿主轮询 takeResult）。 */
    startCall: function (providerId, method, argsJson, callId) {
      var impl = providers.get(String(providerId));
      var tracks = impl && impl.tracks;
      if (!tracks || typeof tracks[method] !== 'function') {
        resultSlots[callId] = safeJson({ ok: false, error: '插件不支持 ' + providerId + '.' + method });
        return;
      }
      var args = [];
      try {
        args = JSON.parse(argsJson || '[]');
      } catch (e) {
        args = [];
      }
      var op = makeOperation();
      args.push(op);
      Promise.resolve(tracks[method].apply(tracks, args)).then(
        function (value) {
          resultSlots[callId] = safeJson({ ok: true, value: value === undefined ? null : value });
        },
        function (err) {
          resultSlots[callId] = safeJson({ ok: false, error: (err && err.message) || String(err) });
        }
      );
    },

    /** 取结果：无结果返回 null，有则返回 JSON 并清空。 */
    takeResult: function (callId) {
      if (!Object.prototype.hasOwnProperty.call(resultSlots, callId)) return null;
      var value = resultSlots[callId];
      delete resultSlots[callId];
      return value;
    },

    deliverHttp: deliverHttp,

    pendingHttpCount: function () {
      return pendingHttp.size;
    },
  };

  global.__ceru = api;
})(globalThis);
