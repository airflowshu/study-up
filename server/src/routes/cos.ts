/**
 * 图片直传 COS 的接口。
 *
 * 流程：
 *   1. 客户端 `GET /v1/storage/config` 拿到 image_base（未启用时是 null，走老路径）；
 *   2. 上传前 `POST /v1/storages/presign` 用 Bearer 换一个限定了 key 的 PUT 预签名 URL；
 *   3. 客户端直接 PUT 到 COS，服务器不中转字节。
 *
 * 归属校验照旧：key 必须以 `f/<自己的 familyId>/` 开头。客户端自己拼 key 不变，
 * 所以数据库里存的 key 不需要迁移。
 */
import type { FastifyInstance } from 'fastify'
import { requireAuth } from '../auth/guard.js'
import { cosEnabled, cosImageBase, cosObjectUrl, signPutUrl } from '../cos.js'
import { badRequest, forbidden, notImplemented } from '../errors.js'
import { config } from '../config.js'

export async function cosRoutes(app: FastifyInstance): Promise<void> {
  // 公开：客户端启动时取一次，决定读图地址拼哪里
  app.get('/v1/storage/config', async (_req, reply) => {
    return reply.send({
      image_base: cosImageBase(),
      // 老客户端不认识这个字段，会继续用自己的默认路径，不影响
      max_image_bytes: config.maxImageBytes,
    })
  })

  app.post(
    '/v1/storages/presign',
    { preHandler: requireAuth },
    async (req, reply) => {
      if (!cosEnabled()) throw notImplemented('服务端未启用 COS 直传')

      const auth = req.auth
      if (!auth) throw forbidden()

      const body = (req.body ?? {}) as { key?: unknown; content_type?: unknown }
      const rawKey = typeof body.key === 'string' ? body.key : ''
      const contentType = typeof body.content_type === 'string' ? body.content_type : ''

      // 和其他上传通路共用白名单：图片、PDF、DOCX
      if (!config.allowedUploadMime.has(contentType)) {
        throw badRequest('只支持图片 / PDF / DOCX')
      }
      if (!rawKey || rawKey.split('/').includes('..') || rawKey.startsWith('/')) {
        throw badRequest('key 不合法')
      }

      // 服务端强制前缀校验：别人的 token 拼不出自己家的前缀，也就签不出来
      const expectedPrefix = `f/${auth.familyId}/`
      if (!rawKey.startsWith(expectedPrefix)) {
        throw forbidden('上传路径不属于当前家庭')
      }

      const expiresIn = 900
      // 图片 key 里的 slot 是「时间戳+随机串」，写一次就永不覆盖，
      // 所以可以给一整年的 immutable 缓存：孩子端反复看同一张图不再重复下载。
      const imageCache = 'public, max-age=31536000, immutable'
      return reply.send({
        upload_url: signPutUrl(rawKey, contentType, expiresIn, imageCache),
        public_url: cosObjectUrl(rawKey),
        method: 'PUT',
        // 必须原样带上，Content-Type 参与签名，少一个字节都会被拒
        headers: { 'Content-Type': contentType, 'Cache-Control': imageCache },
        expires_in: expiresIn,
      })
    },
  )
}
