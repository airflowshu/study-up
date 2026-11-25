/**
 * 认证通道。
 *
 * 与旧 CloudBase 的差别：不再有"匿名登录 + 客户端自己查表比对家庭码"。
 * 家庭码变成真正的凭证，由服务端校验并签发只含该家庭 id 的 token。
 *
 * 响应体刻意保持 `access_token / refresh_token / expires_in` 三个字段名，
 * 两端客户端的会话保存逻辑（Flutter 的 _saveSession / Web 的 saveSession）
 * 因此不需要改。
 */
import { randomBytes, randomUUID } from 'node:crypto'
import type { FastifyInstance, FastifyRequest } from 'fastify'
import { issueToken } from '../auth/jwt.js'
import { createSession, findLiveSession, revokeSession } from '../auth/sessions.js'
import { badRequest, notFound, unauthorized } from '../errors.js'
import { pool } from '../db/pool.js'

/** 去掉了 I/O/0/1 这些手抄易错的字符，剩 32 个，6 位约 10.7 亿种。 */
const ALPHABET = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'

function genCode(): string {
  const bytes = randomBytes(6)
  let out = ''
  for (let i = 0; i < 6; i += 1) {
    const b = bytes[i] ?? 0
    out += ALPHABET[b % ALPHABET.length]
  }
  return out
}

const deviceId = (req: FastifyRequest): string | null => {
  const raw = req.headers['x-device-id']
  return typeof raw === 'string' && raw.length > 0 ? raw.slice(0, 64) : null
}

interface FamilyRow {
  id: string
  code: string
  name: string
  created_at: number
}

interface ChildRow {
  id: string
  family_id: string
  name: string
  color_index: number
  created_at: number
}

const familyDto = (f: FamilyRow) => ({
  id: f.id,
  code: f.code,
  name: f.name,
  created_at: f.created_at,
})

const childDto = (c: ChildRow) => ({
  id: c.id,
  family_id: c.family_id,
  name: c.name,
  color_index: c.color_index,
  created_at: c.created_at,
})

async function issueBundle(
  fam: FamilyRow,
  role: 'parent' | 'child',
  childId: string | null,
  dev: string | null,
): Promise<Record<string, unknown>> {
  const access = issueToken(fam.id, role, childId)
  const session = await createSession(fam.id, role, childId, dev)
  return {
    access_token: access.token,
    refresh_token: session.refreshToken,
    expires_in: access.expiresIn,
    token_type: 'Bearer',
    family: familyDto(fam),
  }
}

