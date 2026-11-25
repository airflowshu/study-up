/**
 * 迁移执行器：按文件名顺序跑 migrations/*.sql，记在 schema_migrations 里。
 *
 * 刻意不做事务回滚 —— 迁移文件本身用 `IF NOT EXISTS` 保证幂等，
 * 单条失败就停下并打印是哪一条，比自动回滚更好排查。
 */
import { readdir, readFile } from 'node:fs/promises'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { pool } from './pool.js'

const here = dirname(fileURLToPath(import.meta.url))

/** 源码跑（tsx src/db）与编译产物跑（node dist/db）目录层级不同，两种都试。 */
async function resolveMigrationsDir(): Promise<string> {
  const candidates = [
    join(here, '../../migrations'),
    join(here, '../../../migrations'),
    join(process.cwd(), 'migrations'),
  ]
  for (const dir of candidates) {
    try {
      await readdir(dir)
      return dir
    } catch {
      /* 继续找下一个 */
    }
  }
  throw new Error(`找不到 migrations 目录，试过：\n${candidates.join('\n')}`)
}

export async function migrate(): Promise<void> {
  const dir = await resolveMigrationsDir()
  await pool.query(`
    CREATE TABLE IF NOT EXISTS schema_migrations (
      name       TEXT PRIMARY KEY,
      applied_at BIGINT NOT NULL
    )
  `)

  const done = await pool.query<{ name: string }>(
    'SELECT name FROM schema_migrations',
  )
  const applied = new Set(done.rows.map((r) => r.name))

  const files = (await readdir(dir)).filter((f) => f.endsWith('.sql')).sort()
  let count = 0

  for (const file of files) {
    if (applied.has(file)) continue
    const sql = await readFile(join(dir, file), 'utf8')
    console.log(`[migrate] 执行 ${file}`)
    try {
      await pool.query(sql)
    } catch (e) {
      throw new Error(`迁移 ${file} 失败：${(e as Error).message}`)
    }
    await pool.query(
      'INSERT INTO schema_migrations (name, applied_at) VALUES ($1, $2)',
      [file, Date.now()],
    )
    count += 1
  }

  console.log(
    count === 0 ? '[migrate] 已是最新' : `[migrate] 完成，执行了 ${count} 个`,
  )
}

// 直接 `npm run migrate` 时执行
if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
  migrate()
    .then(() => pool.end())
    .then(() => process.exit(0))
    .catch((e) => {
      console.error(e)
      process.exit(1)
    })
}
