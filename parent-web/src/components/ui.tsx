import {
  useEffect,
  useRef,
  type ButtonHTMLAttributes,
  type HTMLAttributes,
  type InputHTMLAttributes,
  type ReactNode,
  type Ref,
  type TextareaHTMLAttributes,
} from 'react'
import { X } from 'lucide-react'
import { cn } from '@/lib/cn'
import { subjectColor } from '@/lib/subject'
import { enterModal, exitModal, isTopModal } from '@/lib/modal'

// ---------------- 按钮 ----------------

type Variant = 'primary' | 'secondary' | 'ghost' | 'danger' | 'soft'
type Size = 'sm' | 'md' | 'lg'

const VARIANTS: Record<Variant, string> = {
  primary:
    'bg-primary text-primary-fg hover:bg-primary-hover shadow-sm disabled:bg-primary/50',
  secondary:
    'bg-surface text-fg border border-line hover:bg-surface-2 hover:border-line-strong',
  ghost: 'text-muted hover:bg-surface-3 hover:text-fg',
  danger: 'text-danger-fg bg-danger-soft hover:bg-danger/20',
  soft: 'bg-primary-soft text-primary-soft-fg hover:bg-primary/20',
}

const SIZES: Record<Size, string> = {
  sm: 'h-8 px-2.5 text-[13px] gap-1.5 rounded-lg',
  md: 'h-9 px-3.5 text-sm gap-2 rounded-[10px]',
  lg: 'h-11 px-5 text-[15px] gap-2 rounded-xl',
}

export function Button({
  variant = 'secondary',
  size = 'md',
  loading = false,
  icon,
  className,
  children,
  disabled,
  ...rest
}: ButtonHTMLAttributes<HTMLButtonElement> & {
  variant?: Variant
  size?: Size
  loading?: boolean
  icon?: ReactNode
}) {
  return (
    <button
      type="button"
      disabled={disabled || loading}
      className={cn(
        'inline-flex select-none items-center justify-center font-medium transition-colors',
        'disabled:cursor-not-allowed disabled:opacity-60',
        VARIANTS[variant],
        SIZES[size],
        className,
      )}
      {...rest}
    >
      {loading ? <Spinner className="size-4" /> : icon}
      {children}
    </button>
  )
}

export function IconButton({
  label,
  className,
  children,
  ...rest
}: ButtonHTMLAttributes<HTMLButtonElement> & { label: string }) {
  return (
    <button
      type="button"
      aria-label={label}
      title={label}
      className={cn(
        'inline-flex size-8 items-center justify-center rounded-lg text-muted',
        'transition-colors hover:bg-surface-3 hover:text-fg',
        'disabled:cursor-not-allowed disabled:opacity-50',
        className,
      )}
      {...rest}
    >
      {children}
    </button>
  )
}

// ---------------- 表单 ----------------

export function Input({
  className,
  ...rest
}: InputHTMLAttributes<HTMLInputElement>) {
  return (
    <input
      className={cn(
        'h-10 w-full rounded-[10px] border border-line bg-surface px-3 text-sm text-fg',
        'placeholder:text-subtle transition-colors',
        'hover:border-line-strong focus:border-primary focus:outline-none',
        'focus:ring-3 focus:ring-[var(--c-ring)]',
        className,
      )}
      {...rest}
    />
  )
}

export function Textarea({
  className,
  ...rest
}: TextareaHTMLAttributes<HTMLTextAreaElement> & {
  ref?: Ref<HTMLTextAreaElement>
}) {
  return (
    <textarea
      className={cn(
        'w-full resize-none rounded-[10px] border border-line bg-surface px-3.5 py-3',
        'text-[15px] leading-7 text-fg placeholder:text-subtle transition-colors',
        'hover:border-line-strong focus:border-primary focus:outline-none',
        'focus:ring-3 focus:ring-[var(--c-ring)]',
        className,
      )}
      {...rest}
    />
  )
}

export function Field({
  label,
  hint,
  children,
  className,
}: {
  label: string
  hint?: ReactNode
  children: ReactNode
  className?: string
}) {
  return (
    <div className={cn('flex flex-col gap-1.5', className)}>
      <div className="flex items-baseline justify-between gap-3">
        <label className="text-[13px] font-medium text-fg">{label}</label>
        {hint ? <span className="text-xs text-subtle">{hint}</span> : null}
      </div>
      {children}
    </div>
  )
}

