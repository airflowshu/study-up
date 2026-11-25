import {
  createContext,
  useCallback,
  useContext,
  useMemo,
  useRef,
  useState,
  type ReactNode,
} from 'react'
import { AlertCircle, CheckCircle2, Info, X } from 'lucide-react'
import { cn } from '@/lib/cn'

type Kind = 'success' | 'error' | 'info'

interface ToastItem {
  id: number
  kind: Kind
  text: string
}

interface ToastApi {
  success: (text: string) => void
  error: (text: string) => void
  info: (text: string) => void
}

const ToastContext = createContext<ToastApi | null>(null)

const ICONS: Record<Kind, ReactNode> = {
  success: <CheckCircle2 className="size-4 text-success-fg" />,
  error: <AlertCircle className="size-4 text-danger-fg" />,
  info: <Info className="size-4 text-primary" />,
}

export function ToastProvider({ children }: { children: ReactNode }) {
  const [items, setItems] = useState<ToastItem[]>([])
  const seq = useRef(0)

  const push = useCallback((kind: Kind, text: string) => {
    const id = ++seq.current
    setItems((prev) => [...prev.slice(-2), { id, kind, text }])
    window.setTimeout(() => {
      setItems((prev) => prev.filter((t) => t.id !== id))
    }, kind === 'error' ? 5200 : 3200)
  }, [])

  const api = useMemo<ToastApi>(
    () => ({
      success: (t) => push('success', t),
      error: (t) => push('error', t),
      info: (t) => push('info', t),
    }),
    [push],
  )

  return (
    <ToastContext.Provider value={api}>
      {children}
      <div className="pointer-events-none fixed inset-x-0 bottom-6 z-[60] flex flex-col items-center gap-2 px-4">
        {items.map((t) => (
          <div
            key={t.id}
            className={cn(
              // 用 30rem 而不是 max-w-md：粘贴失败这类提示句子长，
              // 448px 会把「网页」这种两字词硬拆到两行，读起来磕巴
              'pointer-events-auto flex max-w-[30rem] animate-fade-up items-start gap-2.5',
              'rounded-xl border border-line bg-surface px-3.5 py-2.5 card-shadow',
            )}
            role="status"
          >
            <span className="mt-0.5 shrink-0">{ICONS[t.kind]}</span>
            <p className="text-[13px] leading-5 text-fg">{t.text}</p>
            <button
              type="button"
              aria-label="关闭提示"
              className="ml-1 mt-0.5 shrink-0 text-subtle transition-colors hover:text-fg"
              onClick={() =>
                setItems((prev) => prev.filter((x) => x.id !== t.id))
              }
            >
              <X className="size-3.5" />
            </button>
          </div>
        ))}
      </div>
    </ToastContext.Provider>
  )
}

export function useToast(): ToastApi {
  const ctx = useContext(ToastContext)
  if (!ctx) throw new Error('useToast 必须在 ToastProvider 内使用')
  return ctx
}
