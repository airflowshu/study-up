/**
 * 极简 HS256 JWT。
 *
 * 不引第三方库的理由：只需要 sign / verify 两个动作，算法固定为 HS256，
 * payload 里也不放任何可执行内容。依赖越少，镜像越小，升级面越窄。
 *
 * 注意两处容易写错的地方，这里都处理了：
 *   - 签名比较必须用 timingSafeEqual，不能用 ===（防时序侧信道）
 *   - 必须校验 header.alg，否则可以把 alg 改成 none 绕过验签
 */
import { createHmac, timingSafeEqual, randomUUID } from 'node:crypto'
import { config } from '../config.js'
import { unauthorized } from '../errors.js'
import type { Role } from '../rest/tables.js'

export interface JwtClaims {
  sub: string // family_id
  rol: Role
  cid: string | null // child_id，仅孩子 token 有
  iat: number
  exp: number
  jti: string
}

const b64url = (buf: Buffer | string): string =>
  Buffer.from(buf).toString('base64url')

const sign = (data: string): string =>
  createHmac('sha256', config.jwtSecret).update(data).digest('base64url')

export function issueToken(
  familyId: string,
  role: Role,
  childId: string | null,
): { token: string; expiresIn: number } {
  const now = Math.floor(Date.now() / 1000)
  const claims: JwtClaims = {
    sub: familyId,
    rol: role,
    cid: childId,
    iat: now,
    exp: now + config.accessTtlSec,
    jti: randomUUID(),
  }

  const head = b64url(JSON.stringify({ alg: 'HS256', typ: 'JWT' }))
  const body = b64url(JSON.stringify(claims))
  const payload = `${head}.${body}`
  return { token: `${payload}.${sign(payload)}`, expiresIn: config.accessTtlSec }
}

export function verifyToken(raw: string): JwtClaims {
  const parts = raw.split('.')
  if (parts.length !== 3) throw unauthorized()

  const [head, body, sig] = parts as [string, string, string]

  let header: unknown
  try {
    header = JSON.parse(Buffer.from(head, 'base64url').toString('utf8'))
  } catch {
    throw unauthorized()
  }
  if (
    typeof header !== 'object' ||
    header === null ||
    (header as { alg?: unknown }).alg !== 'HS256'
  ) {
    throw unauthorized()
  }

  const expected = sign(`${head}.${body}`)
  const a = Buffer.from(sig)
  const b = Buffer.from(expected)
  if (a.length !== b.length || !timingSafeEqual(a, b)) {
    throw unauthorized()
  }

  let claims: JwtClaims
  try {
    claims = JSON.parse(Buffer.from(body, 'base64url').toString('utf8')) as JwtClaims
  } catch {
    throw unauthorized()
  }

  // 多留 5 秒余量，避免客户端时钟略快时刚签发就判过期
  if (typeof claims.exp !== 'number' || claims.exp + 5 < Math.floor(Date.now() / 1000)) {
    throw new Error('TOKEN_EXPIRED')
  }
  if (typeof claims.sub !== 'string' || !claims.sub) throw unauthorized()

  return claims
}
