/**
 * 契约测试。
 *
 * 目的不是"测覆盖率"，是把客户端依赖的每一条 PostgREST 语义钉死。
 * 这些语义里任何一条偏了，客户端都不会报错——它只会静默丢数据，
 * 或者把"云端还没有这行"误判成"改成功了"。所以在改任何查询层代码前
 * 先跑这个文件。
 */
import assert from 'node:assert/strict'
import { after, before, beforeEach, describe, it } from 'node:test'
import type { FastifyInstance } from 'fastify'
import { buildApp } from '../src/app.js'
import { pool } from '../src/db/pool.js'
import { migrate } from '../src/db/migrate.js'

let app: FastifyInstance
let token = ''
let familyId = ''
let childId = ''

const auth = () => ({ authorization: `Bearer ${token}` })

async function insertRow(
  table: string,
  row: Record<string, unknown>,
  prefer = 'return=representation',
) {
  return app.inject({
    method: 'POST',
    url: `/v1/rdb/rest/${table}`,
    headers: { ...auth(), prefer },
    payload: [row],
  })
}

async function selectRows(table: string, qs: string) {
  return app.inject({
    method: 'GET',
    url: `/v1/rdb/rest/${table}?${qs}`,
    headers: auth(),
  })
}

before(async () => {
  process.env.NODE_ENV = 'test'
  await migrate()
  app = await buildApp({ disableRateLimit: true, disableStatic: true })
  await app.ready()
})

after(async () => {
  await app.close()
  await pool.end()
})

beforeEach(async () => {
  await pool.query(
    `TRUNCATE homework_sessions, homework, children, families, sessions, app_releases CASCADE`,
  )

  const res = await app.inject({
    method: 'POST',
    url: '/auth/v1/families',
    payload: { name: '测试家' },
  })
  assert.equal(res.statusCode, 201)
  const body = res.json() as {
    access_token: string
    family: { id: string; code: string }
  }
  token = body.access_token
  familyId = body.family.id

  childId = 'child-1'
  const ins = await insertRow('children', {
    id: childId,
    family_id: familyId,
    name: '小明',
    color_index: 0,
    created_at: 1_700_000_000_000,
    updated_at: 1_700_000_000_000,
    is_deleted: false,
  })
  assert.equal(ins.statusCode, 201)
})

describe('认证', () => {
  it('创建家庭返回 6 位码与三件套', async () => {
    const res = await app.inject({
      method: 'POST',
      url: '/auth/v1/families',
      payload: { name: '第二家' },
    })
    assert.equal(res.statusCode, 201)
    const b = res.json() as Record<string, unknown>
    assert.equal(typeof b['access_token'], 'string')
    assert.equal(typeof b['refresh_token'], 'string')
    assert.equal(typeof b['expires_in'], 'number')
    const fam = b['family'] as { code: string }
    assert.equal(fam.code.length, 6)
    assert.match(fam.code, /^[A-Z2-9]{6}$/)
  })

  it('家庭码登录成功 / 错误码 404', async () => {
    const fam = (
      await pool.query<{ code: string }>('SELECT code FROM families LIMIT 1')
    ).rows[0]!
    const ok = await app.inject({
      method: 'POST',
      url: '/auth/v1/signin/family',
      payload: { code: fam.code },
    })
    assert.equal(ok.statusCode, 200)

    const bad = await app.inject({
      method: 'POST',
      url: '/auth/v1/signin/family',
      payload: { code: 'ZZZZZZ' },
    })
    assert.equal(bad.statusCode, 404)
  })

  it('刷新返回新的 access，refresh 不变', async () => {
    const created = await app.inject({
      method: 'POST',
      url: '/auth/v1/families',
      payload: { name: '刷新家' },
    })
    const b = created.json() as { refresh_token: string }

    const r = await app.inject({
      method: 'POST',
      url: '/auth/v1/token',
      payload: { grant_type: 'refresh_token', refresh_token: b.refresh_token },
    })
    assert.equal(r.statusCode, 200)
    const nb = r.json() as { access_token: string; refresh_token: string }
    assert.equal(typeof nb.access_token, 'string')
    assert.equal(nb.refresh_token, b.refresh_token)
  })

  it('无 token 读业务表返回 401', async () => {
    const res = await app.inject({
      method: 'GET',
      url: '/v1/rdb/rest/homework?select=*',
    })
    assert.equal(res.statusCode, 401)
  })
})

