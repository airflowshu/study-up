/**
 * 隔离测试。
 *
 * 这一组测试保护的是"别人的数据我拿不到"这件事。它比功能测试更重要：
 * 功能坏了用户会骂，隔离坏了用户永远不知道。
 *
 * 覆盖的是计划 P2 的验收清单：跨家庭读、跨家庭写、家庭 id 伪造、
 * 孩子越权读家庭码、孩子越权改正文、会话吊销、登录爆破限流。
 */
import assert from 'node:assert/strict'
import { after, before, describe, it } from 'node:test'
import type { FastifyInstance } from 'fastify'
import { buildApp } from '../src/app.js'
import { pool } from '../src/db/pool.js'
import { migrate } from '../src/db/migrate.js'

interface FamilyFixture {
  token: string
  refresh: string
  code: string
  id: string
}

interface ChildFixture {
  token: string
  id: string
}

let app: FastifyInstance

async function newFamily(name: string): Promise<FamilyFixture> {
  const res = await app.inject({
    method: 'POST',
    url: '/auth/v1/families',
    payload: { name },
  })
  assert.equal(res.statusCode, 201)
  const b = res.json() as {
    access_token: string
    refresh_token: string
    family: { id: string; code: string }
  }
  return {
    token: b.access_token,
    refresh: b.refresh_token,
    code: b.family.code,
    id: b.family.id,
  }
}

async function addChild(fam: FamilyFixture, name: string): Promise<ChildFixture> {
  const id = `child-${name}-${Math.random().toString(36).slice(2, 8)}`
  const res = await app.inject({
    method: 'POST',
    url: '/v1/rdb/rest/children',
    headers: {
      authorization: `Bearer ${fam.token}`,
      prefer: 'return=representation',
    },
    payload: [
      {
        id,
        family_id: fam.id,
        name,
        color_index: 0,
        created_at: Date.now(),
        updated_at: Date.now(),
        is_deleted: false,
      },
    ],
  })
  assert.equal(res.statusCode, 201)

  const login = await app.inject({
    method: 'POST',
    url: '/auth/v1/signin/child',
    payload: { code: fam.code, name },
  })
  assert.equal(login.statusCode, 200)
  return { token: (login.json() as { access_token: string }).access_token, id }
}

