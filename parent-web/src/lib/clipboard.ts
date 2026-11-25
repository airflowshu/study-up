/**
 * 剪贴板解析：把「文字 + 图片」的复制内容还原成正文草稿。
 *
 * 为什么需要这一层：在 Windows 上从浏览器、Word、微信复制一段图文混排的内容时，
 * `clipboardData.files` 往往是**空的** —— 剪贴板里没有图片的二进制，
 * 只有一个 HTML 片段，图片以 `<img src="...">` 的形式嵌在里面。
 * 只读 `files` 就会把图全丢掉，只粘进一串文字。
 *
 * 这里的做法：
 *   1. 遍历 text/html，遇到 `<img>` 输出一个 `[图片]` 占位，并记下它的地址；
 *   2. 占位符沿用 `richBody.ts` 的约定，`attachFiles()` 会把它们换成 `[图N]`；
 *   3. 图片地址由调用方异步下载成 File 再上传 —— 云存储直链是 public 且回显 CORS，
 *      所以从本站复制的图能读回字节；跨站图片被 CORS 拦住时保留占位并如实告知。
 */

/** 复制来源里可能出现、但浏览器读不到内容的图片地址 */
const UNREADABLE = /^(file|blob|about):/i

/** 单张图上限。超过就不下，避免一次粘贴把页面拖死 */
export const MAX_PASTED_IMAGE_BYTES = 20 * 1024 * 1024

/** 一次粘贴最多处理多少张图，防止复制整篇长文时上传几十张 */
export const MAX_PASTED_IMAGES = 10

/** 结束一个块时补换行，和正文的「段落之间空一行」对齐 */
const BLOCK_TAGS = new Set([
  'ADDRESS', 'ARTICLE', 'ASIDE', 'BLOCKQUOTE', 'DD', 'DIV', 'DL', 'DT',
  'FIELDSET', 'FIGCAPTION', 'FIGURE', 'FOOTER', 'FORM', 'H1', 'H2', 'H3',
  'H4', 'H5', 'H6', 'HEADER', 'HR', 'LI', 'MAIN', 'NAV', 'OL', 'P', 'PRE',
  'SECTION', 'TABLE', 'TBODY', 'TD', 'TFOOT', 'TH', 'THEAD', 'TR', 'UL',
])

/** 这些标签里的内容不是给人读的正文 */
const SKIP_TAGS = new Set(['HEAD', 'SCRIPT', 'STYLE', 'NOSCRIPT', 'TEMPLATE', 'TITLE'])

/**
 * QQ / 微信把**内置表情**（超级表情、动态表情）降级成的纯文字占位。
 *
 * 实测 QQ（NT 版）复制「文字 + 3 个动态表情」后，剪贴板是这样的：
 *
 *   types : ["text/plain", "text/html"]
 *   plain : 数学建议：……P24和P25。[表情][表情][表情]
 *   html  : 数学建议：……P24和P25。[表情][表情][表情]
 *
 * 两份内容一模一样，HTML 里**没有 `<img>`**。也就是说表情在写进剪贴板的那一刻
 * 就已经被替换成了一个通用文字标记 —— 具体是哪个表情、长什么样、是不是在动，
 * 这些信息全部丢失，网页端没有任何办法还原成 Unicode emoji。
 *
 * 注意和 **Unicode emoji** 区分：👍🌟🌹🤝🙏 这类是字符，`text/plain` 里原样存在，
 * 粘贴完全正常。会动的表情（QQ 超级表情）本质是 GIF/APNG 图片，不走这条路。
 */
const EMOJI_PLACEHOLDER = /\[(?:动画表情|表情)\]/g

/** 剔除正文里的内置表情占位，返回干净文本和被剔除的个数 */
export function stripEmojiPlaceholders(s: string): { text: string; count: number } {
  const count = (s.match(EMOJI_PLACEHOLDER) ?? []).length
  return { text: count ? s.replace(EMOJI_PLACEHOLDER, '') : s, count }
}

