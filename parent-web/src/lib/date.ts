/** 日期工具。全部按**本地时区**算，不用 toISOString ——
 *  那个会转成 UTC，晚上 8 点之后「今天」就变成明天了。 */

const pad = (n: number) => (n < 10 ? `0${n}` : `${n}`)

/** yyyy-MM-dd */
export function toDateStr(d: Date): string {
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`
}

export function todayStr(): string {
  return toDateStr(new Date())
}

/** 解析 yyyy-MM-dd 为本地零点的 Date */
export function parseDateStr(s: string): Date {
  const [y, m, d] = s.split('-').map(Number)
  return new Date(y ?? 1970, (m ?? 1) - 1, d ?? 1)
}

export function addDays(s: string, n: number): string {
  const d = parseDateStr(s)
  d.setDate(d.getDate() + n)
  return toDateStr(d)
}

const WEEKDAYS = ['周日', '周一', '周二', '周三', '周四', '周五', '周六']

export function weekday(s: string): string {
  return WEEKDAYS[parseDateStr(s).getDay()] ?? ''
}

/** 「今天」「昨天」「明天」，其余给「3月5日」式短日期 */
export function friendlyDate(s: string): string {
  const today = todayStr()
  if (s === today) return '今天'
  if (s === addDays(today, -1)) return '昨天'
  if (s === addDays(today, 1)) return '明天'
  const d = parseDateStr(s)
  return `${d.getMonth() + 1}月${d.getDate()}日`
}

/** 「2026年11月2日 周一」 */
export function fullDate(s: string): string {
  const d = parseDateStr(s)
  return `${d.getFullYear()}年${d.getMonth() + 1}月${d.getDate()}日 ${weekday(s)}`
}

/** 毫秒时间戳 → HH:mm */
export function timeOf(ms: number): string {
  const d = new Date(ms)
  return `${pad(d.getHours())}:${pad(d.getMinutes())}`
}

/** 相对时间：刚刚 / 5 分钟前 / 3 小时前 / 2 天前 / 3月5日 */
export function timeAgo(ms: number): string {
  const diff = Date.now() - ms
  if (diff < 60_000) return '刚刚'
  if (diff < 3_600_000) return `${Math.floor(diff / 60_000)} 分钟前`
  if (diff < 86_400_000) return `${Math.floor(diff / 3_600_000)} 小时前`
  if (diff < 7 * 86_400_000) return `${Math.floor(diff / 86_400_000)} 天前`
  return fullDate(toDateStr(new Date(ms))).split(' ')[0] ?? ''
}
