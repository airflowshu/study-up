/**
 * 认证钩子。
 *
 * 两种粒度：
 *   - attachAuth：有 token 就解析，没有也不拒绝（app_releases 这类公开读）
 *   - requireAuth：必须有效，否则 401
 *
 * `req.auth` 一旦挂上，下游的查询构造器就只信它，不信客户端传的 family_id。
 */
import type { FastifyReply, FastifyRequest } from 'fastify'
import { unauthorized } from '../errors.js'
import type { AuthCtx } from '../rest/build.js'
import { verifyToken } from './jwt.js'

declare module 'fastify' {
  interface FastifyRequest {
    auth: AuthCtx | null
    /** 当前请求用的 access token 原文，退出登录时用来定位会话。 */
    authRaw: string | null
  }
}

function bearer(req: FastifyRequest): string | null {
  const raw = req.headers.authorization
  if (!raw || !raw.startsWith('Bearer ')) return null
  const token = raw.slice(7).trim()
  return token.length > 0 ? token : null
}

/** 宽松：解析失败按匿名处理，不阻断请求。 */
export async function attachAuth(req: FastifyRequest): Promise<void> {
  req.auth = null
  req.authRaw = null

  const token = bearer(req)
  if (!token) return

  try {
    const claims = verifyToken(token)
    req.auth = {
      familyId: claims.sub,
      role: claims.rol,
      childId: claims.cid ?? null,
    }
    req.authRaw = token
  } catch {
    // 过期或伪造都按未登录处理，由 requireAuth 决定要不要 401
  }
}

/** 严格：没有有效 token 直接 401。 */
export async function requireAuth(
  req: FastifyRequest,
  _reply: FastifyReply,
): Promise<void> {
  await attachAuth(req)
  if (!req.auth) throw unauthorized()
}
