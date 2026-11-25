/** 业务数据访问层：只在云端。Web 端不做本地库 —— 电脑上断开网络本来就干不了活，
 *  额外维护一份本地缓存会把「两端谁是真源」这件事搞复杂。 */

import { API, cloud } from './cloud'
import { compressImage } from './imageCompress'
import type { Attachment, Child, Family, Homework, HomeworkDraft } from './types'
import { randomId } from './uuid'

type Raw = Record<string, unknown>

const str = (v: unknown, fallback = ''): string =>
  typeof v === 'string' ? v : fallback
const num = (v: unknown, fallback = 0): number => {
  if (typeof v === 'number') return v
  if (typeof v === 'string') {
    const n = Number(v)
    return Number.isFinite(n) ? n : fallback
  }
  return fallback
}

function toFamily(r: Raw): Family {
  return {
    id: str(r.id),
    code: str(r.code),
    name: str(r.name),
    createdAt: num(r.created_at),
  }
}

function toChild(r: Raw): Child {
  return {
    id: str(r.id),
    familyId: str(r.family_id),
    name: str(r.name),
    colorIndex: num(r.color_index),
    createdAt: num(r.created_at),
  }
}

function toAttachment(v: unknown): Attachment | null {
  if (!v || typeof v !== 'object') return null
  const r = v as Raw
  const kind = str(r.kind) === 'link' ? 'link' : 'file'
  const id = str(r.id)
  // 没有 id 的老数据补一个：后面删改要靠它对上云端对象，不能是空串
  return {
    id: id || randomId().replace(/-/g, ''),
    kind,
    key: str(r.key),
    name: str(r.name),
    size: num(r.size),
    mime: str(r.mime),
    url: str(r.url),
    title: str(r.title),
    desc: str(r.desc),
    site: str(r.site),
    image: str(r.image),
  }
}

function toAttachments(v: unknown): Attachment[] {
  if (!Array.isArray(v)) return []
  return v.map(toAttachment).filter((a): a is Attachment => a !== null)
}

/** 写回云端前把空字段剔掉：链接类没有 key、文件类没有 url，存一堆空串纯属浪费。 */
function toCloudAttachment(a: Attachment): Record<string, unknown> {
  const out: Record<string, unknown> = { id: a.id, kind: a.kind }
  if (a.key) out.key = a.key
  if (a.name) out.name = a.name
  if (a.size > 0) out.size = a.size
  if (a.mime) out.mime = a.mime
  if (a.url) out.url = a.url
  if (a.title) out.title = a.title
  if (a.desc) out.desc = a.desc
  if (a.site) out.site = a.site
  if (a.image) out.image = a.image
  return out
}

function toHomework(r: Raw): Homework {
  const rawImages = r.images
  const keys = Array.isArray(rawImages)
    ? rawImages.map((e) => (typeof e === 'string' ? e : ''))
    : []
  return {
    id: str(r.id),
    childId: str(r.child_id),
    familyId: str(r.family_id),
    date: str(r.date),
    subject: str(r.subject),
    content: str(r.content),
    imageKeys: keys,
    attachments: toAttachments(r.attachments),
    isDone: r.is_done === true,
    doneAt: typeof r.done_at === 'number' ? r.done_at : null,
    createdAt: num(r.created_at),
    updatedAt: num(r.updated_at),
    isDeleted: r.is_deleted === true,
  }
}

export function newId(): string {
  return randomId()
}

// ---------------- 家庭 ----------------

/**
 * 凭家庭码登录。
 *
 * 注意这里不再是「查表比对」——服务端校验家庭码，通过才签发 token，
 * 并把 family_id 写进 token 的 subject。之后所有请求的隔离都由服务端负责，
 * 客户端传的 family_id 会被丢弃。
 */
export async function loginFamily(code: string): Promise<Family> {
  const { family } = await cloud.signInFamily(code)
  return {
    id: family.id,
    code: family.code,
    name: family.name,
    createdAt: family.created_at,
  }
}

/**
 * 拉当前登录家庭的信息。
 *
 * 不传 id：服务端只回 token 对应的那一行。传了也会被覆盖——
 * 这正好防住"改了 localStorage 就以为能进别人家"。
 */
