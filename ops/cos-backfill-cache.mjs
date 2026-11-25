/**
 * 给桶里已有的图片补 Cache-Control。
 *
 * 为什么需要：Cache-Control 是对象元数据，只能在写入时定。
 * 改造之前上传的图没有这个头，浏览器每次刷新都会重新下载。
 * 新上传的图已由 presign 接口自动带上，这个脚本只用于补历史数据。
 *
 * 用法（项目根目录）：
 *   node --env-file=.env ops/cos-backfill-cache.mjs
 *
 * 原理：PUT Object - Copy，源和目标都指向自己，metadata-directive=Replaced，
 * 只把 Cache-Control 换掉。Content-Type 按扩展名重新给，必须给对，
 * 否则图片会变成下载或显示异常。
 */
import crypto from 'node:crypto'
const { COS_SECRET_ID, COS_SECRET_KEY, COS_BUCKET, COS_REGION } = process.env
const HOST = `${COS_BUCKET}.cos.${COS_REGION}.myqcloud.com`
const CC = 'public, max-age=31536000, immutable'
const hmac=(k,d)=>crypto.createHmac('sha1',k).update(d,'utf8').digest('hex')
const sha1=(d)=>crypto.createHash('sha1').update(d,'utf8').digest('hex')

function sign(method, pathname, headers, params={}){
  const t=Math.floor(Date.now()/1000), kt=`${t};${t+600}`, sk=hmac(COS_SECRET_KEY,kt)
  const names = Object.keys(headers).map(h=>h.toLowerCase()).sort()
  const headerList = names.join(';')
  const headerString = names.map(n => {
    const v = Object.entries(headers).find(([k])=>k.toLowerCase()===n)[1]
    return `${n}=${encodeURIComponent(v)}`
  }).join('&')
  const pk = Object.keys(params).sort()
  const paramList = pk.join(';')
  const paramString = pk.map(k=>`${k}=${encodeURIComponent(params[k])}`).join('&')
  const sts = `sha1\n${kt}\n${sha1(`${method.toLowerCase()}\n/${pathname}\n${paramString}\n${headerString}\n`)}\n`
  return `q-sign-algorithm=sha1&q-ak=${COS_SECRET_ID}&q-sign-time=${kt}&q-key-time=${kt}&q-header-list=${headerList}&q-url-param-list=${paramList}&q-signature=${hmac(sk,sts)}`
}

async function listAll(){
  let marker='', out=[]
  for(;;){
    const p={'max-keys':'1000'}; if(marker) p.marker=marker
    const qs='?'+Object.keys(p).sort().map(k=>`${k}=${encodeURIComponent(p[k])}`).join('&')
    const auth = sign('GET','',{Host:HOST},p)
    const r=await fetch(`https://${HOST}/${qs}`,{headers:{Host:HOST,Authorization:auth}})
    const xml=await r.text()
    const items=[...xml.matchAll(/<Key>([^<]*)<\/Key>/g)].map(m=>m[1])
    out.push(...items)
    if(!/<IsTruncated>true<\/IsTruncated>/.test(xml)||items.length===0) break
    marker=items[items.length-1]
  }
  return out
}

const keys = await listAll()
console.log(`共 ${keys.length} 个对象`)
const TYPES = {'.jpg':'image/jpeg','.jpeg':'image/jpeg','.png':'image/png','.webp':'image/webp','.gif':'image/gif'}
let ok=0, skip=0, fail=0
for (const key of keys) {
  if (key.startsWith('apk/')) { skip++; continue }
  const ext = key.slice(key.lastIndexOf('.')).toLowerCase()
  const ct = TYPES[ext]
  if (!ct) { console.log(`  跳过（未知类型）${key}`); skip++; continue }
  const enc = key.split('/').map(encodeURIComponent).join('/')
  const headers = {
    'Host': HOST,
    'Cache-Control': CC,
    'Content-Type': ct,
    'x-cos-copy-source': `${HOST}/${enc}`,
    'x-cos-metadata-directive': 'Replaced',
  }
  const auth = sign('PUT', enc, headers)
  const r = await fetch(`https://${HOST}/${enc}`, { method:'PUT', headers: {...headers, Authorization: auth} })
  if (r.ok) { ok++ }
  else { fail++; console.log(`  失败 ${r.status} ${key} ${(await r.text()).slice(0,160)}`) }
}
console.log(`补缓存：成功 ${ok} / 跳过 ${skip} / 失败 ${fail}`)
