/**
 * 图文混排正文：图片位置写成行内标记 `[图3]`（3 = 第 3 张图）。
 *
 * 这套规则移植自 Flutter 端 `lib/core/rich_body.dart`，**两个端必须逐字一致**：
 * 孩子端 App 用同一套解析渲染，Web 端只要有任何偏差，
 * 家长在电脑上看到的预览和孩子手机上看到的内容就会不一样。
 *
 * 为什么用可见标记而不是「图片序号 + 字符偏移」：标记就是几个字符，
 * 选中、删除、剪切、粘贴、撤销全都天然生效，数据库也不用加字段。
 */

/** 严格合法的标记 */
export const IMAGE_MARKER = /\[图(\d{1,3})\]/

/** 宽松版：连写坏的标记一起认（`[图1`、`[图12]`）。
 *  必须带数字 —— 正文里「[图片]」这种写法很常见，把 `[图` 当标记会吃掉用户写的字。 */
const MARKER_OR_FRAGMENT = /\[图(\d{1,3})\]?/g

/** 待补图占位：微信复制图文消息时图片没进剪贴板，只在文字里留一个 `[图片]` */
export const IMAGE_HOLE = /\[图片\]/g

const HOLE_LENGTH = 4

export function imageMarker(index: number): string {
  return `[图${index}]`
}

/** 正文里待补图的占位起始下标 */
export function imageHoles(content: string): number[] {
  return [...content.matchAll(IMAGE_HOLE)].map((m) => m.index ?? 0)
}

export type BodyBlock =
  | { kind: 'text'; text: string }
  | { kind: 'images'; images: number[] }

function tidy(s: string): string {
  const t = s
    .replace(/\r\n?/g, '\n')
    .split('\n')
    .map((l) => l.replace(/[ \t]+/g, ' ').trim())
    .join('\n')
  return t.replace(/^\n+|\n+$/g, '')
}

/**
 * 把正文拆成「文字 / 图片组」的序列。
 *
 * 序号越界、重复的标记当普通文字留着，不删 —— 正文是家长写的，
 * 宁可多显示几个字也不能悄悄吞掉。
 */
export function parseBody(content: string, imageCount: number): BodyBlock[] {
  const blocks: BodyBlock[] = []
  let buf = ''
  const seen = new Set<number>()
  let group: number[] = []

  const flushText = () => {
    const s = tidy(buf)
    buf = ''
    if (s) blocks.push({ kind: 'text', text: s })
  }
  const flushGroup = () => {
    if (group.length) blocks.push({ kind: 'images', images: group })
    group = []
  }

  let cursor = 0
  for (const m of content.matchAll(MARKER_OR_FRAGMENT)) {
    const start = m.index ?? 0
    const between = content.slice(cursor, start)
    cursor = start + m[0].length
    buf += between
    const idx = Number.parseInt(m[1] ?? '', 10) || 0

    const valid = idx >= 1 && idx <= imageCount && !seen.has(idx)
    if (!valid) {
      // 不是有效标记：原样留在正文里
      buf += m[0]
      continue
    }
    seen.add(idx)

    if (group.length === 0) {
      flushText()
    } else if (between.trim() === '') {
      // 和上一张紧挨着（中间只有空白）：并进同一组
      buf = ''
    } else {
      flushGroup()
      flushText()
    }
    group.push(idx)
  }
  buf += content.slice(cursor)
  flushGroup()
  flushText()

  // 正文里没出现的图（老数据、标记被删坏）统一补在末尾，绝不丢图
  const missing: number[] = []
  for (let k = 1; k <= imageCount; k++) if (!seen.has(k)) missing.push(k)
  if (missing.length) blocks.push({ kind: 'images', images: missing })

  return blocks
}

/**
 * 保存前整理正文：
 * - 合法标记保留（重复的只留第一个）
 * - 序号越界的标记当普通文字留着
 * - 没被标记引用的图在末尾补上标记
 */
export function normalizeBody(content: string, imageCount: number): string {
  let out = ''
  const seen = new Set<number>()
  let cursor = 0
  for (const m of content.matchAll(MARKER_OR_FRAGMENT)) {
    const start = m.index ?? 0
    out += content.slice(cursor, start)
    cursor = start + m[0].length
    const idx = Number.parseInt(m[1] ?? '', 10) || 0
    if (idx >= 1 && idx <= imageCount) {
      if (!seen.has(idx)) {
        seen.add(idx)
        out += imageMarker(idx)
      }
    } else {
      out += m[0]
    }
  }
  out += content.slice(cursor)

  let text = out.replace(/[ \t]+\n/g, '\n').trim()
  const missing: number[] = []
  for (let k = 1; k <= imageCount; k++) if (!seen.has(k)) missing.push(k)
  if (missing.length) {
    const tail = missing.map(imageMarker).join('')
    text = text ? `${text}\n${tail}` : tail
  }
  return text
}

