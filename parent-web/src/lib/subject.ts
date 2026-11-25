/** 学科与配色的固定表，与 Flutter 端 `lib/core/theme.dart` 保持一致。
 *  同一学科在各端颜色相同，孩子和家长看到的是同一个视觉线索。 */

export const SUBJECTS = [
  '语文',
  '数学',
  '英语',
  '科学',
  '道法',
  '体育',
  '美术',
  '音乐',
] as const

export const SUBJECT_COLORS: Record<string, string> = {
  语文: '#2F7FF3',
  数学: '#10B981',
  英语: '#F59E0B',
  科学: '#7C3AED',
  道法: '#EF4444',
  体育: '#06B6D4',
  美术: '#EC4899',
  音乐: '#14B8A6',
}

export function subjectColor(subject: string): string {
  return SUBJECT_COLORS[subject] ?? '#767C8C'
}

export const CHILD_COLORS = [
  '#5B6BF5',
  '#10B981',
  '#F59E0B',
  '#7C3AED',
  '#EC4899',
  '#06B6D4',
]

export function childColor(index: number): string {
  return CHILD_COLORS[index % CHILD_COLORS.length] ?? '#5B6BF5'
}

/** 姓名首字，头像用 */
export function initialOf(name: string): string {
  return name.trim().slice(0, 1) || '?'
}
