/**
 * 把容器本地的 APK 推到 COS。在 api 容器内执行：
 *
 *   docker exec homework-api-1 node /tmp/push-apk.mjs /data/uploads/apk/releases/homework-1.1.0.apk releases/homework-1.1.0.apk
 *
 * 为什么不在外面用 HTTP 走 /v1/admin/apk 上传：那条路要经过 Cloudflare 隧道，
 * 50MB 得传 9 分钟。容器内直接连 COS 上海，几十秒。
 */

import { readFile, stat } from 'node:fs/promises'
import crypto from 'node:crypto'

const [localPath, remoteKey] = process.argv.slice(2)
if (!localPath || !remoteKey) {
  console.error('用法: node push-apk.mjs <本地路径> <COS key>')
  process.exit(2)
}

const { COS_SECRET_ID, COS_SECRET_KEY, COS_BUCKET, COS_REGION } = process.env
if (!COS_SECRET_ID || !COS_SECRET_KEY || !COS_BUCKET || !COS_REGION) {
  console.error('缺 COS_* 环境变量')
  process.exit(2)
}

const HOST = `${COS_BUCKET}.cos.${COS_REGION}.myqcloud.com`
const CONTENT_TYPE = 'application/vnd.android.package-archive'
const hmac = (k, d) => crypto.createHmac('sha1', k).update(d, 'utf8').digest('hex')
const sha1 = (d) => crypto.createHash('sha1').update(d, 'utf8').digest('hex')

// key 统一加 apk/ 前缀，和本地卷 <DATA_DIR>/uploads/apk/<key> 对应
const key = `apk/${remoteKey}`
const pathname = key.split('/').map(encodeURIComponent).join('/')

const now = Math.floor(Date.now() / 1000)
const keyTime = `${now};${now + 3600}`
const signKey = hmac(COS_SECRET_KEY, keyTime)
const headerString =
  `content-type=${encodeURIComponent(CONTENT_TYPE)}&host=${encodeURIComponent(HOST)}`
const httpString = `put\n/${pathname}\n\n${headerString}\n`
const signature = hmac(signKey, `sha1\n${keyTime}\n${sha1(httpString)}\n`)
const authorization =
  `q-sign-algorithm=sha1&q-ak=${COS_SECRET_ID}&q-sign-time=${keyTime}` +
  `&q-key-time=${keyTime}&q-header-list=content-type;host&q-url-param-list=` +
  `&q-signature=${signature}`

const size = (await stat(localPath)).size
console.log(`上传 ${localPath}（${(size / 1048576).toFixed(1)}MB）-> ${key}`)

const body = await readFile(localPath)
const t0 = Date.now()
const res = await fetch(`https://${HOST}/${pathname}`, {
  method: 'PUT',
  headers: { Authorization: authorization, 'Content-Type': CONTENT_TYPE, Host: HOST },
  body,
})
const sec = (Date.now() - t0) / 1000
console.log(`HTTP ${res.status}  用时 ${sec.toFixed(1)}s  平均 ${(size / 1048576 / sec).toFixed(2)} MB/s`)
if (!res.ok) {
  console.log((await res.text()).slice(0, 300))
  process.exit(1)
}
console.log(`公网地址: https://${HOST}/${pathname}`)
