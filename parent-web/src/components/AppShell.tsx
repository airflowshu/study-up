import { useState, type ReactNode } from 'react'
import {
  BookOpen,
  LogOut,
  Monitor,
  Moon,
  Settings as SettingsIcon,
  Sun,
  Users,
} from 'lucide-react'
import { cn } from '@/lib/cn'
import { useApp } from '@/store/app'
import { useToast } from './toast'
import { IconButton } from './ui'

export type ViewName = 'homework' | 'children' | 'settings'

const NAV = [
  { key: 'homework' as const, label: '作业', icon: BookOpen },
  { key: 'children' as const, label: '孩子', icon: Users },
  { key: 'settings' as const, label: '设置', icon: SettingsIcon },
]

export function AppShell({
  current,
  onNavigate,
  children,
}: {
  current: ViewName
  onNavigate: (v: ViewName) => void
  children: ReactNode
}) {
  const { family, theme, setTheme, logout } = useApp()
  const toast = useToast()
  const [copied, setCopied] = useState(false)

  const copyCode = async () => {
    if (!family) return
    try {
      await navigator.clipboard.writeText(family.code)
      setCopied(true)
      toast.success('家庭码已复制，发给家人就能登进来')
      window.setTimeout(() => setCopied(false), 1800)
    } catch {
      toast.error('复制失败，请手动选中复制')
    }
  }

  return (
    <div className="flex h-full">
      <aside className="flex w-[236px] shrink-0 flex-col border-r border-line bg-surface">
        <div className="flex items-center gap-2.5 px-5 pb-5 pt-6">
          <div className="flex size-9 items-center justify-center rounded-[11px] bg-primary text-primary-fg shadow-sm">
            <svg viewBox="0 0 24 24" className="size-5" fill="none">
              <path
                d="M6.5 12.5l3.4 3.4L17.5 8.5"
                stroke="currentColor"
                strokeWidth="2.2"
                strokeLinecap="round"
                strokeLinejoin="round"
              />
            </svg>
          </div>
          <div className="leading-tight">
            <p className="text-[15px] font-semibold tracking-tight text-fg">
              家庭作业
            </p>
            <p className="text-[11px] text-subtle">家长端 · 电脑版</p>
          </div>
        </div>

        <nav className="flex flex-col gap-0.5 px-3">
          {NAV.map((item) => {
            const Icon = item.icon
            const active = current === item.key
            return (
              <button
                key={item.key}
                type="button"
                onClick={() => onNavigate(item.key)}
                className={cn(
                  'flex h-9 items-center gap-2.5 rounded-[10px] px-2.5 text-sm transition-colors',
                  active
                    ? 'bg-primary-soft font-medium text-primary-soft-fg'
                    : 'text-muted hover:bg-surface-2 hover:text-fg',
                )}
              >
                <Icon
                  className={cn('size-4', active ? '' : 'text-subtle')}
                  strokeWidth={active ? 2.2 : 1.9}
                />
                {item.label}
              </button>
            )
          })}
        </nav>

        <div className="mt-auto px-3 pb-4">
          {family ? (
            <button
              type="button"
              onClick={copyCode}
              title="点击复制家庭码"
              className="mb-3 w-full rounded-xl border border-line bg-surface-2 px-3 py-2.5 text-left transition-colors hover:border-line-strong"
            >
              <p className="truncate text-[13px] font-medium text-fg">
                {family.name}
              </p>
              <p className="mt-0.5 flex items-center gap-1.5 text-[11px] text-subtle">
                家庭码
                <span className="font-mono tracking-[0.14em] text-muted">
                  {family.code}
                </span>
                {copied ? (
                  <span className="text-success-fg">已复制</span>
                ) : null}
              </p>
            </button>
          ) : null}

          <div className="mb-2 flex items-center justify-between rounded-xl bg-surface-2 px-1 py-1">
            {(
              [
                { key: 'light', icon: Sun, label: '浅色' },
                { key: 'dark', icon: Moon, label: '深色' },
                { key: 'system', icon: Monitor, label: '跟随系统' },
              ] as const
            ).map(({ key, icon: Icon, label }) => {
              const active = theme === key
              return (
                <button
                  key={key}
                  type="button"
                  onClick={() => setTheme(key)}
                  title={label}
                  aria-label={label}
                  aria-pressed={active}
                  className={cn(
                    'flex h-7 flex-1 items-center justify-center rounded-lg transition-colors',
                    active
                      ? 'bg-surface text-fg shadow-sm'
                      : 'text-muted hover:text-fg',
                  )}
                >
                  <Icon className="size-3.5" />
                </button>
              )
            })}
          </div>

          <button
            type="button"
            onClick={logout}
            className="flex h-8 w-full items-center gap-2 rounded-lg px-2.5 text-[13px] text-subtle transition-colors hover:bg-danger-soft hover:text-danger-fg"
          >
            <LogOut className="size-3.5" />
            退出登录
          </button>
        </div>
      </aside>

      <main className="flex min-w-0 flex-1 flex-col overflow-hidden">
        {children}
      </main>
    </div>
  )
}

export function TopBar({
  title,
  subtitle,
  actions,
}: {
  title: ReactNode
  subtitle?: ReactNode
  actions?: ReactNode
}) {
  return (
    <header className="flex shrink-0 items-center justify-between gap-4 border-b border-line bg-surface/70 px-7 py-3.5 backdrop-blur-sm">
      <div className="min-w-0">
        <h1 className="truncate text-[17px] font-semibold tracking-tight text-fg">
          {title}
        </h1>
        {subtitle ? (
          <p className="mt-0.5 truncate text-[12px] text-muted">{subtitle}</p>
        ) : null}
      </div>
      {actions ? (
        <div className="flex shrink-0 items-center gap-2">{actions}</div>
      ) : null}
    </header>
  )
}

export { IconButton }
