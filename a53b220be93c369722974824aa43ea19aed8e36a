/*!
 * @name 自测音源
 * @description 仅用于验证宿主协议，不联网
 * @version 1.0.0
 * @author kgka
 */

const { EVENT_NAMES, request, on, send } = globalThis.lx

on(EVENT_NAMES.request, ({ action, source, info }) => {
  if (action !== 'musicUrl') return Promise.reject('action not support')
  return new Promise((resolve, reject) => {
    // 故意请求一个必然失败的地址：验证「HTTP 失败回调 → 脚本自行兜底」这条路径
    request('http://127.0.0.1:1/never', { method: 'GET' }, (err) => {
      if (!err) return reject(new Error('本不该成功'))
      console.log('预期内的请求失败：', err.statusMessage ?? err.error)
      resolve('https://example.com/' + (info.musicInfo.hash || 'nohash') + '.mp3')
    })
  })
})

send(EVENT_NAMES.inited, {
  status: true,
  openDevTools: false,
  sources: {
    kg: {
      name: 'kg',
      type: 'music',
      actions: ['musicUrl'],
      qualitys: ['128k', '320k']
    }
  }
})