/** 删掉第 index 张图（1 开始）的标记，后面的序号整体减一 */
export function removeImageMarker(content: string, index: number): string {
  return content.replace(MARKER_OR_FRAGMENT, (all, digits: string) => {
    const idx = Number.parseInt(digits, 10) || 0
    if (idx === index) return ''
    if (idx > index) return imageMarker(idx - 1)
    return all
  })
}

/**
 * 正文字数：标记和空白不算。
 *
 * 用 UTF-16 长度而不是字素簇数，是**故意的**：Flutter 端
 * `rich_body.dart` 的 `plainLength` 用的就是 `.length`，两端必须算出同一个数，
 * 否则家长在电脑上看到 25 字、孩子手机上看到 30 字，会以为内容没同步。
 * 代价是一个 emoji 算 2～8 个字。要修就两端一起改（Dart 侧换 `characters`），
 * 不能只动一边。
 */
export function plainLength(content: string): number {
  return content
    .replace(MARKER_OR_FRAGMENT, '')
    .replace(/\s/g, '').length
}

/** 去掉标记的纯文字，列表摘要用；空行一并压掉 */
export function plainText(content: string): string {
  return content
    .replace(MARKER_OR_FRAGMENT, '')
    .replace(/\r\n?/g, '\n')
    .split('\n')
    .map((l) => l.replace(/[ \t]+/g, ' ').trim())
    .filter(Boolean)
    .join('\n')
    .trim()
}

/**
 * 在光标处插入图片标记，并让标记单独占一行 ——
 * 和正文挤在一行里，预览时会跟文字黏在一起，读不出因果。
 */
export function insertMarkerAt(
  content: string,
  cursor: number,
  index: number,
): { content: string; cursor: number } {
  const pos = Math.max(0, Math.min(cursor, content.length))
  const before = content.slice(0, pos)
  const after = content.slice(pos)
  const marker = imageMarker(index)
  const prefix = before && !before.endsWith('\n') ? '\n' : ''
  const suffix = after && !after.startsWith('\n') ? '\n' : ''
  const chunk = `${prefix}${marker}${suffix}`
  return { content: before + chunk + after, cursor: pos + chunk.length }
}

/** 一次插入多张图的标记（一次粘 5 张时只动一次正文，避免光标错位） */
export function insertMarkersAt(
  content: string,
  cursor: number,
  indexes: number[],
): { content: string; cursor: number } {
  if (!indexes.length) return { content, cursor }
  const pos = Math.max(0, Math.min(cursor, content.length))
  const before = content.slice(0, pos)
  const after = content.slice(pos)
  const markers = indexes.map(imageMarker).join('\n')
  const prefix = before && !before.endsWith('\n') ? '\n' : ''
  const suffix = after && !after.startsWith('\n') ? '\n' : ''
  const chunk = `${prefix}${markers}${suffix}`
  return { content: before + chunk + after, cursor: pos + chunk.length }
}

/** 把正文里前 count 个 `[图片]` 占位依次换成从 firstIndex 起的图片标记 */
export function fillImageHoles(
  content: string,
  firstIndex: number,
  count: number,
): { content: string; filled: number } {
  const holes = imageHoles(content)
  if (!holes.length || count <= 0) return { content, filled: 0 }
  const use = Math.min(holes.length, count)
  let text = content
  // 从后往前替换，前面占位的位置不受影响
  for (let i = use - 1; i >= 0; i--) {
    const pos = holes[i] ?? 0
    const end = pos + HOLE_LENGTH
    const marker = imageMarker(firstIndex + i)
    const prevCh = pos > 0 ? text[pos - 1] : '\n'
    const nextCh = end < text.length ? text[end] : '\n'
    const chunk = `${prevCh === '\n' ? '' : '\n'}${marker}${nextCh === '\n' ? '' : '\n'}`
    text = text.slice(0, pos) + chunk + text.slice(end)
  }
  return { content: text, filled: use }
}

/**
 * 清掉没被填上的 `[图片]` 占位。
 *
 * 粘贴图文时先落占位、再异步下载图片；下载失败（跨域、本地文件、404）就不会有图来填它。
 * 留着的话 `[图片]` 会原样出现在孩子手机上，还不如不显示 —— 所以按数量从后往前删。
 * 从后往前是因为 `fillImageHoles` 是从前开始填的，没填上的必然在尾部。
 */
export function dropTrailingHoles(content: string, count: number): string {
  if (count <= 0) return content
  let text = content
  for (let i = 0; i < count; i += 1) {
    const pos = text.lastIndexOf('[图片]')
    if (pos < 0) break
    let start = pos
    let end = pos + HOLE_LENGTH
    // 占位独占一行时把整行删掉，别留一个空行
    if (start > 0 && text[start - 1] === '\n') start -= 1
    if (text[end] === '\n') end += 1
    text = text.slice(0, start) + text.slice(end)
  }
  return text
}
