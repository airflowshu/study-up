/**
 * 腾讯云 COS 直传支持。
 *
 * 为什么要有这个东西：图片经 Cloudflare 隧道往返（隧道落在洛杉矶）时，
 * 上行只有 30-100KB/s，下行约 90KB/s，一张 500KB 的作业图要等十几秒。
 * 改成客户端拿预签名 URL 直传 COS 之后，上传和读图都走国内链路。
 *
 * 三个刻意的设计：
 *
 *   1. **密钥不出服务端**。客户端拿到的是一个限定了 key 和有效期的 PUT 预签名 URL，
 *      用完之后失效，泄不出去也改不了别的对象。
 *   2. **未配置就退回原路径**。COS_* 环境变量没填时，presign 返回 501、config 返回 null，
 *      客户端继续走 NAS 本地存储。这样服务端可以先上线，客户端晚一步跟上。
 *   3. **读旧图要能兜住**。改成 COS 之后，本地 volume 里的老文件还得能读，
 *      所以 storage 路由在本地找不到文件时会 302 到 COS。
 */
import crypto from 'node:crypto'
import { config } from './config.js'

const hmac = (key: string, data: string): string =>
  crypto.createHmac('sha1', key).update(data, 'utf8').digest('hex')

const sha1 = (data: string): string =>
  crypto.createHash('sha1').update(data, 'utf8').digest('hex')

/** COS 是否配置齐全。缺任何一项都当作未启用。 */
export function cosEnabled(): boolean {
  return Boolean(
    config.cos.secretId && config.cos.secretKey && config.cos.bucket && config.cos.region,
  )
}

/**
 * 桶的公网 origin（不含末尾斜杠）。
 *
 * 用途只有一个：拼进 CSP 白名单。浏览器的 CSP 是「默认全拒」，
 * `connect-src 'self'` 会把直传 COS 的 fetch 直接拦成 `Failed to fetch`，
 * `img-src 'self'` 会让 COS 上的图裂掉 —— 而且报错信息只有一句
 * "Failed to fetch"，在网络面板里看不到任何请求，极难定位。
 * 所以只要启用了 COS，就必须把它的 origin 放进这两条指令。
 *
 * 只放这一个精确 origin，不用通配，避免把整条 CSP 放成 `*`。
 */
export function cosOrigin(): string | null {
  if (!cosEnabled()) return null
  return `https://${config.cos.bucket}.cos.${config.cos.region}.myqcloud.com`
}

/** 对象公网地址前缀，客户端拼读图地址用。未启用时返回 null。 */
export function cosImageBase(): string | null {
  if (!cosEnabled()) return null
  return `https://${config.cos.bucket}.cos.${config.cos.region}.myqcloud.com`
}

/** 对象公网直链。 */
export function cosObjectUrl(key: string): string | null {
  const base = cosImageBase()
  if (!base) return null
  return `${base}/${key.split('/').map(encodeURIComponent).join('/')}`
}

/**
 * APK 在 COS 里的公网地址。
 * 存储路径统一加 `apk/` 前缀，和本地卷 `<DATA_DIR>/uploads/apk/<key>` 对应，
 * 这样同一个 key 在两种存储下语义一致，迁移时不用改客户端的理解。
 */
export function cosApkUrl(key: string): string | null {
  return cosObjectUrl(`apk/${key}`)
}

/**
 * 生成 PUT 预签名 URL（q-sign-algorithm=sha1）。
 *
 * Content-Type 必须一起签：不签的话同一个 URL 可以被拿去传任意类型的内容。
 * 客户端 PUT 时也必须带完全相同的 Content-Type，否则 COS 会拒。
 *
 * cacheControl 也走同一套机制：它是**对象元数据**，只能在写入时定，
 * 事后改必须发 copy 请求。图片 key 里的 slot 是随机唯一标识、永不复用，
 * 所以可以放心给一年的 immutable 缓存 —— 少一次重复下载就是省一份流量费。
 */
export function signPutUrl(
  key: string,
  contentType: string,
  expiresIn = 900,
  cacheControl?: string,
): string {
  const host = `${config.cos.bucket}.cos.${config.cos.region}.myqcloud.com`
  const pathname = key.split('/').map(encodeURIComponent).join('/')

  const now = Math.floor(Date.now() / 1000)
  const keyTime = `${now};${now + expiresIn}`
  const signKey = hmac(config.cos.secretKey, keyTime)

  // header-list 必须按字典序用 `;` 连接，headerString 按同样顺序用 `&` 连接；
  // 列进来的头，客户端必须一个不落地带上，否则签名对不上。
  const signed: Record<string, string> = { 'content-type': contentType }
  if (cacheControl) signed['cache-control'] = cacheControl
  const names = [...Object.keys(signed), 'host'].sort()
  const headerList = names.join(';')
  const headerString = names
    .map((n) => `${n}=${encodeURIComponent(n === 'host' ? host : (signed[n] ?? ''))}`)
    .join('&')

  const paramList = ''
  const httpString = `put\n/${pathname}\n\n${headerString}\n`
  const stringToSign = `sha1\n${keyTime}\n${sha1(httpString)}\n`
  const signature = hmac(signKey, stringToSign)

  const query = [
    'q-sign-algorithm=sha1',
    `q-ak=${encodeURIComponent(config.cos.secretId)}`,
    `q-sign-time=${keyTime}`,
    `q-key-time=${keyTime}`,
    `q-header-list=${headerList}`,
    `q-url-param-list=${paramList}`,
    `q-signature=${signature}`,
  ].join('&')

  return `https://${host}/${pathname}?${query}`
}

/**
 * Node 的 fetch 能接受流式 body，但 @types/node 没有把 BodyInit 暴露成全局类型，
 * 这里从 fetch 的签名里把它取出来。
 */
type FetchInit = NonNullable<Parameters<typeof fetch>[1]>

/**
 * 把请求体直接流式搬到 COS。APK 有 50MB，不能先读进内存再传——
 * 512MB 的容器内存顶得住一次，顶不住两次并发。
 */
export async function cosPutStream(
  key: string,
  contentType: string,
  body: FetchInit['body'],
): Promise<void> {
  const url = signPutUrl(key, contentType, 3600)
  const res = await fetch(url, {
    method: 'PUT',
    headers: { 'Content-Type': contentType },
    body,
    // Node 的 fetch 传流式 body 必须显式声明半双工，否则直接报错
    duplex: 'half',
  } as FetchInit & { duplex: 'half' })

  if (!res.ok) {
    const text = await res.text().catch(() => '')
    throw new Error(`COS 上传失败 HTTP ${res.status} ${text.slice(0, 200)}`)
  }
}
