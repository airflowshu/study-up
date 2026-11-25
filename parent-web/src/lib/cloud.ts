/**
 * 后端客户端。
 *
 * 从 CloudBase 迁到家里的 NAS 之后，这一层的形状基本没变——
 * 因为新服务端刻意保留了原来的三条通道：
 *
 *   登录  POST {base}/auth/v1/signin/family
 *   数据  GET/POST/PATCH {base}/v1/rdb/rest/<table>
 *   图片  POST {base}/v1/storages/object/homework/<key>
 *
 * 两处关键变化：
 *
 *   1. `baseUrl` 是空字符串。前端和 API 由同一个进程提供，天然同源。
 *      同源省掉三件事：OPTIONS 预检、CORS 头、图床回源的跨域限制。
 *   2. 不再有匿名登录。登录必须用家庭码向服务端换 token，
 *      服务端在签发时就绑定了 family_id，此后所有查询都由服务端注入隔离条件。
 */
import { randomDeviceId } from './uuid'

const BASE_URL = (import.meta.env.VITE_API_BASE as string | undefined) ?? ''

/**
 * COS 图片前缀，由服务端 `/v1/storage/config` 下发。
 * null 表示服务端没配 COS，图片继续走本站路径（服务端会 302 到 COS 兜底）。
 */
let storageBase: string | null = null

const encodeKey = (key: string): string =>
  key.split('/').map(encodeURIComponent).join('/')

export const API = {
  /**
   * 空串 = 同源。留这个口子只是为了 `npm run dev` 时指向本地后端，
   * 或者把前端单独挂到别的域名下（那时要同时配 CORS）。
   */
  baseUrl: BASE_URL,
  get restUrl(): string {
    return `${BASE_URL}/v1/rdb/rest`
  },
  /** 图片直链。配了 COS 就直接连 COS，没配就回本站。 */
  imageUrl(key: string): string {
    if (storageBase) return `${storageBase}/${encodeKey(key)}`
    return `${BASE_URL}/v1/storages/object/homework/${key}`
  },
} as const

/**
 * 启动时取一次存储配置。失败不抛：退回本站路径，功能不受影响，
 * 只是图片会经隧道回源（慢一点，但能用）。
 */
export async function loadStorageConfig(): Promise<void> {
  try {
    const res = await fetch(`${BASE_URL}/v1/storage/config`)
    if (!res.ok) return
    const data = (await res.json()) as { image_base?: string | null }
    if (typeof data.image_base === 'string' && data.image_base) {
      storageBase = data.image_base.replace(/\/+$/, '')
    }
  } catch {
    // 取不到就用本站路径
  }
}

export class ApiError extends Error {
  constructor(
    message: string,
    readonly status?: number,
    readonly detail?: string,
  ) {
    super(message)
    this.name = 'ApiError'
  }
}

const KEY_TOKEN = 'hw_web_token'
const KEY_REFRESH = 'hw_web_refresh'
const KEY_EXPIRE = 'hw_web_expire'
const KEY_DEVICE = 'hw_web_device'

function readLocal(key: string): string {
  try {
    return localStorage.getItem(key) ?? ''
  } catch {
    return ''
  }
}

function writeLocal(key: string, value: string): void {
  try {
    if (value) localStorage.setItem(key, value)
    else localStorage.removeItem(key)
  } catch {
    /* 无痕模式等场景下写不进去，退化为仅内存会话 */
  }
}

function deviceId(): string {
  let id = readLocal(KEY_DEVICE)
  if (!id) {
    id = randomDeviceId()
    writeLocal(KEY_DEVICE, id)
  }
  return id
}

// 避免循环依赖：uuid.ts 不引任何业务模块

export interface FamilyInfo {
  id: string
  code: string
  name: string
  created_at: number
}

export interface AuthBundle {
  family: FamilyInfo
  expiresIn: number
}

/** 从错误响应里抠出给用户看的中文。服务端约定错误体是 `{ message }`。 */
async function errorFrom(res: Response, fallback: string): Promise<ApiError> {
  let msg = fallback
  let detail = ''
  try {
    detail = await res.text()
    const parsed: unknown = JSON.parse(detail)
    if (
      typeof parsed === 'object' &&
      parsed !== null &&
      'message' in parsed &&
      typeof (parsed as { message: unknown }).message === 'string'
    ) {
      msg = (parsed as { message: string }).message
    }
  } catch {
    /* 错误体不是 JSON 就用兜底文案 */
  }
  return new ApiError(msg, res.status, detail)
}