async function addHomework(
  fam: FamilyFixture,
  childId: string,
  id: string,
): Promise<void> {
  const res = await app.inject({
    method: 'POST',
    url: '/v1/rdb/rest/homework',
    headers: {
      authorization: `Bearer ${fam.token}`,
      prefer: 'return=representation',
    },
    payload: [
      {
        id,
        child_id: childId,
        family_id: fam.id,
        date: '2026-11-09',
        subject: '语文',
        content: '原文',
        images: [],
        created_at: 1,
        updated_at: 1,
      },
    ],
  })
  assert.equal(res.statusCode, 201)
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

describe('家庭隔离', () => {
  it('B 读不到 A 的作业', async () => {
    await pool.query('TRUNCATE homework_sessions, homework, children, families, sessions CASCADE')
    const a = await newFamily('A家')
    const b = await newFamily('B家')
    const ca = await addChild(a, '小明')
    await addHomework(a, ca.id, 'hw-a')

    const res = await app.inject({
      method: 'GET',
      url: '/v1/rdb/rest/homework?select=*',
      headers: { authorization: `Bearer ${b.token}` },
    })
    assert.equal(res.statusCode, 200)
    assert.deepEqual(res.json(), [])
  })

  it('B 显式按 A 的 family_id 过滤也拿不到', async () => {
    const a = await newFamily('A2')
    const b = await newFamily('B2')
    const ca = await addChild(a, '小刚')
    await addHomework(a, ca.id, 'hw-a2')

    // 服务端会丢掉这个 family_id，用 token 里的值覆盖
    const res = await app.inject({
      method: 'GET',
      url: `/v1/rdb/rest/homework?family_id=eq.${a.id}&select=id`,
      headers: { authorization: `Bearer ${b.token}` },
    })
    assert.equal(res.statusCode, 200)
    assert.deepEqual(res.json(), [])
  })

  it('B 改 A 的行返回 200 + 空数组，且 A 的数据没变', async () => {
    const a = await newFamily('A3')
    const b = await newFamily('B3')
    const ca = await addChild(a, '小红')
    await addHomework(a, ca.id, 'hw-a3')

    const res = await app.inject({
      method: 'PATCH',
      url: '/v1/rdb/rest/homework?id=eq.hw-a3',
      headers: {
        authorization: `Bearer ${b.token}`,
        prefer: 'return=representation',
      },
      payload: { content: '被篡改' },
    })
    assert.equal(res.statusCode, 200)
    assert.deepEqual(res.json(), [])

    const check = await pool.query<{ content: string }>(
      'SELECT content FROM homework WHERE id = $1',
      ['hw-a3'],
    )
    assert.equal(check.rows[0]!.content, '原文')
  })

  it('B 插入时伪造 A 的 family_id，落库仍是 B', async () => {
    const a = await newFamily('A4')
    const b = await newFamily('B4')
    const cb = await addChild(b, '小B')

    const res = await app.inject({
      method: 'POST',
      url: '/v1/rdb/rest/homework',
      headers: {
        authorization: `Bearer ${b.token}`,
        prefer: 'return=representation',
      },
      payload: [
        {
          id: 'hw-forged',
          child_id: cb.id,
          family_id: a.id, // 伪造
          date: '2026-11-09',
          subject: '数学',
          content: '',
          images: [],
          created_at: 1,
          updated_at: 1,
        },
      ],
    })
    assert.equal(res.statusCode, 201)

    const check = await pool.query<{ family_id: string }>(
      'SELECT family_id FROM homework WHERE id = $1',
      ['hw-forged'],
    )
    assert.equal(check.rows[0]!.family_id, b.id)
  })
})

describe('孩子身份边界', () => {
  it('孩子读 families 被拒（家庭码不能泄漏给孩子）', async () => {
    const a = await newFamily('孩子的家')
    const kid = await addChild(a, '小豆')

    const res = await app.inject({
      method: 'GET',
      url: '/v1/rdb/rest/families?select=*',
      headers: { authorization: `Bearer ${kid.token}` },
    })
    assert.equal(res.statusCode, 403)
  })

  it('孩子只能看到自己那条 children', async () => {
    const a = await newFamily('俩娃家')
    const kid1 = await addChild(a, '老大')
    await addChild(a, '老二')

    const res = await app.inject({
      method: 'GET',
      url: '/v1/rdb/rest/children?select=id',
      headers: { authorization: `Bearer ${kid1.token}` },
    })
    assert.equal(res.statusCode, 200)
    const ids = (res.json() as Array<{ id: string }>).map((r) => r.id)
    assert.deepEqual(ids, [kid1.id])
  })

  it('孩子看不到兄弟姐妹的作业', async () => {
    const a = await newFamily('作业家')
    const kid1 = await addChild(a, '甲')
    const kid2 = await addChild(a, '乙')
    await addHomework(a, kid1.id, 'hw-甲')
    await addHomework(a, kid2.id, 'hw-乙')

    const res = await app.inject({
      method: 'GET',
      url: '/v1/rdb/rest/homework?select=id',
      headers: { authorization: `Bearer ${kid1.token}` },
    })
    const ids = (res.json() as Array<{ id: string }>).map((r) => r.id)
    assert.deepEqual(ids, ['hw-甲'])
  })

  it('孩子能打勾，但改不了正文', async () => {
    const a = await newFamily('打勾家')
    const kid = await addChild(a, '小丁')
    await addHomework(a, kid.id, 'hw-done')

    const ok = await app.inject({
      method: 'PATCH',
      url: '/v1/rdb/rest/homework?id=eq.hw-done',
      headers: {
        authorization: `Bearer ${kid.token}`,
        prefer: 'return=representation',
      },
      payload: { is_done: true, done_at: 1_700_000_000_000 },
    })
    assert.equal(ok.statusCode, 200)
    assert.equal((ok.json() as unknown[]).length, 1)

    const denied = await app.inject({
      method: 'PATCH',
      url: '/v1/rdb/rest/homework?id=eq.hw-done',
      headers: { authorization: `Bearer ${kid.token}` },
      payload: { content: '孩子改的' },
    })
    assert.equal(denied.statusCode, 403)

    const check = await pool.query<{ content: string; is_done: boolean }>(
      'SELECT content, is_done FROM homework WHERE id = $1',
      ['hw-done'],
    )
    assert.equal(check.rows[0]!.content, '原文')
    assert.equal(check.rows[0]!.is_done, true)
  })
})

describe('会话与限流', () => {
  it('吊销会话后 refresh 返回 401', async () => {
    const a = await newFamily('吊销家')
    await pool.query(
      'UPDATE sessions SET revoked_at = $1 WHERE family_id = $2',
      [Date.now(), a.id],
    )

    const res = await app.inject({
      method: 'POST',
      url: '/auth/v1/token',
      payload: { grant_type: 'refresh_token', refresh_token: a.refresh },
    })
    assert.equal(res.statusCode, 401)
  })

  it('连续错 11 次家庭码触发 429', async () => {
    // 限流是 per-app 的计数器，所以单独起一个开启了限流的实例
    const limited = await buildApp({ disableRateLimit: false, disableStatic: true })
    await limited.ready()

    let sawTooMany = false
    for (let i = 0; i < 14; i += 1) {
      const res = await limited.inject({
        method: 'POST',
        url: '/auth/v1/signin/family',
        payload: { code: 'ZZZZZZ' },
        remoteAddress: '203.0.113.9',
      })
      if (res.statusCode === 429) {
        sawTooMany = true
        break
      }
    }
    await limited.close()
    assert.equal(sawTooMany, true, '连错 14 次都没被限流')
  })
})
