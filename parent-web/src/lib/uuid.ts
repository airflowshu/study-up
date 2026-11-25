/**
 * UUID 生成。
 *
 * 为什么不直接用 `crypto.randomUUID()`：它只在安全上下文（HTTPS 或 localhost）
 * 才存在。如果拿 `http://192.168.x.x:8787` 打开页面，这个函数是 undefined，
 * 而 `deviceId()` 和 `newId()` 都在请求链路的必经之路上——
 * 结果是整站白屏级故障，且报错信息完全指不到根因。
 *
 * getRandomValues 没有这个限制，所以退路要写在这里。
 */
export function randomId(): string {
  if (typeof crypto !== 'undefined' && typeof crypto.randomUUID === 'function') {
    return crypto.randomUUID()
  }

  const bytes = new Uint8Array(16)
  crypto.getRandomValues(bytes)

  // 按 RFC 4122 打上 v4 与变体位，否则某些后端会当成非法 UUID
  bytes[6] = (bytes[6]! & 0x0f) | 0x40
  bytes[8] = (bytes[8]! & 0x3f) | 0x80

  const hex = Array.from(bytes, (b) => b.toString(16).padStart(2, '0'))
  return [
    hex.slice(0, 4).join(''),
    hex.slice(4, 6).join(''),
    hex.slice(6, 8).join(''),
    hex.slice(8, 10).join(''),
    hex.slice(10, 16).join(''),
  ].join('-')
}

/** 设备 id：32 位无连字符，和 Flutter 端 deviceId 的形态保持一致。 */
export function randomDeviceId(): string {
  return randomId().replace(/-/g, '')
}
