/**
 * refresh 会话。存 hash 不存明文——库被读走也换不到 token。
 *
 * 刻意不做 refresh 轮换：parent-web 可能同时开着几个标签页，
 * 轮换会让后刷新的那个把前面的踢掉。安全性靠 access 短有效期
 * + 会话可吊销（删孩子、退出登录、重置）来兜底。
 */
import { createHash, randomBytes, randomUUID } from 'node:crypto'
import { config } from '../config.js'
import { pool } from '../db/pool.js'
import type { Role } from '../rest/tables.js'

export interface SessionRow {
  id: string
  family_id: string
  role: Role
  child_id: string | null
  expires_at: number
  revoked_at: number | null
}

const hash = (token: string): string =>
  createHash('sha256').update(token).digest('hex')

export interface IssuedSession {
  refreshToken: string
  sessionId: string
  expiresIn: number
}

export async function createSession(
  familyId: string,
  role: Role,
  childId: string | null,
  deviceId: string | null,
): Promise<IssuedSession> {
  const refreshToken = randomBytes(32).toString('base64url')
  const id = randomUUID()
  const now = Date.now()
  const expiresAt = now + config.refreshTtlSec * 1000

  await pool.query(
    `INSERT INTO sessions
       (id, family_id, role, child_id, refresh_hash, device_id, created_at, last_used_at, expires_at)
     VALUES ($1, $2, $3, $4, $5, $6, $7, $7, $8)`,
    [id, familyId, role, childId, hash(refreshToken), deviceId, now, expiresAt],
  )

  return { refreshToken, sessionId: id, expiresIn: config.refreshTtlSec }
}

/** 校验 refresh token，返回可用会话；过期/吊销/不存在都返回 null。 */
export async function findLiveSession(
  refreshToken: string,
): Promise<SessionRow | null> {
  const res = await pool.query<SessionRow>(
    `SELECT id, family_id, role, child_id, expires_at, revoked_at
       FROM sessions WHERE refresh_hash = $1 LIMIT 1`,
    [hash(refreshToken)],
  )
  const row = res.rows[0]
  if (!row) return null
  if (row.revoked_at !== null) return null
  if (row.expires_at < Date.now()) return null

  await pool.query('UPDATE sessions SET last_used_at = $1 WHERE id = $2', [
    Date.now(),
    row.id,
  ])
  return row
}

export async function revokeSession(sessionId: string): Promise<void> {
  await pool.query(
    'UPDATE sessions SET revoked_at = $1 WHERE id = $2 AND revoked_at IS NULL',
    [Date.now(), sessionId],
  )
}

/** 孩子被删时调用：该孩子的所有设备立刻失去刷新能力。 */
export async function revokeChildSessions(childId: string): Promise<number> {
  const res = await pool.query(
    `UPDATE sessions SET revoked_at = $1
      WHERE child_id = $2 AND revoked_at IS NULL`,
    [Date.now(), childId],
  )
  return res.rowCount ?? 0
}

export async function revokeFamilySessions(familyId: string): Promise<number> {
  const res = await pool.query(
    `UPDATE sessions SET revoked_at = $1
      WHERE family_id = $2 AND revoked_at IS NULL`,
    [Date.now(), familyId],
  )
  return res.rowCount ?? 0
}
