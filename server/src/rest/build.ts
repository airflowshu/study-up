/**
 * 把解析后的 Query 构造成参数化 SQL。
 *
 * 两条铁律：
 *   1. 标识符（表名/列名）一律走白名单，绝不拼进 SQL 文本；
 *   2. 所有值走 $n 占位符。
 *
 * 隔离条件由这里统一注入，路由层没有机会忘记加 family_id。
 */
import { badRequest, forbidden } from '../errors.js'
import type { Query, Filter } from './parse.js'
import { columnDef, tableDef, type Role, type TableDef } from './tables.js'

export interface AuthCtx {
  familyId: string
  role: Role
  childId: string | null
}

/** 递增的占位符袋子。 */
class Params {
  readonly values: unknown[] = []
  add(value: unknown): string {
    this.values.push(value)
    return `$${this.values.length}`
  }
}

const q = (ident: string): string => `"${ident.replace(/"/g, '""')}"`

/**
 * 按列类型把值交给驱动的绑定参数。
 *
 * jsonb 必须自己 stringify：node-postgres 会把 JS 数组当成 PG 的数组字面量
 * 序列化成 `{a,b,c}`，塞给 jsonb 列直接报 "invalid input syntax for type json"。
 * 空串槽位也因此得以完整保留——原样序列化，不做任何过滤。
 */
function bind(p: Params, table: TableDef, column: string, value: unknown): string {
  const def = columnDef(table, column)
  if (def?.type === 'jsonb') {
    return p.add(JSON.stringify(value ?? []))
  }
  return p.add(value ?? null)
}

/** 该角色能读哪些列。null 表示整表禁读。 */
export function readableColumns(table: TableDef, auth: AuthCtx | null): string[] {
  const list = auth ? table.read[auth.role] : table.read.anon
  if (!list) {
    throw forbidden(
      auth ? '当前身份没有读取权限' : '这个数据需要登录后才能读取',
    )
  }
  return list
}

/** 该角色能写哪些列。null 表示不可写。 */
export function writableColumns(table: TableDef, auth: AuthCtx | null): string[] {
  const list = auth ? table.write[auth.role] : null
  if (!list) throw forbidden('当前身份没有写入权限')
  return list
}

/** 隔离 + 角色收窄。返回若干 AND 片段。 */
function scopeClauses(table: TableDef, auth: AuthCtx | null, p: Params): string[] {
  const out: string[] = []

  if (table.scope === 'family') {
    if (!auth) throw forbidden('这个数据需要登录后才能读取')
    out.push(`${q('family_id')} = ${p.add(auth.familyId)}`)
  } else if (table.scope === 'self') {
    if (!auth) throw forbidden('这个数据需要登录后才能读取')
    out.push(`${q('id')} = ${p.add(auth.familyId)}`)
  }

  // 孩子只能看到自己的行。不加这一条，孩子端就能读到兄弟姐妹的作业。
  if (table.childNarrow && auth?.role === 'child') {
    if (!auth.childId) throw forbidden('孩子身份缺少标识，请重新登录')
    out.push(`${q(table.childNarrow)} = ${p.add(auth.childId)}`)
  }

  if (table.anonWhere && !auth) {
    out.push(`${q(table.anonWhere.column)} = ${p.add(table.anonWhere.value)}`)
  }

  return out
}

function filterClause(f: Filter, allowed: string[], p: Params): string {
  // 过滤只能落在"本来就能读到的列"上。
  // 否则可以借 `?password_hash=eq.x` 的存在性判断反推出不该知道的信息。
  if (!allowed.includes(f.column)) {
    throw badRequest(`不能按 ${f.column} 过滤`)
  }
  const id = q(f.column)

  switch (f.op) {
    case 'eq':
      return `${id} = ${p.add(f.value)}`
    case 'neq':
      return `${id} <> ${p.add(f.value)}`
    case 'gt':
      return `${id} > ${p.add(f.value)}`
    case 'gte':
      return `${id} >= ${p.add(f.value)}`
    case 'lt':
      return `${id} < ${p.add(f.value)}`
    case 'lte':
      return `${id} <= ${p.add(f.value)}`
    case 'is':
      return `${id} IS NULL`
    case 'in': {
      const values = f.value as unknown[]
      if (values.length === 0) return 'FALSE'
      const holes = values.map((v) => p.add(v)).join(', ')
      return `${id} IN (${holes})`
    }
  }
}

interface Built {
  text: string
  values: unknown[]
}