export async function fetchMyFamily(): Promise<Family | null> {
  const rows = await cloud.select<Raw>('families', [
    ['select', '*'],
    ['limit', '1'],
  ])
  const first = rows[0]
  return first ? toFamily(first) : null
}

// ---------------- 孩子 ----------------

export async function fetchChildren(familyId: string): Promise<Child[]> {
  // familyId 参数保留只为调用处不用改。服务端会用 token 里的家庭 id 覆盖它。
  void familyId
  const rows = await cloud.select<Raw>('children', [
    ['is_deleted', 'eq.false'],
    ['select', '*'],
    ['order', 'created_at.asc'],
  ])
  return rows.map(toChild)
}

export async function createChild(input: {
  familyId: string
  name: string
  colorIndex: number
}): Promise<Child> {
  const now = Date.now()
  const row = {
    id: newId(),
    family_id: input.familyId,
    name: input.name,
    color_index: input.colorIndex,
    created_at: now,
    updated_at: now,
    is_deleted: false,
  }
  await cloud.insert('children', row)
  return toChild(row)
}

export async function updateChild(
  id: string,
  fields: { name?: string; colorIndex?: number },
): Promise<void> {
  const patch: Record<string, unknown> = { updated_at: Date.now() }
  if (fields.name !== undefined) patch.name = fields.name
  if (fields.colorIndex !== undefined) patch.color_index = fields.colorIndex
  await cloud.patch('children', id, patch)
}

/** 软删除：孩子名下已布置的作业仍在，孩子的历史记录不会凭空消失 */
export async function softDeleteChild(id: string): Promise<void> {
  await cloud.patch('children', id, {
    is_deleted: true,
    updated_at: Date.now(),
  })
}

// ---------------- 作业 ----------------

export async function fetchHomework(
  familyId: string,
  opts: { childIds: string[]; from?: string; to?: string },
): Promise<Homework[]> {
  // family_id 由服务端注入，这里传不传都不影响结果
  void familyId
  const params: Array<[string, string]> = [
    ['is_deleted', 'eq.false'],
    ['select', '*'],
    ['order', 'date.desc,created_at.desc'],
  ]
  if (opts.from) params.push(['date', `gte.${opts.from}`])
  if (opts.to) params.push(['date', `lte.${opts.to}`])
  // child_id=in.(a,b) —— 只取本家庭现存孩子名下的
  if (opts.childIds.length) {
    params.push(['child_id', `in.(${opts.childIds.join(',')})`])
  } else {
    return []
  }
  if (!opts.to && !opts.from) params.push(['limit', '300'])
  const rows = await cloud.select<Raw>('homework', params)
  return rows.map(toHomework)
}

/** 单条作业。编辑页进来时用，避免为了改一条把整月都拉下来。 */
export async function fetchHomeworkById(id: string): Promise<Homework | null> {
  const rows = await cloud.select<Raw>('homework', [
    ['id', `eq.${id}`],
    ['select', '*'],
    ['limit', '1'],
  ])
  const first = rows[0]
  return first ? toHomework(first) : null
}

/**
 * 保存作业内容。
 *
 * **只写内容字段**（child_id / family_id / date / subject / content / images），
 * 绝不带 is_done / done_at —— 那两个字段归孩子端写。
 * 两端字段不重叠，孩子在手机上打的勾才不会被家长在电脑上的一次保存冲掉。
 */
export async function saveHomework(
  draft: HomeworkDraft,
  homeworkId: string,
  isNew: boolean,
): Promise<Homework> {
  const now = Date.now()
  const fields = {
    child_id: draft.childId,
    family_id: draft.familyId,
    date: draft.date,
    subject: draft.subject,
    content: draft.content,
    images: draft.imageKeys,
    // 附件整坨存 JSON：结构固定、只在家长这边写，没必要拆表
    attachments: draft.attachments.map(toCloudAttachment),
    updated_at: now,
  }

  if (!isNew) {
    const patched = await cloud.patch<Raw>('homework', homeworkId, fields)
    const row = patched[0]
    if (row) return toHomework(row)
    // 云端没有这条（换过设备/被清过），补插一条，别让这次的修改落空
  }
  return insertHomework(homeworkId, fields, draft, now)
}

