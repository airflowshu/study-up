/**
 * 应用构建。与启动过程分离，测试里可以直接 inject 而不占端口。
 *
 * 一个进程同时干三件事：静态前端、REST 数据、认证与存储。
 * 同源是刻意的——跨域会带来预检、CORS 头、图床回源三处长期麻烦。
 */
import { existsSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import Fastify, { type FastifyInstance } from 'fastify'
import fastifyStatic from '@fastify/static'
import rateLimit from '@fastify/rate-limit'
import { assertConfig } from './config.js'
import { HttpError } from './errors.js'
import { authRoutes } from './routes/auth.js'
import { restRoutes } from './routes/rest.js'
import { storageRoutes } from './routes/storage.js'
import { cosOrigin } from './cos.js'
import { cosRoutes } from './routes/cos.js'
import { adminRoutes } from './routes/admin.js'
import { appRoutes } from './routes/app.js'
import { linkRoutes } from './routes/link.js'

const here = dirname(fileURLToPath(import.meta.url))

/** 编译后 dist/app.js 与源码 src/app.ts 到 public 的相对层级一致，都是上一级。 */
function publicDir(): string | null {
  const candidates = [
    join(here, '../public'),
    join(here, '../../public'),
    join(process.cwd(), 'public'),
  ]
  return candidates.find((p) => existsSync(join(p, 'index.html'))) ?? null
}

export interface BuildOptions {
  /** 测试里关掉限流，否则连打 10 次就被 429 挡掉。 */
  disableRateLimit?: boolean
  /** 测试里不挂静态目录。 */
  disableStatic?: boolean
}

export async function buildApp(opts: BuildOptions = {}): Promise<FastifyInstance> {
  assertConfig()

  const app = Fastify({
    logger: process.env.NODE_ENV === 'test' ? false : {
      level: process.env.LOG_LEVEL ?? 'info',
      // 令牌不进日志
      redact: ['req.headers.authorization', 'req.headers["x-admin-token"]'],
    },
    trustProxy: '10.0.0.0/8',
    bodyLimit: 1024 * 1024,
  })

  // ---- 二进制上行：保留为流，不要缓冲进内存 ----
  // 20MB 图 × 并发 2 尚可，但 50MB 的 APK 一旦缓冲就会顶爆 512MB 的容器。
  const passThrough = (
    _req: unknown,
    payload: NodeJS.ReadableStream,
    done: (e: Error | null, body?: unknown) => void,
  ) => {
    done(null, payload)
  }
  app.addContentTypeParser(/^image\//, passThrough)
  // 附件上传同理：PDF / DOCX 也必须按流处理。
  // 少注册这两个，Fastify 会在进入路由之前就返回 415 Unsupported Media Type，
  // 客户端只能看到一句和业务无关的框架报错。
  app.addContentTypeParser('application/pdf', passThrough)
  app.addContentTypeParser(
    'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    passThrough,
  )
  app.addContentTypeParser('application/octet-stream', passThrough)
  app.addContentTypeParser('application/vnd.android.package-archive', passThrough)

  // ---- 安全头 ----
  // 启用 COS 后必须把它加进 CSP：预签名直传是跨域 fetch（受 connect-src 管），
  // COS 上的图片是跨域 <img>（受 img-src 管）。缺一条的表现分别是
  // 上传报 "Failed to fetch"、图片裂成空白，且网络面板里看不到任何请求。
  const cos = cosOrigin()
  const imgSrc = cos ? `'self' data: blob: ${cos}` : `'self' data: blob:`
  const connectSrc = cos ? `'self' ${cos}` : `'self'`
  const csp =
    `default-src 'self'; img-src ${imgSrc}; ` +
    `style-src 'self' 'unsafe-inline'; script-src 'self'; ` +
    `connect-src ${connectSrc}; object-src 'none'; base-uri 'self'; form-action 'self'`

  app.addHook('onSend', async (_req, reply) => {
    reply.header('X-Content-Type-Options', 'nosniff')
    reply.header('X-Frame-Options', 'DENY')
    reply.header('Referrer-Policy', 'no-referrer')
    reply.header('Content-Security-Policy', csp)
  })

  // ---- 登录限流 ----
  // 家庭码空间约 10.7 亿，但没有限流时分布式猜也能命中。每分钟 10 次够正常使用。
  // 全局关闭，只在 auth 路由上按 route config 挂——数据读接口不该被这个限制。
  if (!opts.disableRateLimit) {
    await app.register(rateLimit, { global: false })
  }

  // ---- 路由 ----
  await app.register(appRoutes)
  await app.register(linkRoutes)
  await app.register(authRoutes)
  await app.register(restRoutes)
  await app.register(storageRoutes)
  await app.register(cosRoutes)
  await app.register(adminRoutes)

  // ---- 静态前端 ----
  const pub = opts.disableStatic ? null : publicDir()
  if (pub) {
    await app.register(fastifyStatic, {
      root: pub,
      index: ['index.html'],
      // 关掉插件自带的 cache-control，否则它会在 setHeaders 之后
      // 把头部覆盖成默认的 `public, max-age=0`，带 hash 的资源就白瞎了。
      cacheControl: false,
      setHeaders(res, path) {
        const normalized = path.replace(/\\/g, '/')
        if (normalized.endsWith('index.html')) {
          // HTML 不能缓存：资源名带 hash，HTML 一缓存旧版就永远拉不到新 JS
          res.setHeader('Cache-Control', 'no-cache')
        } else if (normalized.includes('/assets/')) {
          res.setHeader('Cache-Control', 'public, max-age=31536000, immutable')
        } else {
          res.setHeader('Cache-Control', 'no-cache')
        }
      },
    })
  } else if (!opts.disableStatic) {
    app.log.warn('没找到 public/index.html，只提供 API（本地开发时正常）')
  }

  // ---- 错误处理 ----
  app.setErrorHandler((err, req, reply) => {
    if (err instanceof HttpError) {
      if (err.status === 401) reply.header('WWW-Authenticate', 'Bearer')
      return reply
        .code(err.status)
        .send({ message: err.message, ...(err.detail ? { detail: err.detail } : {}) })
    }

    // 限流插件抛的错误带 statusCode
    const status = (err as { statusCode?: number }).statusCode
    if (status && status >= 400 && status < 500) {
      return reply.code(status).send({ message: '请求太频繁或参数不对，请稍后再试' })
    }

    req.log.error({ err }, '未处理的异常')
    return reply.code(500).send({ message: '服务出错了，请稍后再试' })
  })

  app.setNotFoundHandler((req, reply) => {
    reply.code(404).send({ message: `没有这个接口：${req.method} ${req.url}` })
  })

  return app
}
