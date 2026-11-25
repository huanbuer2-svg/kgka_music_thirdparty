/**
 * MusicFree 插件运行时垫片
 * ============================================================================
 * MusicFree 插件是「CommonJS 模块」：执行后 `module.exports` 暴露
 * `search` / `getMediaSource` / `getLyric` / `getTopLists` 等方法。
 *
 * QuickJS 里没有 fetch、没有 setTimeout，插件会用 axios（可缺失）或 fetch，
 * 所以这里补齐 fetch / setTimeout / clearTimeout / AbortController，并把
 * HTTP 通过 `__mfSend` 桥接给宿主（与 lx / ceru 同样的单向通道 + 轮询取结果）。
 * ============================================================================
 */
(function (global) {
  'use strict';

  var sendBridge = global.__mfSend || function () {};
  var logBridge = global.__mfLog || function () {};

  var httpSeq = 0;
  var pendingHttp = Object.create(null);
  var timers = [];
  var timerSeq = 0;
  var resultSlots = Object.create(null);

  // ------------------------------------------------------- 定时器（QuickJS 没有）
  global.setTimeout = function (fn, ms) {
    var id = ++timerSeq;
    timers.push({ id: id, fn: fn, at: Date.now() + (Number(ms) || 0) });
    return id;
  };
  global.clearTimeout = function (id) {
    for (var i = timers.length - 1; i >= 0; i--) {
      if (timers[i].id === id) timers.splice(i, 1);
    }
  };
  global.setInterval = function (fn, ms) {
    // 插件很少用；给个不循环的实现避免卡死
    return global.setTimeout(fn, ms);
  };
  global.clearInterval = global.clearTimeout;

  if (typeof global.AbortController === 'undefined') {
    global.AbortController = function () {
      var self = this;
      self.signal = { aborted: false, onabort: null, addEventListener: function () {}, removeEventListener: function () {} };
      self.abort = function () {
        self.signal.aborted = true;
      };
    };
  }

  // ---------------------------------------------------------------------- fetch
  function buildResponse(payload) {
    var text = payload.text == null ? '' : String(payload.text);
    var headers = payload.headers || {};
    return {
      ok: payload.status >= 200 && payload.status < 300,
      status: payload.status,
      statusText: String(payload.status || ''),
      url: payload.url || '',
      headers: {
        get: function (name) { return headers[String(name).toLowerCase()]; },
        has: function (name) { return headers[String(name).toLowerCase()] != null; },
        forEach: function (cb) {
          for (var k in headers) {
            if (Object.prototype.hasOwnProperty.call(headers, k)) cb(headers[k], k);
          }
        },
      },
      text: function () { return Promise.resolve(text); },
      json: function () {
        try {
          return Promise.resolve(JSON.parse(text));
        } catch (e) {
          return Promise.reject(e);
        }
      },
      arrayBuffer: function () {
        var bytes = new Uint8Array(text.length);
        for (var i = 0; i < text.length; i++) bytes[i] = text.charCodeAt(i) & 0xff;
        return Promise.resolve(bytes.buffer);
      },
    };
  }

  global.fetch = function (url, options) {
    var opts = options || {};
    return new Promise(function (resolve, reject) {
      var id = 'r' + ++httpSeq;
      pendingHttp[id] = { resolve: resolve, reject: reject };
      try {
        sendBridge(
          'musicfree',
          JSON.stringify({
            type: 'http',
            id: id,
            url: typeof url === 'string' ? url : String(url && url.url),
            method: opts.method || 'GET',
            headers: opts.headers || {},
            body: opts.body,
            timeoutMs: 20000,
          })
        );
      } catch (e) {
        delete pendingHttp[id];
        reject(e);
      }
    });
  };

  function deliverHttp(id, payloadJson) {
    var entry = pendingHttp[id];
    if (!entry) return false;
    delete pendingHttp[id];
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
    entry.resolve(buildResponse(payload));
    return true;
  }

  // ------------------------------------------------------------------- 宿主接口
  var pluginExports = null;

  function mfApi() {
    if (!pluginExports) throw new Error('插件尚未加载');
    return pluginExports;
  }

  function normalizeItems(list) {
    var out = [];
    if (!list || !list.length) return out;
    for (var i = 0; i < list.length; i++) {
      var item = list[i] || {};
      out.push({
        id: String(item.id || item._songId || item._rid || ''),
        title: String(item.title || item.name || '未知歌曲'),
        artist: String(item.artist || item.singer || ''),
        album: item.album ? String(item.album) : '',
        artwork: item.artwork || item.cover || item.pic || '',
        duration: Number(item.duration) || 0,
        lrc: item.lrc || null,
        raw: item,
      });
    }
    return out;
  }

  global.__mf = {
    version: 'musicfree@1',

    load: function (code) {
      pluginExports = null;
      global.module = { exports: {} };
      global.exports = global.module.exports;
      if (typeof global.require === 'undefined') {
        // 插件第一行就会 try require('axios')，返回 null 让它走 fetch 兜底
        global.require = function () { return null; };
      }
      (0, eval)(code);
      pluginExports = global.module.exports || {};
      return JSON.stringify({
        platform: pluginExports.platform || '',
        version: pluginExports.version || '',
        author: pluginExports.author || '',
        description: pluginExports.description || '',
        srcUrl: pluginExports.srcUrl || '',
        supportedSearchType: pluginExports.supportedSearchType || ['music'],
        hasSearch: typeof pluginExports.search === 'function',
        hasMediaSource: typeof pluginExports.getMediaSource === 'function',
        hasLyric: typeof pluginExports.getLyric === 'function',
        hasTopLists: typeof pluginExports.getTopLists === 'function',
        primaryKey: pluginExports.primaryKey || [],
      });
    },

    info: function () {
      return JSON.stringify({ platform: mfApi().platform || '' });
    },

    /** 启动一次异步调用，结果写槽位；宿主轮询 takeResult。 */
    startCall: function (method, argsJson, callId) {
      var api = pluginExports || {};
      var fn = api[method];
      if (typeof fn !== 'function') {
        resultSlots[callId] = JSON.stringify({ ok: false, error: '插件不支持 ' + method });
        return;
      }
      var args = [];
      try { args = JSON.parse(argsJson || '[]'); } catch (e) { args = []; }
      Promise.resolve(fn.apply(api, args)).then(
        function (value) {
          if (method === 'search' || method === 'getTopListDetail') {
            var page = value || {};
            resultSlots[callId] = JSON.stringify({
              ok: true,
              value: {
                isEnd: page.isEnd !== false,
                total: Number(page.total) || undefined,
                items: normalizeItems(page.data || []),
              },
            });
          } else {
            resultSlots[callId] = JSON.stringify({ ok: true, value: value === undefined ? null : value });
          }
        },
        function (err) {
          var message = err && err.message ? err.message : String(err);
          logBridge('error', method + ' 失败: ' + message);
          resultSlots[callId] = JSON.stringify({ ok: false, error: message });
        }
      );
    },

    takeResult: function (callId) {
      if (!Object.prototype.hasOwnProperty.call(resultSlots, callId)) return null;
      var value = resultSlots[callId];
      delete resultSlots[callId];
      return value;
    },

    deliverHttp: deliverHttp,

    /** 宿主轮询时调用，触发到期的定时器（插件的超时/重试依赖它）。 */
    pumpTimers: function () {
      if (!timers.length) return 0;
      var now = Date.now();
      var due = [];
      for (var i = timers.length - 1; i >= 0; i--) {
        if (timers[i].at <= now) {
          due.push(timers[i]);
          timers.splice(i, 1);
        }
      }
      for (var j = 0; j < due.length; j++) {
        try { due[j].fn(); } catch (e) { logBridge('error', 'timer 异常: ' + e); }
      }
      return due.length;
    },

    pendingHttpCount: function () {
      var n = 0;
      for (var k in pendingHttp) {
        if (Object.prototype.hasOwnProperty.call(pendingHttp, k)) n++;
      }
      return n;
    },
  };
})(globalThis);