async function insertHomework(
  id: string,
  fields: Record<string, unknown>,
  draft: HomeworkDraft,
  now: number,
): Promise<Homework> {
  const row = {
    id,
    ...fields,
    is_done: false,
    done_at: null,
    created_at: now,
    is_deleted: false,
  }
  await cloud.insert('homework', row)
  return toHomework({ ...row, subject: draft.subject })
}

export async function softDeleteHomework(id: string): Promise<void> {
  await cloud.patch('homework', id, {
    is_deleted: true,
    updated_at: Date.now(),
  })
}

// ---------------- 图片 ----------------

function extOf(blob: Blob): string {
  const type = blob.type.toLowerCase()
  if (type.includes('png')) return '.png'
  if (type.includes('webp')) return '.webp'
  if (type.includes('gif')) return '.gif'
  return '.jpg'
}

/**
 * 上传一张作业图片，返回云 key。
 *
 * key 形如 `f/<家庭id>/homework/<作业id>/<唯一标识>.jpg`，两段前缀各有用途：
 *   - `f/<家庭id>/` 让服务端做 O(1) 的归属校验，别人家的 token 写不进这个路径；
 *   - 唯一标识而不是「第几张」，是因为电脑上删掉中间一张再补一张时位置序号会重复，
 *     按序号命名会把前面那张覆盖掉。图在作业里的位置由 images 数组顺序决定。
 *
 * 路径刻意不依赖作业行是否已存在 —— 客户端是「先传图、后插行」，
 * 服务端若要求先有作业，第一次发带图作业就会 403。
 */
export async function uploadHomeworkImage(
  familyId: string,
  homeworkId: string,
  slot: string,
  blob: Blob,
): Promise<string> {
  // 先压再传：家宽经 Cloudflare Tunnel 的上行只有 ~25KB/s，原图直传要几十秒。
  // 扩展名必须取自压缩后的 blob，压缩会把 PNG 转成 JPEG。
  const optimized = await compressImage(blob)
  const key = `f/${familyId}/homework/${homeworkId}/${slot}${extOf(optimized)}`
  await cloud.uploadImage(key, optimized)
  return key
}

// ---------------- 附件与链接 ----------------

/** 附件大小上限，和服务端 config.maxImageBytes 一致，先拦一道省得传完被拒。 */
export const MAX_ATTACHMENT_BYTES = 20 * 1024 * 1024

/**
 * 上传一个文档附件，返回云端 key。
 *
 * key 用附件的稳定 id 拼，不用「第几个」：家长删掉中间那个再补一个，
 * 下标会重复，按序号命名会把前一个文件的内容覆盖掉。
 * 也不把原文件名拼进 key —— 中文、空格、重名都会让 URL 变脏。
 */
export async function uploadHomeworkFile(
  familyId: string,
  homeworkId: string,
  attachmentId: string,
  file: File,
): Promise<string> {
  const name = file.name.toLowerCase()
  const ext = name.endsWith('.docx') ? '.docx' : '.pdf'
  const mime = ext === '.docx'
    ? 'application/vnd.openxmlformats-officedocument.wordprocessingml.document'
    : 'application/pdf'
  const key = `f/${familyId}/homework/${homeworkId}/att-${attachmentId}${ext}`
  // 个别浏览器给 File 的空 type，服务端白名单会直接拒，这里补齐
  await cloud.uploadImage(key, file.type ? file : new Blob([file], { type: mime }))
  return key
}

export interface LinkPreview {
  url: string
  title: string
  desc: string
  image: string
  site: string
}

/**
 * 让服务端去抓网页的标题 / 描述 / 缩略图。
 *
 * 浏览器直接 fetch 第三方页面会被 CORS 挡死，所以这条必须绕服务端。
 * 抓不到就让服务端报错，前端退化成「域名 + 网址」，不阻塞发布。
 */
export async function fetchLinkPreview(url: string): Promise<LinkPreview> {
  const res = await cloud.request(
    'GET',
    `${API.baseUrl}/v1/link/preview?url=${encodeURIComponent(url)}`,
  )
  const data = (await res.json()) as Partial<LinkPreview>
  return {
    url: typeof data.url === 'string' ? data.url : url,
    title: typeof data.title === 'string' ? data.title : '',
    desc: typeof data.desc === 'string' ? data.desc : '',
    image: typeof data.image === 'string' ? data.image : '',
    site: typeof data.site === 'string' ? data.site : '',
  }
}