describe('PostgREST 语义', () => {
  it('eq 过滤', async () => {
    await insertRow('homework', {
      id: 'hw-1',
      child_id: childId,
      family_id: familyId,
      date: '2026-11-09',
      subject: '语文',
      content: '抄写',
      images: [],
      created_at: 1,
      updated_at: 1,
    })
    const res = await selectRows('homework', 'subject=eq.语文&select=*')
    assert.equal(res.statusCode, 200)
    assert.equal((res.json() as unknown[]).length, 1)
  })

  it('gte + lte 同名参数是 AND 区间', async () => {
    for (const d of ['2026-11-07', '2026-11-08', '2026-11-10']) {
      await insertRow('homework', {
        id: `hw-${d}`,
        child_id: childId,
        family_id: familyId,
        date: d,
        subject: '数学',
        content: '',
        images: [],
        created_at: 1,
        updated_at: 1,
      })
    }
    const res = await selectRows(
      'homework',
      'date=gte.2026-11-08&date=lte.2026-11-09&select=id',
    )
    assert.equal(res.statusCode, 200)
    const rows = res.json() as Array<{ id: string }>
    assert.equal(rows.length, 1)
    assert.equal(rows[0]!.id, 'hw-2026-11-08')
  })

  it('in.(a,b) 在逗号被编码后仍能解析', async () => {
    for (const c of ['c1', 'c2', 'c3']) {
      await insertRow('children', {
        id: c,
        family_id: familyId,
        name: c,
        color_index: 0,
        created_at: 1,
        updated_at: 1,
      })
    }
    for (const c of ['c1', 'c2', 'c3']) {
      await insertRow('homework', {
        id: `h-${c}`,
        child_id: c,
        family_id: familyId,
        date: '2026-11-09',
        subject: '英语',
        content: '',
        images: [],
        created_at: 1,
        updated_at: 1,
      })
    }

    // 客户端真实发出去的样子：encodeURIComponent 把逗号变成 %2C，括号保留为 %28%29
    const res = await selectRows('homework', 'child_id=in.%28c1%2Cc3%29&select=id')
    assert.equal(res.statusCode, 200)
    assert.equal((res.json() as unknown[]).length, 2)
  })

  it('order 支持多字段', async () => {
    await insertRow('homework', {
      id: 'a',
      child_id: childId,
      family_id: familyId,
      date: '2026-11-09',
      subject: '语文',
      content: '',
      images: [],
      created_at: 100,
      updated_at: 1,
    })
    await insertRow('homework', {
      id: 'b',
      child_id: childId,
      family_id: familyId,
      date: '2026-11-09',
      subject: '数学',
      content: '',
      images: [],
      created_at: 200,
      updated_at: 1,
    })

    const res = await selectRows(
      'homework',
      'select=id&order=date.desc%2Ccreated_at.desc',
    )
    assert.equal(res.statusCode, 200)
    const rows = res.json() as Array<{ id: string }>
    assert.deepEqual(
      rows.map((r) => r.id),
      ['b', 'a'],
    )
  })

  it('select 只回指定列', async () => {
    await insertRow('homework', {
      id: 'hw-sel',
      child_id: childId,
      family_id: familyId,
      date: '2026-11-09',
      subject: '语文',
      content: 'x',
      images: [],
      created_at: 1,
      updated_at: 1,
    })
    const res = await selectRows('homework', 'select=id,is_deleted')
    const rows = res.json() as Array<Record<string, unknown>>
    assert.deepEqual(Object.keys(rows[0]!).sort(), ['id', 'is_deleted'])
  })

  it('limit 生效', async () => {
    for (let i = 0; i < 5; i += 1) {
      await insertRow('homework', {
        id: `l-${i}`,
        child_id: childId,
        family_id: familyId,
        date: '2026-11-09',
        subject: '语文',
        content: '',
        images: [],
        created_at: i,
        updated_at: i,
      })
    }
    const res = await selectRows('homework', 'select=id&limit=2')
    assert.equal((res.json() as unknown[]).length, 2)
  })

  it('Prefer: return=minimal 不回行', async () => {
    const res = await insertRow(
      'homework',
      {
        id: 'hw-min',
        child_id: childId,
        family_id: familyId,
        date: '2026-11-09',
        subject: '语文',
        content: '',
        images: [],
        created_at: 1,
        updated_at: 1,
      },
      'return=minimal',
    )
    assert.equal(res.statusCode, 201)
    assert.equal(res.body, '')
  })

  it('Prefer: return=representation 回写后的行', async () => {
    const res = await insertRow('homework', {
      id: 'hw-rep',
      child_id: childId,
      family_id: familyId,
      date: '2026-11-09',
      subject: '语文',
      content: '',
      images: [],
      created_at: 1,
      updated_at: 1,
    })
    const rows = res.json() as Array<Record<string, unknown>>
    assert.equal(rows.length, 1)
    assert.equal(rows[0]!['id'], 'hw-rep')
  })

  it('PATCH 匹配 0 行返回 200 + 空数组（不是 404）', async () => {
    const res = await app.inject({
      method: 'PATCH',
      url: '/v1/rdb/rest/homework?id=eq.不存在',
      headers: { ...auth(), prefer: 'return=representation' },
      payload: { content: '改了' },
    })
    assert.equal(res.statusCode, 200)
    assert.deepEqual(res.json(), [])
  })

  it('重复主键返回 409', async () => {
    const row = {
      id: 'dup',
      child_id: childId,
      family_id: familyId,
      date: '2026-11-09',
      subject: '语文',
      content: '',
      images: [],
      created_at: 1,
      updated_at: 1,
    }
    assert.equal((await insertRow('homework', row)).statusCode, 201)
    assert.equal((await insertRow('homework', row)).statusCode, 409)
  })

  it('BIGINT 列返回 number 而不是字符串', async () => {
    await insertRow('homework', {
      id: 'hw-big',
      child_id: childId,
      family_id: familyId,
      date: '2026-11-09',
      subject: '语文',
      content: '',
      images: [],
      created_at: 1_700_000_000_123,
      updated_at: 1_700_000_000_123,
    })
    const res = await selectRows('homework', 'select=created_at')
    const rows = res.json() as Array<{ created_at: unknown }>
    assert.equal(typeof rows[0]!.created_at, 'number')
    assert.equal(rows[0]!.created_at, 1_700_000_000_123)
  })

  it('images 的空串槽位必须原样保留', async () => {
    const images = ['f/x/0.jpg', '', 'f/x/2.jpg']
    await insertRow('homework', {
      id: 'hw-img',
      child_id: childId,
      family_id: familyId,
      date: '2026-11-09',
      subject: '语文',
      content: '[图1] 和 [图3]',
      images,
      created_at: 1,
      updated_at: 1,
    })
    const res = await selectRows('homework', 'id=eq.hw-img&select=images')
    const rows = res.json() as Array<{ images: string[] }>
    assert.deepEqual(rows[0]!.images, images)
  })

  it('布尔过滤 eq.false 走真布尔', async () => {
    await insertRow('children', {
      id: 'gone',
      family_id: familyId,
      name: '已删',
      color_index: 0,
      created_at: 1,
      updated_at: 1,
      is_deleted: true,
    })
    const res = await selectRows('children', 'is_deleted=eq.false&select=id')
    const ids = (res.json() as Array<{ id: string }>).map((r) => r.id)
    assert.ok(ids.includes('child-1'))
    assert.ok(!ids.includes('gone'))
  })

  it('不支持的列名返回 400 而不是 500', async () => {
    const res = await selectRows('homework', 'select=nosuchcol')
    assert.equal(res.statusCode, 400)
  })
})
