/**
 * 部署冒烟：按客户端的真实调用方式跑一遍主链路。
 * 在容器内执行：node /tmp/e2e.mjs
 *
 * 只验证「服务真的能用」，不碰生产数据——每次都新建一个临时家庭。
 */

const BASE = process.env.E2E_BASE ?? 'http://127.0.0.1:8787'
let failed = 0

function check(name, ok, extra = '') {
  console.log(`${ok ? 'PASS' : 'FAIL'}  ${name}${extra ? '  ' + extra : ''}`)
  if (!ok) failed += 1
}

async function call(path, { method = 'GET', token, body, headers = {} } = {}) {
  const res = await fetch(BASE + path, {
    method,
    headers: {
      'content-type': 'application/json',
      ...(token ? { authorization: `Bearer ${token}` } : {}),
      ...headers,
    },
    body: body === undefined ? undefined : JSON.stringify(body),
  })
  const text = await res.text()
  let json
  try {
    json = text ? JSON.parse(text) : null
  } catch {
    json = text
  }
  return { status: res.status, json }
}

const uuid = () => crypto.randomUUID()
const now = Date.now()

// 1. 建家庭
const fam = await call('/auth/v1/families', { method: 'POST', body: { name: '部署验证' } })
const family = fam.json?.family
check('建家庭 201', fam.status === 201 && !!family?.code, `code=${family?.code}`)
const parentToken = fam.json?.access_token
check('拿到家长 token', typeof parentToken === 'string' && parentToken.length > 20)

// 2. 建孩子
const childId = uuid()
const child = await call('/v1/rdb/rest/children', {
  method: 'POST',
  token: parentToken,
  headers: { prefer: 'return=representation' },
  body: { id: childId, name: '小明', color_index: 2, created_at: now, updated_at: now },
})
check('建孩子 201', child.status === 201, `status=${child.status}`)
const childFamilyId = Array.isArray(child.json) ? child.json[0]?.family_id : child.json?.family_id
check('family_id 由服务端注入', childFamilyId === family?.id, `family_id=${childFamilyId}`)

// 3. 布置作业
const hwId = uuid()
const hw = await call('/v1/rdb/rest/homework', {
  method: 'POST',
  token: parentToken,
  headers: { prefer: 'return=representation' },
  body: {
    id: hwId,
    child_id: childId,
    date: new Date().toISOString().slice(0, 10),
    subject: '数学',
    content: '第 12 页 1-5 题 [图1]',
    images: [''],
    is_done: false,
    created_at: now,
    updated_at: now,
  },
})
check('布置作业 201', hw.status === 201, `status=${hw.status}`)

// 4. 读回
const list = await call(`/v1/rdb/rest/homework?child_id=eq.${childId}&select=*`, {
  token: parentToken,
})
const rows = Array.isArray(list.json) ? list.json : []
check('读回作业 1 条', list.status === 200 && rows.length === 1, `rows=${rows.length}`)
check('images 保留空串槽位', JSON.stringify(rows[0]?.images) === '[""]', `images=${JSON.stringify(rows[0]?.images)}`)

// 5. 孩子登录
const kid = await call('/auth/v1/signin/child', { method: 'POST', body: { code: family?.code, name: '小明' } })
check('孩子登录', kid.status === 200 && !!kid.json?.access_token, `status=${kid.status}`)
const childToken = kid.json?.access_token

// 6. 孩子打勾（客户端只发这两个字段，服务端白名单也只放这两个）
const tick = await call(`/v1/rdb/rest/homework?id=eq.${hwId}`, {
  method: 'PATCH',
  token: childToken,
  body: { is_done: true, done_at: Date.now() },
})
check('孩子打勾 200', tick.status === 200, `status=${tick.status}`)

// 7. 孩子改正文必须被拒（服务端列白名单）
const sneak = await call(`/v1/rdb/rest/homework?id=eq.${hwId}`, {
  method: 'PATCH',
  token: childToken,
  body: { content: '改掉' },
})
check('孩子改 content 被拒 403', sneak.status === 403, `status=${sneak.status}`)

// 8. 未带 token 读作业必须 401
const anon = await call(`/v1/rdb/rest/homework?child_id=eq.${childId}`)
check('匿名读作业 401', anon.status === 401, `status=${anon.status}`)

// 9. 静态站点
const page = await fetch(BASE + '/')
const html = await page.text()
check('家长端首页 200', page.status === 200 && html.includes('<div id="root"'), `len=${html.length}`)

console.log(failed === 0 ? '\n全部通过' : `\n失败 ${failed} 项`)
process.exit(failed === 0 ? 0 : 1)
