/**
 * 模态层栈：解决「多个弹层叠在一起时，Esc 该关哪个」和「body 滚动锁被互相覆盖」。
 *
 * 背景：抽屉里点图片会再叠一层灯箱。两边都是 `position: fixed` 的全屏层，
 * 各自都在 document 上挂了 Esc 监听、也都改 `document.body.style.overflow`。
 * 结果是：
 *   1. 按一次 Esc 两个一起关；
 *   2. 灯箱先关时把 overflow 恢复成抽屉打开之前的值，抽屉还在但页面能滚了。
 *
 * 这里用一个后进先出的栈：只有**栈顶**那一层响应 Esc，滚动锁按引用计数恢复。
 * 每层各持一个 token（Symbol），互不干扰。
 */

const stack: symbol[] = []
let savedOverflow = ''

/** 进入一层模态。必须在 useEffect 里调用，并配对 exitModal */
export function enterModal(token: symbol): void {
  if (stack.includes(token)) return
  if (stack.length === 0) {
    savedOverflow = document.body.style.overflow
    document.body.style.overflow = 'hidden'
  }
  stack.push(token)
}

/** 离开一层模态。重复调用无副作用 */
export function exitModal(token: symbol): void {
  const i = stack.lastIndexOf(token)
  if (i >= 0) stack.splice(i, 1)
  if (stack.length === 0) document.body.style.overflow = savedOverflow
}

/** 是否是最上层 —— 只有它该处理 Esc */
export function isTopModal(token: symbol): boolean {
  return stack[stack.length - 1] === token
}
