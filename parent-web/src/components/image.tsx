import { useCallback, useEffect, useRef, useState } from 'react'
import { createPortal } from 'react-dom'
import {
  ChevronLeft,
  ChevronRight,
  ExternalLink,
  ImageOff,
  Maximize2,
  Minus,
  Plus,
  RotateCcw,
  RotateCw,
  X,
} from 'lucide-react'
import { API } from '@/lib/cloud'
import { cn } from '@/lib/cn'
import { enterModal, exitModal, isTopModal } from '@/lib/modal'

/**
 * 图片直链。
 *
 * 服务端对这个路径是公开读的（`<img>` 带不了 Authorization 头），
 * 防扫靠 key 里的家庭 id 与作业 id 都是 UUID，猜不出来。
 */
export function imageUrl(key: string): string {
  return API.imageUrl(key)
}

export interface LightboxImage {
  key: string
  label?: string
}

/**
 * 单个缩略图。加载中给骨架，失败给明确的占位 ——
 * 家长最怕的是「图在这儿但看不到」，那样根本判断不出作业是不是传全了。
 */
export function Thumb({
  storageKey,
  onOpen,
  className,
  index,
}: {
  storageKey: string
  onOpen: () => void
  className?: string
  index?: number
}) {
  const [state, setState] = useState<'loading' | 'ok' | 'fail'>('loading')
  if (!storageKey) {
    return (
      <div
        className={cn(
          'flex flex-col items-center justify-center gap-1 rounded-lg border border-dashed border-line bg-surface-2 text-subtle',
          className,
        )}
      >
        <ImageOff className="size-4" />
        <span className="text-[11px]">图片缺失</span>
      </div>
    )
  }
  return (
    <button
      type="button"
      onClick={onOpen}
      className={cn(
        'group relative overflow-hidden rounded-lg border border-line bg-surface-2',
        'transition-shadow hover:border-line-strong hover:shadow-md',
        className,
      )}
      aria-label={`查看第 ${index ?? 1} 张图片`}
    >
      {state !== 'ok' ? (
        <div className="absolute inset-0 flex items-center justify-center">
          {state === 'loading' ? (
            <span className="size-4 animate-spin rounded-full border-2 border-line-strong border-t-primary" />
          ) : (
            <span className="flex flex-col items-center gap-1 text-subtle">
              <ImageOff className="size-4" />
              <span className="text-[11px]">加载失败</span>
            </span>
          )}
        </div>
      ) : null}
      <img
        src={imageUrl(storageKey)}
        alt=""
        loading="lazy"
        className={cn(
          'size-full object-cover transition-transform duration-300 group-hover:scale-[1.03]',
          state === 'ok' ? 'opacity-100' : 'opacity-0',
        )}
        onLoad={() => setState('ok')}
        onError={() => setState('fail')}
      />
      {index !== undefined ? (
        <span className="absolute left-1.5 top-1.5 rounded bg-black/55 px-1.5 py-0.5 text-[10px] font-medium text-white">
          {index}
        </span>
      ) : null}
    </button>
  )
}

const MIN_ZOOM = 1
const MAX_ZOOM = 8
/** 双击放大到多少倍。比 2 稍大一点，看小字更实在 */
const DOUBLE_CLICK_ZOOM = 2.5

interface View {
  zoom: number
  x: number
  y: number
}

const RESET: View = { zoom: 1, x: 0, y: 0 }

function clampZoom(z: number): number {
  return Math.min(MAX_ZOOM, Math.max(MIN_ZOOM, z))
}

/**
 * 全屏看图。滚轮缩放、放大后拖动平移、双击切换、键盘操作。
 *
 * **为什么用 portal**：抽屉（`HomeworkDetailDrawer`）带了 `animate-slide-in-right`，
 * 它的 transform 会让内部 `position: fixed` 的包含块变成抽屉自己。灯箱原本渲染在
 * `RichBodyView` 里，正好落在抽屉内部，于是「全屏」实际只有抽屉那 540px 宽，
 * 图片右侧整块甩到浏览器外面。portal 到 body 之后，fixed 永远相对视口，
 * 再也不受父级 transform / overflow / 层叠上下文影响。
 */