class CloudClient {
  private token = ''
  private refreshToken = ''
  private expireAt = 0
  private authing: Promise<void> | null = null

  /** 会话彻底失效时的回调，由 store 挂上去做「回登录页」。 */
  onAuthLost: (() => void) | null = null

  private hydrate(): void {
    if (this.token) return
    this.token = readLocal(KEY_TOKEN)
    this.refreshToken = readLocal(KEY_REFRESH)
    this.expireAt = Number(readLocal(KEY_EXPIRE) || 0)
  }

  private saveSession(body: Record<string, unknown>): void {
    this.token = typeof body.access_token === 'string' ? body.access_token : ''
    this.refreshToken =
      typeof body.refresh_token === 'string' ? body.refresh_token : ''
    const expiresIn =
      typeof body.expires_in === 'number' ? body.expires_in : 43_200
    this.expireAt = Date.now() + expiresIn * 1000
    writeLocal(KEY_TOKEN, this.token)
    writeLocal(KEY_REFRESH, this.refreshToken)
    writeLocal(KEY_EXPIRE, String(this.expireAt))
  }

  private clearSession(): void {
    this.token = ''
    this.refreshToken = ''
    this.expireAt = 0
    writeLocal(KEY_TOKEN, '')
    writeLocal(KEY_REFRESH, '')
    writeLocal(KEY_EXPIRE, '')
  }

  /** 本地是否还留着可用的会话，用于启动时判断要不要直接进主页。 */
  hasSession(): boolean {
    this.hydrate()
    return Boolean(this.token || this.refreshToken)
  }

  getFamilyIdFromToken(): string | null {
    this.hydrate()
    if (!this.token) return null
    const parts = this.token.split('.')
    if (parts.length !== 3) return null
    try {
      const payload = JSON.parse(atob(parts[1]!.replace(/-/g, '+').replace(/_/g, '/')))
      return typeof payload.sub === 'string' ? payload.sub : null
    } catch {
      return null
    }
  }

  // ---------------- 登录 ----------------

