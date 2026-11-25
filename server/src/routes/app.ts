/**
 * 客户端公开接口：版本检查。
 *
 * 单独开一条而不是让客户端查表，是因为这一步发生在登录之前——
 * 用户还没进家庭也得能收到更新提示。
 */
import type { FastifyInstance } from 'fastify'
import { pool } from '../db/pool.js'

interface ReleaseRow {
  id: string
  platform: string
  version_name: string
  version_code: number
  download_url: string
  changelog: string
  force_update: boolean
  is_active: boolean
  published_at: Date
}

export async function appRoutes(app: FastifyInstance): Promise<void> {
  app.get('/v1/app/releases/latest', async (req, reply) => {
    const platform = String(
      (req.query as { platform?: string }).platform ?? 'android',
    )

    const res = await pool.query<ReleaseRow>(
      `SELECT id, platform, version_name, version_code, download_url,
              changelog, force_update, is_active, published_at
         FROM app_releases
        WHERE platform = $1 AND is_active = TRUE
        ORDER BY version_code DESC
        LIMIT 1`,
      [platform],
    )

    const row = res.rows[0]
    if (!row) return reply.send(null)

    return reply.send({
      id: row.id,
      platform: row.platform,
      version_name: row.version_name,
      version_code: row.version_code,
      download_url: row.download_url,
      changelog: row.changelog,
      force_update: row.force_update,
      is_active: row.is_active,
      published_at: row.published_at,
    })
  })

  app.get('/healthz', async (_req, reply) => {
    try {
      await pool.query('SELECT 1')
      return reply.send({ ok: true })
    } catch (e) {
      return reply.code(503).send({ ok: false, error: (e as Error).message })
    }
  })
}
