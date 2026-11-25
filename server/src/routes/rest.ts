/**
 * 数据通道：`/v1/rdb/rest/:table`。
 *
 * 这是与老客户端兼容的关键一层。路由形态、查询语法、状态码、Prefer 语义
 * 全部按 PostgREST 的习惯来，客户端的数据层因此零改动。
 */
import type { FastifyInstance, FastifyReply, FastifyRequest } from 'fastify'
import { conflict, unauthorized } from '../errors.js'
import { attachAuth, requireAuth } from '../auth/guard.js'
import { pool } from '../db/pool.js'
import {
  buildDelete,
  buildInsert,
  buildSelect,
  buildUpdate,
  readableColumns,
  requireTable,
} from '../rest/build.js'
import { parseQuery } from '../rest/parse.js'
import type { TableDef } from '../rest/tables.js'

function rawQuery(req: FastifyRequest): string {
  const url = req.raw.url ?? ''
  const at = url.indexOf('?')
  return at < 0 ? '' : url.slice(at + 1)
}

function wantsRepresentation(req: FastifyRequest): boolean {
  const prefer = String(req.headers['prefer'] ?? '')
  return prefer.includes('return=representation')
}

/** PG 唯一键冲突（23505）映射成 409，客户端据此走"已存在"分支。 */
function mapPgError(e: unknown): never {
  const err = e as { code?: string; constraint?: string; message?: string }
  if (err.code === '23505') {
    throw conflict('记录已存在')
  }
  if (err.code === '23503') {
    throw conflict('关联的数据不存在')
  }
  if (err.code === '22P02') {
    throw conflict('字段类型不对')
  }
  throw e
}

function tableOf(req: FastifyRequest): TableDef {
  const params = req.params as { table?: string }
  return requireTable(String(params.table ?? ''))
}

export async function restRoutes(app: FastifyInstance): Promise<void> {
  app.get(
    '/v1/rdb/rest/:table',
    async (req: FastifyRequest, reply: FastifyReply) => {
      await attachAuth(req)
      const table = tableOf(req)

      // 没登录且该表不允许匿名读 → 401（不是 403）：
      // 客户端的 401 分支会清 token 重新登录，403 则会被当成业务错误弹给用户。
      if (!req.auth && !table.read.anon) throw unauthorized()

      const query = parseQuery(rawQuery(req), table)
      const built = buildSelect(table, query, req.auth)

      try {
        const res = await pool.query(built.text, built.values)
        return reply.send(res.rows)
      } catch (e) {
        mapPgError(e)
      }
    },
  )

  app.post(
    '/v1/rdb/rest/:table',
    { preHandler: requireAuth },
    async (req: FastifyRequest, reply: FastifyReply) => {
      const table = tableOf(req)
      const auth = req.auth
      if (!auth) throw unauthorized()

      // 客户端 insert 传的是单元素数组，这里也容忍单对象
      const body = req.body as unknown
      const rows = Array.isArray(body)
        ? (body as Array<Record<string, unknown>>)
        : [body as Record<string, unknown>]

      const built = buildInsert(table, rows, auth)

      try {
        const res = await pool.query(built.text, built.values)
        if (!wantsRepresentation(req)) {
          return reply.code(201).send()
        }
        return reply.code(201).send(res.rows)
      } catch (e) {
        mapPgError(e)
      }
    },
  )

  app.patch(
    '/v1/rdb/rest/:table',
    { preHandler: requireAuth },
    async (req: FastifyRequest, reply: FastifyReply) => {
      const table = tableOf(req)
      const auth = req.auth
      if (!auth) throw unauthorized()

      const query = parseQuery(rawQuery(req), table)
      const patch = (req.body ?? {}) as Record<string, unknown>
      const built = buildUpdate(table, query, patch, auth)

      try {
        const res = await pool.query(built.text, built.values)
        // 匹配 0 行也是 200 + []，绝不能 404：
        // 客户端靠这个判断"云端还没有这行"，进而补一次 insert。
        return reply.send(wantsRepresentation(req) ? res.rows : res.rows)
      } catch (e) {
        mapPgError(e)
      }
    },
  )

  app.delete(
    '/v1/rdb/rest/:table',
    { preHandler: requireAuth },
    async (req: FastifyRequest, reply: FastifyReply) => {
      const table = tableOf(req)
      const auth = req.auth
      if (!auth) throw unauthorized()

      const query = parseQuery(rawQuery(req), table)
      const built = buildDelete(table, query, auth)

      const res = await pool.query(built.text, built.values)
      return reply.code(200).send(res.rows)
    },
  )

  // 让「该表能不能读」的判断在启动期就被用到，避免 cfg 里写错列名到运行时才发现
  void readableColumns
}
