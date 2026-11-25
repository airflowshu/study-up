/** 启动入口。构建逻辑在 app.ts，这里只负责连库、迁移、监听、优雅退出。 */
import { config } from './config.js'
import { pool } from './db/pool.js'
import { migrate } from './db/migrate.js'
import { buildApp } from './app.js'

async function main(): Promise<void> {
  const app = await buildApp()

  try {
    await migrate()
  } catch (e) {
    app.log.error({ err: e }, '数据库迁移失败')
    throw e
  }

  await app.listen({ port: config.port, host: '0.0.0.0' })
  app.log.info(`监听 ${config.port}，数据目录 ${config.dataDir}`)
}

async function shutdown(signal: string): Promise<void> {
  console.log(`[main] 收到 ${signal}，准备退出`)
  await pool.end().catch(() => undefined)
  process.exit(0)
}
process.on('SIGTERM', () => void shutdown('SIGTERM'))
process.on('SIGINT', () => void shutdown('SIGINT'))

main().catch((e) => {
  console.error(e)
  process.exit(1)
})