export interface ClipboardDraft {
  /** 纯文本，图片位置是 `[图片]` 占位；内置表情的 `[表情]` 占位已剔除 */
  text: string
  /** 按出现顺序排列的图片地址，最后一个没取到不影响前面的配对 */
  imageSrcs: string[]
  /** 有图但地址读不到（本地文件等）的数量，用来给用户一句明确的提示 */
  unreadable: number
  /** 被拒的具体地址，仅用于诊断打印，不展示给用户 */
  blocked: string[]
  /** 被源程序降级成 `[表情]` 的内置表情个数，已从 text 里剔除 */
  emojiCount: number
}

/**
 * 从 img 上挑一个最可能可用的地址。
 *
 * 顺序很关键：**先挑能读的**。很多程序（微信 PC、QQ）把 `<img src>` 写成
 * `file:///C:/Users/...` 这种本地缓存路径，同时把真地址塞在 `data-src` 里。
 * 早先的写法无条件相信 `src`，于是一张本能取到的图被误判成「本地文件读不到」。
 */
function pickSrc(img: Element): string {
  const candidates: string[] = []
  const push = (v: string | null | undefined) => {
    const s = v?.trim()
    if (s && !s.startsWith('data:image/gif')) candidates.push(s)
  }

  push(img.getAttribute('src'))
  // 懒加载图常把真地址放在 data-* 或 srcset 里
  for (const attr of ['data-src', 'data-original', 'data-actualsrc', 'data-lazy-src']) {
    push(img.getAttribute(attr))
  }
  const srcset = img.getAttribute('srcset')
  if (srcset) push(srcset.split(',')[0]?.trim().split(/\s+/)[0])

  return candidates.find((s) => !UNREADABLE.test(s)) ?? candidates[0] ?? ''
}

/** 把一段 HTML 摊成纯文本，图片变成 `[图片]` 占位 */
export function htmlToDraft(html: string): ClipboardDraft {
  const doc = new DOMParser().parseFromString(html, 'text/html')
  const out = { text: '', imageSrcs: [] as string[] }
  let unreadable = 0
  const blocked: string[] = []

  const walk = (node: Node): void => {
    if (node.nodeType === Node.TEXT_NODE) {
      const raw = node.nodeValue ?? ''
      out.text += raw
        .replace(/\u00a0/g, ' ')
        // 只清真正的隐形垃圾字符（零宽空格、零宽不连字、BOM）。
        // **U+200D（ZWJ）必须留着** —— 它是 emoji 组合序列的连接符，
        // 删掉会把 👨‍👩‍👧 拆成三个独立的人、把 👩‍💻 拆成人加电脑。
        .replace(/[\u200b\u200c\ufeff]/g, '')
      return
    }
    if (node.nodeType !== Node.ELEMENT_NODE) return

    const el = node as Element
    const tag = el.tagName.toUpperCase()
    if (SKIP_TAGS.has(tag)) return

    if (tag === 'BR') {
      out.text += '\n'
      return
    }

    if (tag === 'IMG') {
      const src = pickSrc(el)
      if (!src || UNREADABLE.test(src)) {
        unreadable += 1
        if (src) blocked.push(src)
        return
      }
      out.imageSrcs.push(src)
      out.text += '[图片]'
      return
    }

    const isBlock = BLOCK_TAGS.has(tag)
    if (isBlock && out.text && !out.text.endsWith('\n')) out.text += '\n'
    for (const child of Array.from(el.childNodes)) walk(child)
    if (isBlock && out.text && !out.text.endsWith('\n')) out.text += '\n'
  }

  walk(doc.body)

  // 内置表情的占位是纯文字，摊平之后才认得出来。
  // 留着会让孩子端看到「[表情]」这三个字，正文一眼就是机器痕迹，所以直接剔掉，
  // 由调用方弹一句提示告诉家长「表情没带过来、要保留请截图」。
  const { text: cleaned, count: emojiCount } = stripEmojiPlaceholders(out.text)

  return {
    text: tidy(cleaned),
    imageSrcs: out.imageSrcs.slice(0, MAX_PASTED_IMAGES),
    unreadable,
    blocked,
    emojiCount,
  }
}