export function buildSelect(table: TableDef, query: Query, auth: AuthCtx | null): Built {
  const readable = readableColumns(table, auth)
  const p = new Params()

  const cols =
    query.select.length > 0 ? query.select : readable
  for (const c of cols) {
    if (!readable.includes(c)) throw badRequest(`不能读取列 ${c}`)
  }

  const where = [
    ...scopeClauses(table, auth, p),
    ...query.filters.map((f) => filterClause(f, readable, p)),
  ]

  let text = `SELECT ${cols.map(q).join(', ')} FROM ${q(table.name)}`
  if (where.length) text += ` WHERE ${where.join(' AND ')}`
  if (query.order.length) {
    text += ` ORDER BY ${query.order
      .map((o) => `${q(o.column)} ${o.dir.toUpperCase()}`)
      .join(', ')}`
  }
  text += ` LIMIT ${p.add(query.limit)}`

  return { text, values: p.values }
}

/** PATCH 的目标行：隔离 + 查询过滤。刻意复用同一套 scopeClauses。 */
function targetWhere(
  table: TableDef,
  query: Query,
  auth: AuthCtx,
  p: Params,
): string {
  const clos = scopeClauses(table, auth, p)
  for (const f of query.filters) {
    clos.push(filterClause(f, readableColumns(table, auth), p))
  }
  // 没有任何条件时拒绝执行，避免一次误请求改全表。
  if (clos.length === 0) throw badRequest('缺少更新条件')
  return clos.join(' AND ')
}

export function buildInsert(
  table: TableDef,
  rows: Array<Record<string, unknown>>,
  auth: AuthCtx,
): Built {
  if (rows.length === 0) throw badRequest('插入内容为空')
  const writable = writableColumns(table, auth)

  const names: string[] = []
  for (const row of rows) {
    for (const key of Object.keys(row)) {
      if (!names.includes(key)) names.push(key)
    }
  }

  for (const name of names) {
    if (!writable.includes(name)) {
      throw forbidden(`不能写入字段 ${name}`)
    }
  }

  const p = new Params()

  // family_id 永远以 token 为准：客户端传什么都覆盖掉。
  // 覆盖而不是拒绝，是为了兼容老客户端会主动带 family_id 的行为。
  const enforced: Record<string, unknown> = {}
  if (table.scope === 'family') enforced['family_id'] = auth.familyId
  if (table.childNarrow && auth.role === 'child' && auth.childId) {
    enforced[table.childNarrow] = auth.childId
  }

  const allNames = [...new Set([...names, ...Object.keys(enforced)])]
  for (const n of allNames) {
    if (!writable.includes(n)) {
      throw forbidden(`不能写入字段 ${n}`)
    }
  }

  const tuples: string[] = []
  for (const row of rows) {
    const merged = { ...row, ...enforced }
    const holes = allNames.map((n) => bind(p, table, n, merged[n]))
    tuples.push(`(${holes.join(', ')})`)
  }

  const returning = readableColumns(table, auth)
  const text =
    `INSERT INTO ${q(table.name)} (${allNames.map(q).join(', ')}) ` +
    `VALUES ${tuples.join(', ')} ` +
    `RETURNING ${returning.map(q).join(', ')}`

  return { text, values: p.values }
}

export function buildUpdate(
  table: TableDef,
  query: Query,
  patch: Record<string, unknown>,
  auth: AuthCtx,
): Built {
  const writable = writableColumns(table, auth)

  const sets: string[] = []
  const p = new Params()

  for (const [key, value] of Object.entries(patch)) {
    if (key === 'id') continue // 主键不可改，静默忽略而不是报错
    if (!writable.includes(key)) {
      throw forbidden(`不能修改字段 ${key}`)
    }
    sets.push(`${q(key)} = ${bind(p, table, key, value)}`)
  }

  // family_id 一律强制回 token 的值，防止把行"搬"到别的家庭
  if (table.scope === 'family' && !sets.some((s) => s.startsWith('"family_id"'))) {
    sets.push(`${q('family_id')} = ${p.add(auth.familyId)}`)
  }

  if (sets.length === 0) throw badRequest('没有要修改的字段')

  const where = targetWhere(table, query, auth, p)
  const returning = readableColumns(table, auth)

  // 匹配 0 行必须返回空数组 + 200：
  // 客户端的 saveHomework 靠"PATCH 没改到东西"来决定补插一条。
  // 这里如果返回 404，那条 upsert 逻辑就永远走不到 insert 分支。
  const text =
    `UPDATE ${q(table.name)} SET ${sets.join(', ')} ` +
    `WHERE ${where} RETURNING ${returning.map(q).join(', ')}`

  return { text, values: p.values }
}

export function buildDelete(
  table: TableDef,
  query: Query,
  auth: AuthCtx,
): Built {
  if (!table.allowDelete) {
    throw forbidden('不支持物理删除')
  }
  const p = new Params()
  const where = targetWhere(table, query, auth, p)
  return {
    text: `DELETE FROM ${q(table.name)} WHERE ${where} RETURNING id`,
    values: p.values,
  }
}

/** 路由层拿表名时用，顺手把非法表名挡掉。 */
export function requireTable(name: string): TableDef {
  const def = tableDef(name)
  if (!def) throw badRequest(`没有这张表：${name}`)
  return def
}
