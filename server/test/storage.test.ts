/**
 * 存储通道测试。
 *
 * 保护三件事：
 *   1. 别人家的前缀写不进去
 *   2. 图片读得到且带长缓存头（客户端靠 immutable 省流量）
 *   3. APK 支持 Range —— 断点续传和下载器都要这个
 */
import assert from 'node:assert/strict'
import { mkdtemp, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { after, before, describe, it } from 'node:test'
import type { FastifyInstance } from 'fastify'

// config 在模块加载时读环境变量，所以必须先设 env 再动态 import
const dataDir = await mkdtemp(join(tmpdir(), 'hw-test-'))
process.env.DATA_DIR = dataDir
process.env.NODE_ENV = 'test'

const { buildApp } = await import('../src/app.js')
const { pool } = await import('../src/db/pool.js')
const { migrate } = await import('../src/db/migrate.js')

let app: FastifyInstance
let token = ''
let familyId = ''
let otherToken = ''
let otherFamilyId = ''

/** 一张最小的合法 PNG（1×1 透明） */
const PNG = Buffer.from(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==',
  'base64',
)

before(async () => {
  await migrate()
  app = await buildApp({ disableRateLimit: true, disableStatic: true })
  await app.ready()

  const mk = async (name: string) => {
    const res = await app.inject({
      method: 'POST',
      url: '/auth/v1/families',
      payload: { name },
    })
    const b = res.json() as { access_token: string; family: { id: string } }
    return { token: b.access_token, id: b.family.id }
  }
  const a = await mk('存图家')
  const b = await mk('别家')
  token = a.token
  familyId = a.id
  otherToken = b.token
  otherFamilyId = b.id
})

after(async () => {
  await app.close()
  await pool.end()
  await rm(dataDir, { recursive: true, force: true })
})

describe('图片', () => {
  it('不带 token 上传 401', async () => {
    const res = await app.inject({
      method: 'POST',
      url: `/v1/storages/object/homework/f/${familyId}/homework/hw1/0.png`,
      headers: { 'content-type': 'image/png' },
      payload: PNG,
    })
    assert.equal(res.statusCode, 401)
  })

  it('写别人家的前缀 403', async () => {
    const res = await app.inject({
      method: 'POST',
      url: `/v1/storages/object/homework/f/${otherFamilyId}/homework/hw1/0.png`,
      headers: {
        authorization: `Bearer ${token}`,
        'content-type': 'image/png',
      },
      payload: PNG,
    })
    assert.equal(res.statusCode, 403)
  })

  it('上传成功且裸 GET 可读、带 immutable 缓存', async () => {
    const key = `f/${familyId}/homework/hw-nonexistent/0.png`
    const up = await app.inject({
      method: 'POST',
      url: `/v1/storages/object/homework/${key}`,
      headers: {
        authorization: `Bearer ${token}`,
        'content-type': 'image/png',
      },
      payload: PNG,
    })
    assert.equal(up.statusCode, 200)

    // 关键：上传时作业行还不存在（客户端是先传图后插行），不能因此拒绝
    const get = await app.inject({
      method: 'GET',
      url: `/v1/storages/object/homework/${key}`,
    })
    assert.equal(get.statusCode, 200)
    assert.equal(get.headers['content-type'], 'image/png')
    assert.match(String(get.headers['cache-control']), /immutable/)
    assert.equal(get.rawPayload.length, PNG.length)
  })

  it('不存在的 key 返回 404', async () => {
    const res = await app.inject({
      method: 'GET',
      url: `/v1/storages/object/homework/f/${familyId}/homework/nope/0.png`,
    })
    assert.equal(res.statusCode, 404)
  })

  it('路径穿越被拒', async () => {
    const res = await app.inject({
      method: 'GET',
      url: '/v1/storages/object/homework/..%2F..%2Fetc%2Fpasswd',
    })
    assert.ok(res.statusCode === 403 || res.statusCode === 404)
  })

  it('非图片 MIME 被拒', async () => {
    const res = await app.inject({
      method: 'POST',
      url: `/v1/storages/object/homework/f/${familyId}/homework/hw1/0.png`,
      headers: {
        authorization: `Bearer ${token}`,
        'content-type': 'application/pdf',
      },
      payload: Buffer.from('%PDF-1.4'),
    })
    // application/pdf 走默认 JSON 解析器，会先被 415 或 400 挡下
    assert.ok(res.statusCode >= 400 && res.statusCode < 500)
  })

  it('超过 20MB 返回 413', async () => {
    const big = Buffer.alloc(21 * 1024 * 1024, 1)
    const res = await app.inject({
      method: 'POST',
      url: `/v1/storages/object/homework/f/${familyId}/homework/hw1/big.png`,
      headers: {
        authorization: `Bearer ${token}`,
        'content-type': 'image/png',
      },
      payload: big,
    })
    assert.equal(res.statusCode, 413)
  })
})

describe('APK', () => {
  const APK = Buffer.from('fake-apk-content-'.repeat(1000))
  const adminToken = process.env.ADMIN_TOKEN ?? ''

  it('没有管理令牌 401', async () => {
    const res = await app.inject({
      method: 'PUT',
      url: '/v1/admin/apk/releases/test.apk',
      headers: { 'content-type': 'application/vnd.android.package-archive' },
      payload: APK,
    })
    assert.equal(res.statusCode, 401)
  })

  it('上传后公开可读且支持 Range', async () => {
    const up = await app.inject({
      method: 'PUT',
      url: '/v1/admin/apk/releases/test.apk',
      headers: {
        'x-admin-token': adminToken,
        'content-type': 'application/vnd.android.package-archive',
      },
      payload: APK,
    })
    assert.equal(up.statusCode, 200)

    const full = await app.inject({
      method: 'GET',
      url: '/v1/storages/object/apk/releases/test.apk',
    })
    assert.equal(full.statusCode, 200)
    assert.equal(full.rawPayload.length, APK.length)

    const part = await app.inject({
      method: 'GET',
      url: '/v1/storages/object/apk/releases/test.apk',
      headers: { range: 'bytes=0-99' },
    })
    assert.equal(part.statusCode, 206)
    assert.match(String(part.headers['content-range']), /^bytes 0-99\//)
    assert.equal(part.rawPayload.length, 100)
  })

  it('登记版本后 latest 能取到，{BASE} 被替换', async () => {
    const create = await app.inject({
      method: 'POST',
      url: '/v1/admin/releases',
      headers: {
        'x-admin-token': adminToken,
        'content-type': 'application/json',
      },
      payload: {
        platform: 'android',
        version_name: '1.1.0',
        version_code: 8,
        download_url: '{BASE}/v1/storages/object/apk/releases/test.apk',
        changelog: '迁移到 NAS',
        force_update: true,
      },
    })
    assert.equal(create.statusCode, 201)

    const latest = await app.inject({
      method: 'GET',
      url: '/v1/app/releases/latest?platform=android',
    })
    assert.equal(latest.statusCode, 200)
    const b = latest.json() as Record<string, unknown>
    assert.equal(b['version_code'], 8)
    assert.equal(b['force_update'], true)
    assert.ok(String(b['download_url']).includes('/v1/storages/object/apk/'))
  })
})
