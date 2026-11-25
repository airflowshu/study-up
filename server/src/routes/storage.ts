/**
 * 对象存储通道：`/v1/storages/object/:bucket/*`。
 *
 * 路径形态照抄原 CloudBase：`<bucket>/<key>`，key 里可以带斜杠。
 * 但两件事和以前不一样：
 *
 *   1. 上传要求 Bearer，且 key 必须以 `f/<自己的 familyId>/` 开头。
 *      别人家的家庭 id 猜不到，但猜到了也写不进去。
 *   2. 读保持公开（`<img>` 标签带不了 Authorization 头），
 *      靠 key 里的 UUID 不可枚举来防扫。这是明确接受的取舍。
 */
import { createReadStream } from 'node:fs'
import { mkdir, rename, stat, unlink, writeFile } from 'node:fs/promises'
import { dirname, join, posix } from 'node:path'
import { pipeline } from 'node:stream/promises'
import { createWriteStream } from 'node:fs'
import type { FastifyInstance, FastifyReply, FastifyRequest } from 'fastify'
import { config } from '../config.js'
import { cosObjectUrl } from '../cos.js'
import { requireAuth } from '../auth/guard.js'
import { badRequest, forbidden, notFound, tooLarge } from '../errors.js'

const root = (): string => join(config.dataDir, 'uploads')

/** 防路径穿越。`..` 一律拒绝，规范化后必须还在根目录之下。 */
function safeKey(rawKey: string): string {
  const decoded = decodeURIComponent(rawKey)
  const normalized = posix.normalize(decoded).replace(/^\/+/, '')
  if (
    normalized.length === 0 ||
    normalized.startsWith('..') ||
    normalized.split('/').includes('..')
  ) {
    throw forbidden('路径不合法')
  }
  return normalized
}

function params(req: FastifyRequest): { bucket: string; key: string } {
  const p = req.params as { bucket?: string; '*': string }
  const bucket = String(p.bucket ?? '')
  if (bucket !== 'homework' && bucket !== 'apk') {
    throw notFound('没有这个存储桶')
  }
  return { bucket, key: safeKey(p['*'] ?? '') }
}

function contentTypeOf(key: string): string {
  const ext = key.slice(key.lastIndexOf('.') + 1).toLowerCase()
  switch (ext) {
    case 'png':
      return 'image/png'
    case 'webp':
      return 'image/webp'
    case 'gif':
      return 'image/gif'
    case 'jpg':
    case 'jpeg':
      return 'image/jpeg'
    case 'pdf':
      return 'application/pdf'
    case 'docx':
      return 'application/vnd.openxmlformats-officedocument.wordprocessingml.document'
    case 'apk':
      return 'application/vnd.android.package-archive'
    default:
      return 'application/octet-stream'
  }
}

/** 解析单段 Range。只支持最常见的 `bytes=start-end`。 */
function parseRange(
  header: string | undefined,
  size: number,
): { start: number; end: number } | null {
  if (!header) return null
  const m = /^bytes=(\d*)-(\d*)$/.exec(header.trim())
  if (!m) return null

  const startRaw = m[1] ?? ''
  const endRaw = m[2] ?? ''
  if (!startRaw && !endRaw) return null

  let start: number
  let end: number
  if (!startRaw) {
    // bytes=-500 → 最后 500 字节
    const tail = Number(endRaw)
    if (!Number.isFinite(tail) || tail <= 0) return null
    start = Math.max(0, size - tail)
    end = size - 1
  } else {
    start = Number(startRaw)
    end = endRaw ? Number(endRaw) : size - 1
  }

  if (!Number.isFinite(start) || !Number.isFinite(end)) return null
  if (start > end || start >= size) return null
  return { start, end: Math.min(end, size - 1) }
}

export async function storageRoutes(app: FastifyInstance): Promise<void> {
  // ---- 上传 ----
  app.post(
    '/v1/storages/object/:bucket/*',
    {
      preHandler: requireAuth,
      // 全局 1MB 是给 JSON 用的；图片这一条单独放宽
      bodyLimit: config.maxImageBytes + 1024 * 1024,
    },
    async (req: FastifyRequest, reply: FastifyReply) => {
      const auth = req.auth
      if (!auth) throw forbidden()

      const { bucket, key } = params(req)

      if (bucket === 'apk') {
        throw forbidden('APK 请走 /v1/admin/apk 接口')
      }

      // 图片只能写进自己家庭的前缀。前缀不对说明客户端没升级或有人在试探。
      const expectedPrefix = `f/${auth.familyId}/`
      if (!key.startsWith(expectedPrefix)) {
        throw forbidden('上传路径不属于当前家庭')
      }

      const declared = String(req.headers['content-type'] ?? '')
      const mime = declared.split(';')[0]?.trim().toLowerCase() ?? ''
      if (!config.allowedUploadMime.has(mime)) {
        throw badRequest('只支持图片 / PDF / DOCX')
      }

      const len = Number(req.headers['content-length'] ?? 0)
      if (Number.isFinite(len) && len > config.maxImageBytes) {
        throw tooLarge(`单个文件不能超过 ${Math.floor(config.maxImageBytes / 1048576)} MB`)
      }

      const target = join(root(), bucket, key)
      await mkdir(dirname(target), { recursive: true })

      const body = req.body as NodeJS.ReadableStream | Buffer | undefined
      if (!body) throw badRequest('没有收到文件内容')

      if (Buffer.isBuffer(body)) {
        if (body.byteLength > config.maxImageBytes) throw tooLarge('文件太大')
        await writeFile(target, body)
      } else {
        // 流式落盘：先写 .part 再 rename，避免断电留下半张图被当成完整图读出
        const tmp = `${target}.part`
        try {
          await pipeline(body, createWriteStream(tmp))
          await rename(tmp, target)
        } catch (e) {
          await unlink(tmp).catch(() => undefined)
          throw e
        }
      }

      return reply.code(200).send({ key })
    },
  )

  // ---- 读取（公开） ----
  app.get('/v1/storages/object/:bucket/*', async (req, reply) => {
    const { bucket, key } = params(req)
    const file = join(root(), bucket, key)

    let size: number
    try {
      const st = await stat(file)
      if (!st.isFile()) throw notFound()
      size = st.size
    } catch {
      // 图片改走 COS 之后，本地没有的文件要去 COS 找。
      // 302 而不是代理转发：让客户端直连 COS，不把流量再绕回这台 NAS。
      // 这样还没升级的客户端（仍拼本地路径读图）也能看到新图。
      // APK 不在 COS（默认域名禁止分发 APK），所以这里只管 homework 桶。
      if (bucket === 'homework') {
        const remote = cosObjectUrl(key)
        if (remote) return reply.redirect(remote, 302)
      }
      throw notFound('图片不存在')
    }

    const type = contentTypeOf(key)
    const base = {
      'Content-Type': type,
      'Cache-Control': 'public, max-age=31536000, immutable',
      'Accept-Ranges': 'bytes',
      'X-Content-Type-Options': 'nosniff',
    }

    const range = parseRange(req.headers.range, size)
    if (range) {
      const { start, end } = range
      reply.code(206)
      reply.headers({
        ...base,
        'Content-Range': `bytes ${start}-${end}/${size}`,
        'Content-Length': String(end - start + 1),
      })
      return reply.send(createReadStream(file, { start, end }))
    }

    reply.headers({ ...base, 'Content-Length': String(size) })
    return reply.send(createReadStream(file))
  })
}
