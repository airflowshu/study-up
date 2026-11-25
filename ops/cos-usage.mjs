/**
 * 统计 COS 桶的实际占用。
 *
 * 用法（在项目根目录）：
 *   node --env-file=.env ops/cos-usage.mjs
 *
 * 输出对象数、总字节、占 50GB 套餐的比例，以及按家庭分批的占用。
 * 云监控上的「存储量」有延迟，这里直接列举对象求和，是当下的真实值。
 */
import crypto from 'node:crypto'
const { COS_SECRET_ID, COS_SECRET_KEY, COS_BUCKET, COS_REGION } = process.env
const HOST = `${COS_BUCKET}.cos.${COS_REGION}.myqcloud.com`
const hmac=(k,d)=>crypto.createHmac('sha1',k).update(d,'utf8').digest('hex')
const sha1=(d)=>crypto.createHash('sha1').update(d,'utf8').digest('hex')
function sign(m,p,params={}){
  const t=Math.floor(Date.now()/1000), kt=`${t};${t+600}`, sk=hmac(COS_SECRET_KEY,kt)
  const hl='host', hs=`host=${encodeURIComponent(HOST)}`
  const pk=Object.keys(params).sort(), pl=pk.join(';'), ps=pk.map(k=>`${k}=${encodeURIComponent(params[k])}`).join('&')
  const sts=`sha1\n${kt}\n${sha1(`${m.toLowerCase()}\n/${p}\n${ps}\n${hs}\n`)}\n`
  return `q-sign-algorithm=sha1&q-ak=${COS_SECRET_ID}&q-sign-time=${kt}&q-key-time=${kt}&q-header-list=${hl}&q-url-param-list=${pl}&q-signature=${hmac(sk,sts)}`
}
async function list(marker){
  const params = { 'max-keys':'1000' }
  if (marker) params.marker = marker
  const qs='?'+Object.keys(params).sort().map(k=>`${k}=${encodeURIComponent(params[k])}`).join('&')
  const r = await fetch(`https://${HOST}/${qs}`,{headers:{Host:HOST,Authorization:sign('GET','',params)}})
  return r.text()
}
let marker='', total=0, count=0, bytes=0, byFamily={}
for(;;){
  const xml = await list(marker)
  const items = [...xml.matchAll(/<Key>([^<]*)<\/Key>[\s\S]*?<Size>(\d+)<\/Size>/g)]
  for (const [,k,sz] of items){
    const size = Number(sz)
    count++; bytes += size
    const fam = k.split('/')[1] ?? 'other'
    byFamily[fam] = (byFamily[fam] ?? 0) + size
  }
  if(!/<IsTruncated>true<\/IsTruncated>/.test(xml) || items.length===0) break
  marker = items[items.length-1][1]
}
console.log(`对象数: ${count}`)
console.log(`总占用: ${(bytes/1024/1024).toFixed(2)} MB  (${bytes} 字节)`)
console.log(`占 50GB 套餐的 ${(bytes/1024/1024/1024/50*100).toFixed(4)}%`)
for (const [f,v] of Object.entries(byFamily)) console.log(`  ${f}: ${(v/1024/1024).toFixed(2)} MB`)
