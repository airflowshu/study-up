/**
 * 链接预览：抓目标页面的标题 / 描述 / 缩略图，给家长端的「链接卡片」用。
 *
 * 为什么放在服务端而不是浏览器里直接抓：
 * 浏览器 fetch 第三方页面要对方回 `Access-Control-Allow-Origin`，而家长最常粘的
 * 恰恰是公众号、图书平台这类不回声明的站点，前端一抓就是 CORS 失败。
 * 手机 App 没这个限制，所以预览逻辑先做在客户端；Web 端只能借服务端绕过去。
 *
 * 安全上按「这是一个可以读任意 URL 的接口」来防：
 *   - 只允许 http / https；
 *   - 解析出的 IP 必须不是内网 / 回环 / 链路本地（否则等于把家里的 NAS、
 *     云厂商元数据接口暴露给任何拿到家庭码的人）；
 *   - 重定向逐跳重新校验，最多 3 跳 —— 一个 302 就能把上面的检查绕过去；
 *   - 5 秒超时、最多读 512 KB，超了就按读到的部分解析；
 *   - 只做正则解析，不执行脚本、不渲染页面。
 */
import { lookup } from 'node:dns/promises'
import type { FastifyInstance } from 'fastify'
import { requireAuth } from '../auth/guard.js'
import { badRequest, forbidden } from '../errors.js'

interface Preview {
  url: string
  title: string
  desc: string
  image: string
  site: string
}

const TIMEOUT_MS = 5000
const MAX_BYTES = 512 * 1024
const MAX_HOPS = 3
const CACHE_TTL_MS = 10 * 60 * 1000
const CACHE_MAX = 200

/** 简单的 TTL 缓存：同一篇公众号文章常被反复粘贴，没必要每次都去抓。 */
const cache = new Map<string, { at: number; data: Preview }>()

function cacheGet(key: string): Preview | null {
  const hit = cache.get(key)
  if (!hit) return null
  if (Date.now() - hit.at > CACHE_TTL_MS) {
    cache.delete(key)
    return null
  }
  return hit.data
}

function cacheSet(key: string, data: Preview): void {
  if (cache.size >= CACHE_MAX) {
    const oldest = [...cache.entries()].sort((a, b) => a[1].at - b[1].at)[0]
    if (oldest) cache.delete(oldest[0])
  }
  cache.set(key, { at: Date.now(), data })
}

/** 内网 / 回环 / 链路本地，一律不许访问。 */
function isPrivateIp(ip: string): boolean {
  if (ip.includes(':')) {
    const v6 = ip.toLowerCase()
    return (
      v6 === '::1' ||
      v6 === '::' ||
      v6.startsWith('fc') ||
      v6.startsWith('fd') ||
      v6.startsWith('fe80') ||
      v6.startsWith('::ffff:127.') ||
      v6.startsWith('::ffff:10.') ||
      v6.startsWith('::ffff:192.168.')
    )
  }
  const parts = ip.split('.').map(Number)
  if (parts.length !== 4 || parts.some((n) => !Number.isFinite(n))) return true
  const a = parts[0] ?? 0
  const b = parts[1] ?? 0
  return (
    a === 0 ||
    a === 10 ||
    a === 127 ||
    (a === 169 && b === 254) ||
    (a === 172 && b >= 16 && b <= 31) ||
    (a === 192 && b === 168) ||
    a >= 224
  )
}

async function assertPublicUrl(raw: string): Promise<URL> {
  let url: URL
  try {
    url = new URL(raw)
  } catch {
    throw badRequest('这不是一个有效的网址')
  }
  if (url.protocol !== 'http:' && url.protocol !== 'https:') {
    throw badRequest('只支持 http / https 链接')
  }
  const host = url.hostname.replace(/^\[|\]$/g, '')
  // 直接写 IP 的，不用查 DNS
  if (/^[\d.]+$/.test(host) || host.includes(':')) {
    if (isPrivateIp(host)) throw forbidden('不允许访问内网地址')
    return url
  }
  let addrs: { address: string }[]
  try {
    addrs = await lookup(host, { all: true })
  } catch {
    throw badRequest('这个网址解析不到，检查一下有没有写错')
  }
  if (!addrs.length) throw badRequest('这个网址解析不到，检查一下有没有写错')
  if (addrs.every((a) => isPrivateIp(a.address))) {
    throw forbidden('不允许访问内网地址')
  }
  return url
}

/** 逐个 meta 标签解析，不依赖属性顺序（两种写法线上都常见）。 */
function metaTags(html: string): Map<string, string> {
  const out = new Map<string, string>()
  const re = /<meta\b[^>]*>/gi
  let m: RegExpExecArray | null
  while ((m = re.exec(html))) {
    const tag = m[0]
    const key = /(?:property|name)\s*=\s*["']([^"']+)["']/i.exec(tag)?.[1]
    const content = /content\s*=\s*["']([^"']*)["']/i.exec(tag)?.[1]
    if (key && content != null && !out.has(key.toLowerCase())) {
      out.set(key.toLowerCase(), content)
    }
  }
  return out
}

