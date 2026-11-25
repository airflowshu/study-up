/**
 * PostgREST 子集解析器。
 *
 * 客户端（Flutter 的 cloud_api.dart / Web 的 cloud.ts）用的是这套语法，
 * 换了后端也必须逐字兼容，否则客户端只改一个地址是跑不起来的。
 *
 * 支持的形态（就是客户端真实用到的全部）：
 *   col=eq.v      col=gte.v   col=lte.v   col=gt.v   col=lt.v   col=neq.v
 *   col=in.(a,b,c)
 *   col=is.null
 *   select=*      select=a,b
 *   order=col.asc,col2.desc
 *   limit=N
 *
 * 同名参数是 AND（`date=gte.x&date=lte.y` 是区间，不是覆盖）。
 */
import { badRequest } from '../errors.js'
import { coerce, columnDef, type TableDef } from './tables.js'

export type Op = 'eq' | 'neq' | 'gt' | 'gte' | 'lt' | 'lte' | 'in' | 'is'

export interface Filter {
  column: string
  op: Op
  /** in 时是数组，is 时是 null，其余是标量 */
  value: unknown
}

export interface Query {
  select: string[]
  filters: Filter[]
  order: Array<{ column: string; dir: 'asc' | 'desc' }>
  limit: number
}

const OPS: ReadonlySet<string> = new Set([
  'eq', 'neq', 'gt', 'gte', 'lt', 'lte', 'in', 'is',
])

/** 客户端不传 limit 时的兜底。硬上限防止一次拉爆内存。 */
const DEFAULT_LIMIT = 1000
const MAX_LIMIT = 5000

const RESERVED = new Set(['select', 'order', 'limit', 'offset'])

/**
 * 从原始查询串解析。刻意用 URLSearchParams 自己取，而不是依赖框架的
 * query 对象——不同实现对重复键的合并策略不一样，而重复键正是区间的写法。
 */
export function parseQuery(rawQuery: string, table: TableDef): Query {
  const sp = new URLSearchParams(rawQuery)
  const query: Query = { select: [], filters: [], order: [], limit: DEFAULT_LIMIT }

  // ---- select ----
  const selectRaw = sp.get('select')
  if (selectRaw && selectRaw !== '*') {
    for (const name of selectRaw.split(',')) {
      const trimmed = name.trim()
      if (!trimmed) continue
      if (!columnDef(table, trimmed)) {
        throw badRequest(`没有这一列：${trimmed}`)
      }
      query.select.push(trimmed)
    }
  }

  // ---- order ----
  for (const spec of sp.getAll('order')) {
    for (const part of spec.split(',')) {
      const [column, dirRaw] = part.trim().split('.')
      if (!column) continue
      if (!columnDef(table, column)) {
        throw badRequest(`排序字段不存在：${column}`)
      }
      const dir = dirRaw === 'desc' ? 'desc' : 'asc'
      query.order.push({ column, dir })
    }
  }

  // ---- limit ----
  const limitRaw = sp.get('limit')
  if (limitRaw !== null) {
    const n = Number(limitRaw)
    if (!Number.isFinite(n) || n < 0) throw badRequest('limit 不对')
    query.limit = Math.min(Math.trunc(n), MAX_LIMIT)
  }

  // ---- 列过滤 ----
  for (const [key, value] of sp.entries()) {
    if (RESERVED.has(key)) continue

    const def = columnDef(table, key)
    if (!def) throw badRequest(`没有这一列：${key}`)

    const dot = value.indexOf('.')
    if (dot < 0) throw badRequest(`过滤条件写法不对：${key}=${value}`)

    const opRaw = value.slice(0, dot)
    const rest = value.slice(dot + 1)
    if (!OPS.has(opRaw)) {
      throw badRequest(`不支持的过滤操作：${opRaw}`)
    }
    const op = opRaw as Op

    if (op === 'is') {
      if (rest !== 'null') throw badRequest(`is. 只支持 null，收到：${rest}`)
      query.filters.push({ column: key, op, value: null })
      continue
    }

    if (op === 'in') {
      if (!rest.startsWith('(') || !rest.endsWith(')')) {
        throw badRequest(`in. 的写法要像 in.(a,b)，收到：${rest}`)
      }
      const inner = rest.slice(1, -1)
      const values: unknown[] = []
      if (inner.length > 0) {
        for (const piece of inner.split(',')) {
          const converted = coerce(piece, def.type)
          if (converted === undefined) {
            throw badRequest(`${key} 的值类型不对：${piece}`)
          }
          values.push(converted)
        }
      }
      query.filters.push({ column: key, op, value: values })
      continue
    }

    const converted = coerce(rest, def.type)
    if (converted === undefined) {
      throw badRequest(`${key} 的值类型不对：${rest}`)
    }
    query.filters.push({ column: key, op, value: converted })
  }

  return query
}