// ---------------- 展示 ----------------

export function Card({
  className,
  children,
  ...rest
}: HTMLAttributes<HTMLDivElement>) {
  return (
    <div
      className={cn(
        'rounded-[14px] border border-line bg-surface card-shadow',
        className,
      )}
      {...rest}
    >
      {children}
    </div>
  )
}

export function SubjectTag({
  subject,
  size = 'md',
}: {
  subject: string
  size?: 'sm' | 'md'
}) {
  const color = subjectColor(subject)
  return (
    <span
      className={cn(
        'inline-flex shrink-0 items-center gap-1.5 rounded-md font-medium',
        size === 'sm' ? 'px-1.5 py-0.5 text-[11px]' : 'px-2 py-0.5 text-xs',
      )}
      style={{ color, backgroundColor: `${color}1f` }}
    >
      <span
        className="size-1.5 rounded-full"
        style={{ backgroundColor: color }}
      />
      {subject || '未选'}
    </span>
  )
}

export function Spinner({ className }: { className?: string }) {
  return (
    <svg
      className={cn('size-4 animate-spin', className)}
      viewBox="0 0 24 24"
      fill="none"
      aria-hidden
    >
      <circle
        cx="12"
        cy="12"
        r="9"
        stroke="currentColor"
        strokeWidth="2.5"
        opacity="0.2"
      />
      <path
        d="M21 12a9 9 0 0 0-9-9"
        stroke="currentColor"
        strokeWidth="2.5"
        strokeLinecap="round"
      />
    </svg>
  )
}

export function EmptyState({
  icon,
  title,
  description,
  action,
}: {
  icon: ReactNode
  title: string
  description?: string
  action?: ReactNode
}) {
  return (
    <div className="flex flex-col items-center justify-center px-6 py-16 text-center">
      <div className="mb-4 flex size-12 items-center justify-center rounded-2xl bg-surface-3 text-subtle">
        {icon}
      </div>
      <p className="text-[15px] font-medium text-fg">{title}</p>
      {description ? (
        <p className="mt-1.5 max-w-sm text-sm leading-6 text-muted">
          {description}
        </p>
      ) : null}
      {action ? <div className="mt-5">{action}</div> : null}
    </div>
  )
}

// ---------------- 弹层 ----------------

export function Modal({
  open,
  onClose,
  title,
  description,
  children,
  footer,
  width = 440,
}: {
  open: boolean
  onClose: () => void
  title: string
  description?: string
  children?: ReactNode
  footer?: ReactNode
  width?: number
}) {
  const token = useRef(Symbol('modal')).current

  useEffect(() => {
    if (!open) return
    enterModal(token)
    const onKey = (e: KeyboardEvent) => {
      if (e.key === 'Escape' && isTopModal(token)) onClose()
    }
    document.addEventListener('keydown', onKey)
    return () => {
      document.removeEventListener('keydown', onKey)
      exitModal(token)
    }
  }, [open, onClose, token])

  if (!open) return null

  return (
    <div
      className="fixed inset-0 z-50 flex items-center justify-center p-4"
      role="dialog"
      aria-modal="true"
      aria-label={title}
    >
      <div
        className="absolute inset-0 animate-fade-in bg-black/45 backdrop-blur-[2px]"
        onClick={onClose}
      />
      <div
        className="relative z-10 animate-pop-in rounded-2xl border border-line bg-surface p-5 card-shadow"
        style={{ width, maxWidth: '100%' }}
      >
        <div className="mb-4 flex items-start justify-between gap-4">
          <div>
            <h2 className="text-[15px] font-semibold text-fg">{title}</h2>
            {description ? (
              <p className="mt-1 text-[13px] leading-5 text-muted">
                {description}
              </p>
            ) : null}
          </div>
          <IconButton label="关闭" onClick={onClose} className="-mt-1 -mr-1">
            <X className="size-4" />
          </IconButton>
        </div>
        {children}
        {footer ? (
          <div className="mt-5 flex justify-end gap-2">{footer}</div>
        ) : null}
      </div>
    </div>
  )
}
