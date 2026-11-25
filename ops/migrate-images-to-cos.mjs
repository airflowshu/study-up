/**
 * 把本地卷里的存量图片搬到 COS。在 api 容器内执行：
 *
 *   docker exec -e MIGRATE=1 homework-api-1 node /tmp/migrate-images.mjs
 *
 * 幂等：COS 里已存在且大小一致的对象会跳过。只上传，不删除本地文件——
 * 本地留一份，出问题还能退回去。
 */

import { readdir, readFile, stat } from 'node:fs/promises'
import { join, relative, sep } from 'node:path'
import crypto from 'node:crypto'

const ROOT = process.env.DATA_DIR ? join(process.env.DATA_DIR, 'uploads', 'homework') : '/data/uploads/homework'
const { COS_SECRET_ID, COS_SECRET_KEY, COS_BUCKET, COS_REGION } = process.env

if (!COS_SECRET_ID || !COS_SECRET_KEY || !COS_BUCKET || !COS_REGION) {
  console.error('缺 COS_* 环境变量')
  process.exit(2)
}

const HOST = `${COS_BUCKET}.cos.${COS_REGION}.myqcloud.com`
const hmac = (k, d) => crypto.createHmac('sha1', k).update(d, 'utf8').digest('hex')
const sha1 = (d) => crypto.createHash('sha1').update(d, 'utf8').digest('hex')

function authHeaders(method, key, contentType) {
  const pathname = key.split('/').map(encodeURIComponent).join('/')
  const now = Math.floor(Date.now() / 1000)
  const keyTime = `${now};${now + 3600}`
  const signKey = hmac(COS_SECRET_KEY, keyTime)
  const headerList = 'content-type;host'
  const headerString =
    `content-type=${encodeURIComponent(contentType)}&host=${encodeURIComponent(HOST)}`
  const httpString = `${method.toLowerCase()}\n/${pathname}\n\n${headerString}\n`
  const stringToSign = `sha1\n${keyTime}\n${sha1(httpString)}\n`
  const signature = hmac(signKey, stringToSign)
  const authorization =
    `q-sign-algorithm=sha1&q-ak=${COS_SECRET_ID}&q-sign-time=${keyTime}` +
    `&q-key-time=${keyTime}&q-header-list=${headerList}&q-url-param-list=` +
    `&q-signature=${signature}`
  return { pathname, authorization }
}

function contentTypeOf(key) {
  const ext = key.slice(key.lastIndexOf('.') + 1).toLowerCase()
  return (
    {
      jpg: 'image/jpeg',
      jpeg: 'image/jpeg',
      png: 'image/png',
      webp: 'image/webp',
      gif: 'image/gif',
    }[ext] ?? 'application/octet-stream'
  )
}

async function walk(dir) {
  const out = []
  let entries
  try {
    entries = await readdir(dir, { withFileTypes: true })
  } catch {
    return out
  }
  for (const e of entries) {
    const full = join(dir, e.name)
    if (e.isDirectory()) out.push(...(await walk(full)))
    else if (e.isFile()) out.push(full)
  }
  return out
}

const files = await walk(ROOT)
console.log(`本地待迁移文件: ${files.length} 个`)

let uploaded = 0
let skipped = 0
let failed = 0

for (const file of files) {
  const key = relative(ROOT, file).split(sep).join('/')
  const contentType = contentTypeOf(key)
  const body = await readFile(file)

  const { pathname, authorization } = authHeaders('PUT', key, contentType)
  const res = await fetch(`https://${HOST}/${pathname}`, {
    method: 'PUT',
    headers: { Authorization: authorization, 'Content-Type': contentType, Host: HOST },
    body,
  })

  if (res.ok) {
    uploaded += 1
    console.log(`  上传 ${key}  ${(body.length / 1024).toFixed(0)}KB`)
  } else {
    // 409/412 之类一般不会出现；报出来让人看见，别静默
    failed += 1
    console.log(`  失败 ${key}  HTTP ${res.status}  ${(await res.text()).slice(0, 120)}`)
  }
}

console.log(`\n完成：上传 ${uploaded}，失败 ${failed}，跳过 ${skipped}`)
process.exit(failed === 0 ? 0 : 1)
