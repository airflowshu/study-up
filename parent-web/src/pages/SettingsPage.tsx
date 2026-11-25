import { useState } from 'react'
import { Check, Cloud, Copy, ExternalLink, Sparkles } from 'lucide-react'
import { useApp } from '@/store/app'
import { useToast } from '@/components/toast'
import { TopBar } from '@/components/AppShell'
import { Button, Card } from '@/components/ui'

export function SettingsPage() {
  const { family, children, theme, setTheme, logout } = useApp()
  const toast = useToast()
  const [copied, setCopied] = useState(false)

  if (!family) return null

  const copy = async () => {
    try {
      await navigator.clipboard.writeText(family.code)
      setCopied(true)
      toast.success('家庭码已复制')
      window.setTimeout(() => setCopied(false), 1800)
    } catch {
      toast.error('复制失败，请手动选中')
    }
  }

  return (
    <>
      <TopBar title="设置" subtitle="家庭信息与偏好" />

      <div className="min-h-0 flex-1 overflow-y-auto">
        <div className="mx-auto flex max-w-[760px] flex-col gap-4 px-7 py-6">
          {/* 家庭码 */}
          <Card className="p-5">
            <div className="flex items-start justify-between gap-4">
              <div>
                <p className="text-[13px] font-medium text-fg">家庭码</p>
                <p className="mt-1 text-[12px] leading-5 text-muted">
                  家人用这个码在其他设备上登录同一份数据。
                  <br />
                  它就是这个家的钥匙，别随便发到群里。
                </p>
              </div>
              <Button
                size="sm"
                icon={
                  copied ? (
                    <Check className="size-3.5 text-success-fg" />
                  ) : (
                    <Copy className="size-3.5" />
                  )
                }
                onClick={() => void copy()}
              >
                {copied ? '已复制' : '复制'}
              </Button>
            </div>

            <div className="mt-4 rounded-xl border border-line bg-surface-2 px-4 py-4 text-center">
              <p className="font-mono text-[28px] font-semibold tracking-[0.32em] text-fg">
                {family.code}
              </p>
            </div>

            <div className="mt-3 flex items-center justify-between text-[12px] text-subtle">
              <span>{family.name}</span>
              <span>{children.length} 个孩子</span>
            </div>
          </Card>

          {/* 外观 */}
          <Card className="p-5">
            <p className="text-[13px] font-medium text-fg">外观</p>
            <div className="mt-3 grid grid-cols-3 gap-2">
              {(
                [
                  { key: 'light', label: '浅色' },
                  { key: 'dark', label: '深色' },
                  { key: 'system', label: '跟随系统' },
                ] as const
              ).map(({ key, label }) => (
                <button
                  key={key}
                  type="button"
                  onClick={() => setTheme(key)}
                  className={
                    theme === key
                      ? 'h-9 rounded-lg border border-primary/40 bg-primary-soft text-[13px] font-medium text-primary-soft-fg'
                      : 'h-9 rounded-lg border border-line bg-surface text-[13px] text-muted transition-colors hover:border-line-strong hover:text-fg'
                  }
                >
                  {label}
                </button>
              ))}
            </div>
          </Card>

          {/* 数据 */}
          <Card className="p-5">
            <p className="text-[13px] font-medium text-fg">数据</p>
            <div className="mt-3 flex flex-col gap-2.5 text-[12.5px] leading-5 text-muted">
              <p className="flex items-start gap-2">
                <Cloud className="mt-0.5 size-3.5 shrink-0 text-subtle" />
                作业和孩子都存在家里的 NAS 上，和手机 App 是同一份数据。电脑上改完，孩子手机刷新就能看到。
              </p>
              <p className="flex items-start gap-2">
                <Sparkles className="mt-0.5 size-3.5 shrink-0 text-subtle" />
                网页端不做本地缓存，所以在离线状态下无法布置作业；手机上布置过的离线内容会在联网后自动补传。
              </p>
            </div>
          </Card>

          {/* 会话 */}
          <Card className="p-5">
            <p className="text-[13px] font-medium text-fg">登录</p>
            <p className="mt-1 text-[12px] leading-5 text-muted">
              当前以家庭码 {family.code} 登录这台电脑。
            </p>
            <Button
              size="sm"
              variant="danger"
              className="mt-3"
              onClick={logout}
              icon={<ExternalLink className="size-3.5" />}
            >
              退出登录
            </Button>
          </Card>

          <p className="pb-6 text-center text-[11px] text-subtle">
            家庭作业 · 家长电脑版
          </p>
        </div>
      </div>
    </>
  )
}