  /** 家长凭家庭码登录。服务端校验并签发绑定该家庭的 token。 */
  async signInFamily(code: string): Promise<AuthBundle> {
    let res: Response
    try {
      res = await fetch(`${API.baseUrl}/auth/v1/signin/family`, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'x-device-id': deviceId(),
        },
        body: JSON.stringify({ code: code.trim().toUpperCase() }),
      })
    } catch (e) {
      throw new ApiError('连不上服务，检查一下网络或服务器是否在运行', undefined, String(e))
    }

    if (!res.ok) throw await errorFrom(res, '登录失败，请稍后再试')

    const body = (await res.json()) as Record<string, unknown>
    this.saveSession(body)
    const fam = body.family as FamilyInfo
    return { family: fam, expiresIn: Number(body.expires_in ?? 43_200) }
  }

  /** 退出登录。失败也继续清本地——用户点了退出就必须退出去。 */
  async signOut(): Promise<void> {
    this.hydrate()
    const rt = this.refreshToken
    this.clearSession()
    if (!rt) return
    try {
      await fetch(`${API.baseUrl}/auth/v1/signout`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ refresh_token: rt }),
      })
    } catch {
      /* 网络问题不影响本地退出 */
    }
  }

  // ---------------- 会话维护 ----------------

  private async refresh(): Promise<boolean> {
    this.hydrate()
    if (!this.refreshToken) return false
    try {
      const res = await fetch(`${API.baseUrl}/auth/v1/token`, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'x-device-id': deviceId(),
        },
        body: JSON.stringify({
          grant_type: 'refresh_token',
          refresh_token: this.refreshToken,
        }),
      })
      if (!res.ok) {
        this.clearSession()
        return false
      }
      const body = (await res.json()) as Record<string, unknown>
      if (typeof body.access_token !== 'string') {
        this.clearSession()
        return false
      }
      this.saveSession(body)
      return true
    } catch {
      return false
    }
  }

  /** 拿到可用 token。拿不到就报错——不再自动匿名登录，那条路已经没有服务端支持。 */
  private ensureToken(): Promise<void> {
    if (this.authing) return this.authing
    this.authing = this.ensureTokenInner().finally(() => {
      this.authing = null
    })
    return this.authing
  }

  private async ensureTokenInner(): Promise<void> {
    this.hydrate()
    if (this.token && Date.now() < this.expireAt - 60_000) return
    if (await this.refresh()) return

    this.clearSession()
    this.onAuthLost?.()
    throw new ApiError('登录已过期，请重新登录', 401)
  }

  // ---------------- 通用请求 ----------------

  async request(
    method: string,
    url: string,
    init: { json?: unknown; body?: BodyInit; headers?: Record<string, string> } = {},
    allowRetry = true,
  ): Promise<Response> {
    await this.ensureToken()

    const headers: Record<string, string> = {
      Accept: 'application/json',
      Authorization: `Bearer ${this.token}`,
      'x-device-id': deviceId(),
      ...init.headers,
    }
    let body: BodyInit | undefined = init.body
    if (init.json !== undefined) {
      headers['Content-Type'] = 'application/json; charset=utf-8'
      body = JSON.stringify(init.json)
    }

    let res: Response
    try {
      res = await fetch(url, { method, headers, body })
    } catch (e) {
      throw new ApiError('网络不稳定，请稍后重试', undefined, String(e))
    }

    if (res.status === 401 && allowRetry) {
      // access 过期是常态（12 小时），先试着用 refresh 续一次再重发
      if (await this.refresh()) {
        return this.request(method, url, init, false)
      }
      this.clearSession()
      this.onAuthLost?.()
      throw await errorFrom(res, '登录已过期，请重新登录')
    }

    if (!res.ok) throw await errorFrom(res, `云端返回 ${res.status}`)

    return res
  }

  private async asList<T>(res: Response): Promise<T[]> {
    const text = await res.text()
    if (!text) return []
    const parsed: unknown = JSON.parse(text)
    if (Array.isArray(parsed)) return parsed as T[]
    if (parsed && typeof parsed === 'object') return [parsed as T]
    return []
  }

  // ---------------- 表数据 ----------------

  /** PostgREST 查询。params 用数组是为了支持同名键（`date=gte.x` + `date=lte.y`） */
  async select<T>(
    table: string,
    params: Array<[string, string]>,
  ): Promise<T[]> {
    const qs = params
      .map(([k, v]) => `${encodeURIComponent(k)}=${encodeURIComponent(v)}`)
      .join('&')
    const url = `${API.restUrl}/${table}${qs ? `?${qs}` : ''}`
    return this.asList<T>(await this.request('GET', url))
  }

  async insert<T>(table: string, row: Record<string, unknown>): Promise<T[]> {
    const res = await this.request('POST', `${API.restUrl}/${table}`, {
      json: [row],
      headers: { Prefer: 'return=representation' },
    })
    return this.asList<T>(res)
  }

  async patch<T>(
    table: string,
    id: string,
    fields: Record<string, unknown>,
  ): Promise<T[]> {
    const url = `${API.restUrl}/${table}?id=eq.${encodeURIComponent(id)}`
    const res = await this.request('PATCH', url, {
      json: fields,
      headers: { Prefer: 'return=representation' },
    })
    return this.asList<T>(res)
  }

  /**
   * 上传一张图，key 形如 `f/<familyId>/homework/<作业id>/<slot>.jpg`。
   *
   * 优先直传 COS：向服务端换一个限定了 key 的 PUT 预签名 URL，然后浏览器直连 COS。
   * 这样上传不经过 Cloudflare 隧道（隧道落洛杉矶，上行只有几十 KB/s）。
   * 服务端没配 COS 时 presign 会返回 501，这时退回本站通道，行为与改造前一致。
   */
  async uploadImage(key: string, blob: Blob): Promise<void> {
    const contentType = blob.type || 'image/jpeg'

    let presigned: { upload_url: string; headers?: Record<string, string> } | null = null
    try {
      const res = await this.request('POST', `${BASE_URL}/v1/storages/presign`, {
        json: { key, content_type: contentType },
      })
      presigned = (await res.json()) as { upload_url: string; headers?: Record<string, string> }
    } catch (e) {
      // 501 = 服务端未启用 COS。其它错误（401 续期失败、403 越权等）要往外抛，
      // 否则会被误当成"未启用"，把一个真错误掩盖成一次慢上传。
      if (!(e instanceof ApiError) || e.status !== 501) throw e
    }

    if (presigned) {
      const put = await fetch(presigned.upload_url, {
        method: 'PUT',
        // 这里绝不能带 Authorization：COS 只认预签名，多一个头反而会签不上
        headers: presigned.headers ?? { 'Content-Type': contentType },
        body: blob,
      })
      if (!put.ok) {
        throw new ApiError('图片上传失败，请重试', put.status, await put.text())
      }
      return
    }

    await this.request('POST', `${BASE_URL}/v1/storages/object/homework/${key}`, {
      body: blob,
      headers: { 'Content-Type': contentType },
    })
  }
}

export const cloud = new CloudClient()
