import pg from 'pg'
import { config } from '../config.js'

// node-postgres 默认把 BIGINT(int8) 解析成字符串，客户端会崩：
// Flutter 的 done_at 用 `is num` 判断，Web 的 createdAt 也是 number。
// 这些列全是毫秒时间戳，远离 2^53，转成 number 安全。
pg.types.setTypeParser(pg.types.builtins.INT8, (v) => Number(v))

export const pool = new pg.Pool({
  connectionString: config.databaseUrl,
  // 默认 10 个连接是给多进程/高并发场景的。这套服务只有一个 Node 进程、
  // 一个家庭三个人用，实测稳态只开 2 个连接，3 是留了余量。
  // 所以这一项的直接收益很小（每个连接约 1-2MB，且本来就开不满），
  // 真正的价值是防止将来并发上来后无节制地开连接把 PG 内存吃满。
  max: 3,
  idleTimeoutMillis: 30_000,
  connectionTimeoutMillis: 10_000,
})

pool.on('error', (err) => {
  console.error('[pg] 空闲连接异常', err)
})
