/**
 * 运维接口。用 `X-Admin-Token` 保护，只给发版脚本用，客户端不接触。
 */
import { createWriteStream } from 'node:fs'
import { mkdir, rename, unlink } from 'node:fs/promises'
import { dirname, join, posix } from 'node:path'
import { pipeline } from 'node:stream/promises'
import { timingSafeEqual } from 'node:crypto'
import type { FastifyInstance, FastifyReply, FastifyRequest } from 'fastify'
import { config } from '../config.js'

import { badRequest, forbidden, tooLarge, unauthorized } from '../errors.js'
import { pool } from '../db/pool.js'

function checkAdmin(req: FastifyRequest): void {
  const raw = req.headers['x-admin-token']
  const given = typeof raw === 'string' ? raw : ''
  const expected = config.adminToken

  // 长度不同直接拒；长度相同时用定时安全比较，避免逐字节试出令牌
  const a = Buffer.from(given)
  const b = Buffer.from(expected)
  if (a.length !== b.length || !timingSafeEqual(a, b)) {
    throw unauthorized('管理令牌不对')
  }
}

export async function adminRoutes(app: FastifyInstance): Promise<void> {
  // ---- 上传 APK ----
  app.put('/v1/admin/apk/*', { bodyLimit: config.maxApkBytes + 1024 * 1024 }, async (req: FastifyRequest, reply: FastifyReply) => {
    checkAdmin(req)

    const p = req.params as { '*': string }
    const key = posix.normalize(decodeURIComponent(p['*'] ?? '')).replace(/^\/+/, '')
    if (!key || key.split('/').includes('..') || !key.endsWith('.apk')) {
      throw badRequest('APK 路径不合法')
    }

    const len = Number(req.headers['content-length'] ?? 0)
    if (Number.isFinite(len) && len > config.maxApkBytes) {
      throw tooLarge('APK 超过大小上限')
    }

    // 必须流式：50MB 的包缓冲进内存会把 512MB 的容器顶爆
    const body = req.body as NodeJS.ReadableStream | Buffer | undefined
    if (!body) throw badRequest('没有收到文件内容')

    const target = join(config.dataDir, 'uploads', 'apk', key)
    await mkdir(dirname(target), { recursive: true })

    // 曾经试过把 APK 也放 COS，走不通：COS 默认域名禁止分发 APK/IPA，
    // 下载会返回 DownloadForbidden，官方要求绑自定义域名（要备案）。
    // 所以 APK 继续存本地卷，经隧道分发；图片走 COS 不受这条限制。
    const tmp = `${target}.part`
    try {
      if (Buffer.isBuffer(body)) {
        await pipeline(
          async function* () {
            yield body
          },
          createWriteStream(tmp),
        )
      } else {
        await pipeline(body, createWriteStream(tmp))
      }
      await rename(tmp, target)
    } catch (e) {
      await unlink(tmp).catch(() => undefined)
      throw e
    }

    return reply.send({ key })
  })

  // ---- 登记版本 ----
  app.post('/v1/admin/releases', async (req, reply) => {
    checkAdmin(req)

    const b = (req.body ?? {}) as Record<string, unknown>
    const platform = String(b.platform ?? 'android')
    const versionName = String(b.version_name ?? '')
    const versionCode = Number(b.version_code ?? 0)
    const rawUrl = String(b.download_url ?? '')

    if (!versionName || !Number.isFinite(versionCode) || versionCode <= 0) {
      throw badRequest('version_name / version_code 不合法')
    }
    if (!rawUrl) throw badRequest('缺少 download_url')

    // `{BASE}` 占位符换成站点根地址，脚本就不必知道域名
    const downloadUrl = rawUrl.replace('{BASE}', config.publicOrigin)

    const res = await pool.query(
      `INSERT INTO app_releases
         (id, platform, version_name, version_code, download_url, changelog,
          force_update, is_active, published_at)
       VALUES ($1, $2, $3, $4, $5, $6, $7, TRUE, now())
       ON CONFLICT (platform, version_code) DO UPDATE SET
         version_name = EXCLUDED.version_name,
         download_url = EXCLUDED.download_url,
         changelog    = EXCLUDED.changelog,
         force_update = EXCLUDED.force_update,
         is_active    = TRUE,
         published_at = now()
       RETURNING id, platform, version_name, version_code, download_url,
                 changelog, force_update, is_active, published_at`,
      [
        `${platform}-${versionName}`,
        platform,
        versionName,
        Math.trunc(versionCode),
        downloadUrl,
        String(b.changelog ?? ''),
        Boolean(b.force_update),
      ],
    )

    return reply.code(201).send(res.rows[0])
  })

  // ---- 下架某个版本 ----
  app.patch('/v1/admin/releases/:id', async (req, reply) => {
    checkAdmin(req)
    const id = String((req.params as { id?: string }).id ?? '')
    const b = (req.body ?? {}) as { is_active?: unknown }
    const res = await pool.query(
      'UPDATE app_releases SET is_active = $1 WHERE id = $2 RETURNING id',
      [Boolean(b.is_active), id],
    )
    if (res.rowCount === 0) throw badRequest('没有这个版本')
    return reply.send({ ok: true })
  })
}