export function Lightbox({
  images,
  index,
  onClose,
  onChange,
}: {
  images: LightboxImage[]
  index: number
  onClose: () => void
  onChange: (i: number) => void
}) {
  const total = images.length
  const current = images[index]

  const [view, setView] = useState<View>(RESET)
  const [rotation, setRotation] = useState(0)
  const [dragging, setDragging] = useState(false)
  /** 舞台的可视尺寸。旋转 90° 后宽高互换，约束要按交换后的值重算 */
  const [stageSize, setStageSize] = useState({ w: 0, h: 0 })
  const stageRef = useRef<HTMLDivElement>(null)
  const imgRef = useRef<HTMLImageElement>(null)
  const dragRef = useRef<{
    px: number
    py: number
    ox: number
    oy: number
    limitX: number
    limitY: number
  } | null>(null)
  /** 拖动过就不该把松手当成「点空白关闭」 */
  const movedRef = useRef(false)
  const token = useRef(Symbol('lightbox')).current

  // 换一张图就复位，否则上一张的缩放、位移、旋转会带到新图上
  useEffect(() => {
    setView(RESET)
    setRotation(0)
  }, [index])

  // 舞台尺寸随窗口变化，旋转时的 fit 约束依赖它
  useEffect(() => {
    const el = stageRef.current
    if (!el) return
    const ro = new ResizeObserver((entries) => {
      const r = entries[0]?.contentRect
      if (r) setStageSize({ w: r.width, h: r.height })
    })
    ro.observe(el)
    return () => ro.disconnect()
  }, [])

  // 模态栈：body 滚动锁 + 让 Esc 只关最上面这一层（抽屉还开着时不能一起关掉）
  useEffect(() => {
    enterModal(token)
    return () => exitModal(token)
  }, [token])

  /** 以 anchor（相对舞台中心的像素偏移）为不动点缩放 */
  const zoomAt = useCallback((factor: number, anchor = { x: 0, y: 0 }) => {
    setView((v) => {
      const next = clampZoom(v.zoom * factor)
      if (next === v.zoom) return v
      if (next === MIN_ZOOM) return RESET
      const ratio = next / v.zoom
      return {
        zoom: next,
        x: (v.x - anchor.x) * ratio + anchor.x,
        y: (v.y - anchor.y) * ratio + anchor.y,
      }
    })
  }, [])

  /** 顺时针 / 逆时针转 90°。旋转后可视宽高互换，平移量按新方向重算，所以先归零 */
  const rotate = useCallback((delta: number) => {
    setRotation((r) => (r + delta + 360) % 360)
    setView((v) => ({ ...v, x: 0, y: 0 }))
  }, [])

  const resetAll = useCallback(() => {
    setView(RESET)
    setRotation(0)
  }, [])

  // 滚轮缩放。必须用原生监听 —— React 的 onWheel 是 passive 的，preventDefault 不生效
  useEffect(() => {
    const stage = stageRef.current
    if (!stage) return
    const onWheel = (e: WheelEvent) => {
      e.preventDefault()
      const rect = stage.getBoundingClientRect()
      const anchor = {
        x: e.clientX - rect.left - rect.width / 2,
        y: e.clientY - rect.top - rect.height / 2,
      }
      // deltaMode：0=像素 1=行 2=页。触控板的 deltaY 很小，鼠标滚一格约 100
      const unit = e.deltaMode === 1 ? 16 : e.deltaMode === 2 ? rect.height : 1
      // 指数映射：任意倍率下滚一格的手感都一致，不会越放大越猛
      zoomAt(Math.exp(-e.deltaY * unit * 0.0015), anchor)
    }
    stage.addEventListener('wheel', onWheel, { passive: false })
    return () => stage.removeEventListener('wheel', onWheel)
  }, [zoomAt])

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (!isTopModal(token)) return
      if (e.key === 'Escape') {
        e.preventDefault()
        onClose()
        return
      }
      if (e.key === 'ArrowLeft' && total > 1) {
        onChange((index - 1 + total) % total)
        return
      }
      if (e.key === 'ArrowRight' && total > 1) {
        onChange((index + 1) % total)
        return
      }
      if (e.key === '+' || e.key === '=') {
        e.preventDefault()
        zoomAt(1.35)
        return
      }
      if (e.key === '-' || e.key === '_') {
        e.preventDefault()
        zoomAt(1 / 1.35)
        return
      }
      if (e.key === 'r') {
        e.preventDefault()
        rotate(90)
        return
      }
      if (e.key === 'R') {
        e.preventDefault()
        rotate(-90)
        return
      }
      if (e.key === '0') resetAll()
    }
    document.addEventListener('keydown', onKey)
    return () => document.removeEventListener('keydown', onKey)
  }, [token, index, total, onChange, onClose, zoomAt, rotate, resetAll])

  if (!current) return null

  const src = imageUrl(current.key)

  /**
   * 在新标签打开原图。
   *
   * 不能直接用 `<a target="_blank">`：COS 默认域名会给对象加
   * `Content-Disposition: attachment`（2024 年后创建的桶都这样），
   * 浏览器会把它当成下载，点一下只会得到一个存到本地的文件。
   * 先 fetch 成 blob 再开，才是真的把图显示出来。
   *
   * 窗口必须在 await 之前同步打开：等 fetch 回来再 window.open
   * 已经脱离用户手势，会被弹窗拦截器拦掉。
   */
  const openOriginal = async () => {
    const win = window.open('', '_blank')
    try {
      const res = await fetch(src)
      if (!res.ok) throw new Error(String(res.status))
      const url = URL.createObjectURL(await res.blob())
      if (win) win.location.href = url
      else window.open(url, '_blank', 'noopener')
      // 给新标签留够加载时间，回收早了会白屏
      setTimeout(() => URL.revokeObjectURL(url), 60_000)
    } catch {
      // 兜底：直接开原地址，会退化成下载，但至少用户能拿到文件
      win?.close()
      window.open(src, '_blank', 'noopener')
    }
  }

  const zoomed = view.zoom > MIN_ZOOM
  /** 转了 90° 或 270°，可视宽高与原本的宽高互换 */
  const quarterTurn = rotation % 180 !== 0
  /** 有任何变换时「复位」才有意义 */
  const dirty = zoomed || rotation !== 0

  /**
   * 放大后可拖动的半径：图片超出舞台的那部分，两边各一半。
   * 从 img 的 rect 反推未缩放尺寸（rect 已经含 transform，除以倍率即可）。
   */
  const measureLimits = () => {
    const stage = stageRef.current
    const img = imgRef.current
    if (!stage || !img) return { limitX: 0, limitY: 0 }
    const s = stage.getBoundingClientRect()
    const baseW = img.getBoundingClientRect().width / view.zoom
    const baseH = img.getBoundingClientRect().height / view.zoom
    return {
      limitX: Math.max(0, (baseW * view.zoom - s.width) / 2),
      limitY: Math.max(0, (baseH * view.zoom - s.height) / 2),
    }
  }

  const onPointerDown = (e: React.PointerEvent<HTMLDivElement>) => {
    movedRef.current = false
    if (!zoomed) return
    e.currentTarget.setPointerCapture(e.pointerId)
    const { limitX, limitY } = measureLimits()
    dragRef.current = {
      px: e.clientX,
      py: e.clientY,
      ox: view.x,
      oy: view.y,
      limitX,
      limitY,
    }
    setDragging(true)
  }

  const onPointerMove = (e: React.PointerEvent<HTMLDivElement>) => {
    const d = dragRef.current
    if (!d) return
    const dx = e.clientX - d.px
    const dy = e.clientY - d.py
    if (Math.abs(dx) > 3 || Math.abs(dy) > 3) movedRef.current = true
    setView((v) => ({
      ...v,
      x: Math.min(d.limitX, Math.max(-d.limitX, d.ox + dx)),
      y: Math.min(d.limitY, Math.max(-d.limitY, d.oy + dy)),
    }))
  }

  const endDrag = (e: React.PointerEvent<HTMLDivElement>) => {
    if (!dragRef.current) return
    dragRef.current = null
    setDragging(false)
    if (e.currentTarget.hasPointerCapture(e.pointerId)) {
      e.currentTarget.releasePointerCapture(e.pointerId)
    }
  }

  const onStageClick = () => {
    // 拖动松手也会产生 click，别把它当成「点空白关闭」
    if (movedRef.current) {
      movedRef.current = false
      return
    }
    onClose()
  }

  const onDoubleClick = (e: React.MouseEvent<HTMLDivElement>) => {
    e.stopPropagation()
    movedRef.current = false
    if (zoomed) {
      setView(RESET)
      return
    }
    const stage = stageRef.current
    if (!stage) return
    const rect = stage.getBoundingClientRect()
    zoomAt(DOUBLE_CLICK_ZOOM, {
      x: e.clientX - rect.left - rect.width / 2,
      y: e.clientY - rect.top - rect.height / 2,
    })
  }

  const toolClass =
    'inline-flex size-9 items-center justify-center rounded-lg text-white/80 transition-colors hover:bg-white/10 hover:text-white disabled:pointer-events-none disabled:opacity-25'

  return createPortal(
    <div
      className="fixed inset-0 z-[70] flex animate-fade-in flex-col bg-black/92"
      role="dialog"
      aria-modal="true"
      aria-label="查看图片"
    >
      <div className="flex h-14 shrink-0 items-center justify-between px-4 text-white/80">
        <span className="text-[13px] tabular-nums">
          {total > 1 ? `${index + 1} / ${total}` : ''}
        </span>

        <div className="flex items-center gap-1">
          <span
            className="mr-0.5 w-11 text-right text-[12px] tabular-nums text-white/45"
            aria-live="polite"
          >
            {Math.round(view.zoom * 100)}%
          </span>
          <button
            type="button"
            onClick={() => rotate(-90)}
            className={toolClass}
            title="向左转 90°（Shift + R）"
            aria-label="向左转 90 度"
          >
            <RotateCcw className="size-4" />
          </button>
          <button
            type="button"
            onClick={() => rotate(90)}
            className={toolClass}
            title="向右转 90°（R）"
            aria-label="向右转 90 度"
          >
            <RotateCw className="size-4" />
          </button>
          <span className="mx-0.5 h-5 w-px bg-white/15" aria-hidden="true" />
          <button
            type="button"
            onClick={() => zoomAt(1 / 1.35)}
            disabled={!zoomed}
            className={toolClass}
            title="缩小（-）"
            aria-label="缩小"
          >
            <Minus className="size-4" />
          </button>
          <button
            type="button"
            onClick={() => zoomAt(1.35)}
            disabled={view.zoom >= MAX_ZOOM}
            className={toolClass}
            title="放大（+）"
            aria-label="放大"
          >
            <Plus className="size-4" />
          </button>
          <button
            type="button"
            onClick={resetAll}
            disabled={!dirty}
            className={toolClass}
            title="复位（0）"
            aria-label="复位"
          >
            <Maximize2 className="size-4" />
          </button>
          <button
            type="button"
            onClick={openOriginal}
            className={toolClass}
            title="在新标签打开原图"
            aria-label="在新标签打开原图"
          >
            <ExternalLink className="size-4" />
          </button>
          <button
            type="button"
            onClick={onClose}
            className={toolClass}
            aria-label="关闭"
            title="关闭（Esc）"
          >
            <X className="size-5" />
          </button>
        </div>
      </div>

      <div
        ref={stageRef}
        className={cn(
          'relative flex min-h-0 flex-1 select-none items-center justify-center overflow-hidden px-14 pb-10',
          dragging ? 'cursor-grabbing' : zoomed ? 'cursor-grab' : 'cursor-zoom-in',
        )}
        onClick={onStageClick}
        onDoubleClick={onDoubleClick}
        onPointerDown={onPointerDown}
        onPointerMove={onPointerMove}
        onPointerUp={endDrag}
        onPointerCancel={endDrag}
      >
        <img
          ref={imgRef}
          src={src}
          alt=""
          draggable={false}
          onClick={(e) => e.stopPropagation()}
          style={{
            transform: `translate3d(${view.x}px, ${view.y}px, 0) scale(${view.zoom}) rotate(${rotation}deg)`,
            // 竖图转了 90° 之后，视觉宽高互换：原来的 max-h/max-w 是按未旋转的
            // 长宽算的，会让它在旋转后撑出视口。所以按交换后的舞台尺寸重新给上限
            // （内联样式优先级高于 class 里的 max-h-full / max-w-full）。
            maxWidth: quarterTurn && stageSize.h ? stageSize.h : undefined,
            maxHeight: quarterTurn && stageSize.w ? stageSize.w : undefined,
          }}
          className="max-h-full max-w-full object-contain select-none"
        />

        {total > 1 ? (
          <>
            <button
              type="button"
              onClick={(e) => {
                e.stopPropagation()
                onChange((index - 1 + total) % total)
              }}
              className="absolute left-3 top-1/2 z-10 inline-flex size-10 -translate-y-1/2 items-center justify-center rounded-full bg-white/10 text-white transition-colors hover:bg-white/20"
              aria-label="上一张"
            >
              <ChevronLeft className="size-5" />
            </button>
            <button
              type="button"
              onClick={(e) => {
                e.stopPropagation()
                onChange((index + 1) % total)
              }}
              className="absolute right-3 top-1/2 z-10 inline-flex size-10 -translate-y-1/2 items-center justify-center rounded-full bg-white/10 text-white transition-colors hover:bg-white/20"
              aria-label="下一张"
            >
              <ChevronRight className="size-5" />
            </button>
          </>
        ) : null}
      </div>

      <p className="pb-3 text-center text-[11px] text-white/40">
        滚轮缩放 · 拖动平移 · 双击切换 · R 旋转 90° · ← → 换图 · Esc 关闭
      </p>
    </div>,
    document.body,
  )
}