function decodeEntities(s: string): string {
  return s
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"')
    .replace(/&#39;/g, "'")
    .replace(/&nbsp;/g, ' ')
    .replace(/&amp;/g, '&')
    .replace(/&#(\d+);/g, (_, d: string) => String.fromCharCode(Number(d)))
    .replace(/\s+/g, ' ')
    .trim()
}

function pick(html: string, finalUrl: URL): Preview {
  const meta = metaTags(html)
  const titleTag = /<title[^>]*>([\s\S]*?)<\/title>/i.exec(html)?.[1] ?? ''

  const title =
    decodeEntities(meta.get('og:title') ?? '') ||
    decodeEntities(meta.get('twitter:title') ?? '') ||
    decodeEntities(titleTag)

  const desc =
    decodeEntities(meta.get('og:description') ?? '') ||
    decodeEntities(meta.get('description') ?? '') ||
    decodeEntities(meta.get('twitter:description') ?? '')

  const site =
    decodeEntities(meta.get('og:site_name') ?? '') || finalUrl.hostname

  let image = meta.get('og:image') ?? meta.get('twitter:image') ?? ''
  if (image) {
    try {
      image = new URL(decodeEntities(image), finalUrl).toString()
    } catch {
      image = ''
    }
  }

  return {
    url: finalUrl.toString(),
    title: title.slice(0, 200),
    desc: desc.slice(0, 300),
    image: image.slice(0, 1000),
    site: site.slice(0, 100),
  }
}

/** 读前 N 字节就停，别让一个 500 MB 的视频地址把内存吃光。 */
async function readCapped(res: Response): Promise<string> {
  const reader = res.body?.getReader()
  if (!reader) return ''
  const chunks: Uint8Array[] = []
  let total = 0
  while (total < MAX_BYTES) {
    const { done, value } = await reader.read()
    if (done) break
    if (value) {
      chunks.push(value)
      total += value.byteLength
    }
  }
  await reader.cancel().catch(() => {})
  const buf = new Uint8Array(Math.min(total, MAX_BYTES))
  let off = 0
  for (const c of chunks) {
    if (off >= buf.length) break
    const slice = c.subarray(0, Math.min(c.byteLength, buf.length - off))
    buf.set(slice, off)
    off += slice.byteLength
  }
  // 只取 charset 里声明的编码；国内仍有 GBK 页面，解错顶多标题乱码，
  // 不影响链接本身可用，所以不做编码嗅探。
  const charset = /charset=["']?([\w-]+)/i.exec(res.headers.get('content-type') ?? '')?.[1]
  try {
    return new TextDecoder(charset ?? 'utf-8', { fatal: false }).decode(buf)
  } catch {
    return new TextDecoder('utf-8', { fatal: false }).decode(buf)
  }
}

async function fetchPreview(rawUrl: string): Promise<Preview> {
  let url = await assertPublicUrl(rawUrl)
  const signal = AbortSignal.timeout(TIMEOUT_MS)

  for (let hop = 0; hop <= MAX_HOPS; hop += 1) {
    const res = await fetch(url, {
      redirect: 'manual',
      signal,
      headers: {
        // 不少站点对陌生 UA 直接 403，伪装成普通浏览器
        'User-Agent':
          'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 ' +
          '(KHTML, like Gecko) Chrome/124.0 Safari/537.36',
        'Accept-Language': 'zh-CN,zh;q=0.9',
        Accept: 'text/html,application/xhtml+xml',
      },
    })

    if (res.status >= 300 && res.status < 400) {
      const loc = res.headers.get('location')
      if (!loc) break
      // 逐跳校验：不然一个公网地址 302 到 127.0.0.1 就绕过了前面的检查
      url = await assertPublicUrl(new URL(loc, url).toString())
      continue
    }
    if (!res.ok) throw badRequest(`对方网站返回 ${res.status}，抓不到预览`)
    return pick(await readCapped(res), url)
  }
  throw badRequest('这个链接跳转太多次，抓不到预览')
}

export async function linkRoutes(app: FastifyInstance): Promise<void> {
  app.get(
    '/v1/link/preview',
    { preHandler: requireAuth },
    async (req, reply) => {
      const raw = String((req.query as { url?: unknown }).url ?? '').trim()
      if (!raw) throw badRequest('缺少 url 参数')
      if (raw.length > 2000) throw badRequest('网址太长了')

      const cached = cacheGet(raw)
      if (cached) return reply.send(cached)

      const data = await fetchPreview(raw)
      cacheSet(raw, data)
      return reply.send(data)
    },
  )
}