export async function authRoutes(app: FastifyInstance): Promise<void> {
  /** 登录类接口的限流。刷新不算——它是客户端正常运行的一部分。 */
  const loginRate = { max: 10, timeWindow: '1 minute' }
  const refreshRate = { max: 60, timeWindow: '1 minute' }

  // ---- 创建家庭 ----
  app.post('/auth/v1/families', { config: { rateLimit: loginRate } }, async (req, reply) => {
    const body = (req.body ?? {}) as { name?: unknown }
    const name =
      typeof body.name === 'string' && body.name.trim() ? body.name.trim() : '我们家'

    const id = randomUUID()
    const now = Date.now()

    // code 有唯一约束，撞了就换一个重试。32^6 的空间里连撞 5 次基本不可能。
    let row: FamilyRow | undefined
    for (let attempt = 0; attempt < 5 && !row; attempt += 1) {
      const code = genCode()
      try {
        const res = await pool.query<FamilyRow>(
          `INSERT INTO families (id, code, name, created_at)
           VALUES ($1, $2, $3, $4) RETURNING id, code, name, created_at`,
          [id, code, name, now],
        )
        row = res.rows[0]
      } catch (e) {
        if ((e as { code?: string }).code !== '23505') throw e
      }
    }
    if (!row) throw badRequest('家庭码生成失败，请重试')

    const bundle = await issueBundle(row, 'parent', null, deviceId(req))
    return reply.code(201).send(bundle)
  })

  // ---- 家长凭家庭码登录 ----
  app.post('/auth/v1/signin/family', { config: { rateLimit: loginRate } }, async (req, reply) => {
    const body = (req.body ?? {}) as { code?: unknown }
    const code =
      typeof body.code === 'string' ? body.code.trim().toUpperCase() : ''
    if (code.length !== 6) throw badRequest('家庭码是 6 位')

    const res = await pool.query<FamilyRow>(
      'SELECT id, code, name, created_at FROM families WHERE code = $1 LIMIT 1',
      [code],
    )
    const fam = res.rows[0]
    if (!fam) throw notFound('没找到这个家庭码，检查一下是不是输错了')

    return reply.send(await issueBundle(fam, 'parent', null, deviceId(req)))
  })

  // ---- 孩子凭家庭码 + 姓名登录 ----
  app.post('/auth/v1/signin/child', { config: { rateLimit: loginRate } }, async (req, reply) => {
    const body = (req.body ?? {}) as { code?: unknown; name?: unknown }
    const code =
      typeof body.code === 'string' ? body.code.trim().toUpperCase() : ''
    const name = typeof body.name === 'string' ? body.name.trim() : ''

    if (code.length !== 6) throw badRequest('家庭码是 6 位')
    if (!name) throw badRequest('请输入名字')

    const famRes = await pool.query<FamilyRow>(
      'SELECT id, code, name, created_at FROM families WHERE code = $1 LIMIT 1',
      [code],
    )
    const fam = famRes.rows[0]
    if (!fam) throw notFound('没找到这个家庭码，检查一下是不是输错了')

    const cRes = await pool.query<ChildRow>(
      `SELECT id, family_id, name, color_index, created_at FROM children
        WHERE family_id = $1 AND name = $2 AND is_deleted = FALSE
        LIMIT 1`,
      [fam.id, name],
    )
    const child = cRes.rows[0]
    if (!child) throw notFound('这个家里没有这个名字的孩子')

    const bundle = await issueBundle(fam, 'child', child.id, deviceId(req))
    return reply.send({ ...bundle, child: childDto(child) })
  })

  // ---- 刷新 ----
  app.post('/auth/v1/token', { config: { rateLimit: refreshRate } }, async (req, reply) => {
    const body = (req.body ?? {}) as {
      grant_type?: unknown
      refresh_token?: unknown
    }
    if (body.grant_type !== 'refresh_token') {
      throw badRequest('只支持 refresh_token')
    }
    const raw = typeof body.refresh_token === 'string' ? body.refresh_token : ''
    if (!raw) throw badRequest('缺少 refresh_token')

    const session = await findLiveSession(raw)
    if (!session) throw unauthorized('登录已失效，请重新登录')

    const famRes = await pool.query<FamilyRow>(
      'SELECT id, code, name, created_at FROM families WHERE id = $1 LIMIT 1',
      [session.family_id],
    )
    const fam = famRes.rows[0]
    if (!fam) throw unauthorized('登录已失效，请重新登录')

    // 不轮换 refresh：多标签页各自刷新时不会互相踢掉。
    // 代价是 refresh 一旦泄漏就长期有效，靠"可吊销"和 12 小时的 access 兜底。
    const access = issueToken(fam.id, session.role, session.child_id)
    return reply.send({
      access_token: access.token,
      refresh_token: raw,
      expires_in: access.expiresIn,
      token_type: 'Bearer',
      family: familyDto(fam),
    })
  })

  // ---- 退出登录 ----
  // 不要求 access token 有效：token 已过期时用户也得能退出去。
  // 定位会话靠 body 里的 refresh_token，拿不到就当作已经退过了，照样 204。
  app.post('/auth/v1/signout', async (req, reply) => {
    const body = (req.body ?? {}) as { refresh_token?: unknown }
    const raw = typeof body.refresh_token === 'string' ? body.refresh_token : ''
    if (raw) {
      const session = await findLiveSession(raw)
      if (session) await revokeSession(session.id)
    }
    return reply.code(204).send()
  })
}