/** 收拾 HTML 摊平后常见的空行爆炸与行尾空白 */
function tidy(s: string): string {
  return s
    .split('\n')
    .map((line) => line.replace(/[ \t]+$/g, ''))
    .join('\n')
    .replace(/\n{3,}/g, '\n\n')
    .replace(/^\n+/, '')
    .replace(/\n+$/, '')
}

/**
 * 读一次粘贴事件，判断它属于哪种情况。
 *
 * - `files` 里有图（截图、右键复制图片、Finder 里复制的文件）→ 字节就在剪贴板里，最可靠
 * - 没有图但 HTML 里有 `<img>` → 图文混排复制，得按地址去下载
 * - 只有 `[表情]` 占位 → 源程序把内置表情降级成了文字，要接管粘贴才能剔干净并提示
 * - 三者都没有 → 普通文字粘贴，交回浏览器默认行为
 */
export function readClipboard(e: ClipboardEvent): {
  files: File[]
  draft: ClipboardDraft | null
} {
  const all = Array.from(e.clipboardData?.files ?? [])
  const files = all.filter((f) => f.type.startsWith('image/'))
  if (files.length) return { files, draft: null }

  const html = e.clipboardData?.getData('text/html') ?? ''
  const plain = e.clipboardData?.getData('text/plain') ?? ''

  // QQ 这类程序给的 html 就是一段裸文字（没有标签），DOMParser 一样能处理；
  // 但纯文本里才有的占位要单独看，否则会漏掉「整条只有表情」这种情况。
  const src = html.trim() ? html : plain
  if (!src.trim()) return { files: [], draft: null }

  const draft = htmlToDraft(src)
  if (!draft.imageSrcs.length && !draft.unreadable && !draft.emojiCount) {
    return { files: [], draft: null }
  }
  return { files: [], draft }
}

function extFromType(type: string): string {
  const sub = type.split('/')[1] ?? 'png'
  if (sub === 'jpeg') return 'jpg'
  if (sub === 'svg+xml') return 'svg'
  return sub.replace(/[^a-z0-9]/gi, '') || 'png'
}

function dataUriToFile(uri: string, index: number): File | null {
  const m = /^data:([^;,]+)?(;base64)?,(.*)$/s.exec(uri)
  if (!m) return null
  const type = m[1] || 'image/png'
  const isBase64 = Boolean(m[2])
  const payload = m[3] ?? ''
  try {
    let bytes: Uint8Array<ArrayBuffer>
    if (isBase64) {
      const bin = atob(payload)
      // 显式用 ArrayBuffer 构造：TS 会把 Uint8Array(n) 推成 ArrayBufferLike，而 BlobPart 只收 ArrayBuffer
      bytes = new Uint8Array(new ArrayBuffer(bin.length))
      for (let i = 0; i < bin.length; i += 1) bytes[i] = bin.charCodeAt(i)
    } else {
      bytes = new TextEncoder().encode(decodeURIComponent(payload))
    }
    return new File([bytes], `pasted-${index}.${extFromType(type)}`, { type })
  } catch {
    return null
  }
}

/**
 * 把一个图片地址变成可上传的 File。
 *
 * 失败返回 null 而不是抛错：一张图取不到不该让整个粘贴失败，
 * 文字和其余图片照常进来，占位留着让家长手动补。
 */
export async function fetchImageAsFile(
  src: string,
  index: number,
): Promise<File | null> {
  try {
    if (src.startsWith('data:image/')) return dataUriToFile(src, index)
    if (UNREADABLE.test(src) || !/^https?:/i.test(src)) return null

    const res = await fetch(src, { mode: 'cors', credentials: 'omit' })
    if (!res.ok) return null

    const len = Number(res.headers.get('content-length') ?? 0)
    if (len && len > MAX_PASTED_IMAGE_BYTES) return null

    const blob = await res.blob()
    if (!blob.type.startsWith('image/')) return null
    if (blob.size > MAX_PASTED_IMAGE_BYTES) return null

    return new File([blob], `pasted-${index}.${extFromType(blob.type)}`, {
      type: blob.type,
    })
  } catch {
    // 跨域被拦、断网、图片 404 都走这里
    return null
  }
}
