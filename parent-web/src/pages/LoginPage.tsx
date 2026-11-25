import { useState, type FormEvent } from 'react'
import { ArrowRight, CheckCircle2, Keyboard, MonitorSmartphone, Images } from 'lucide-react'
import { useApp } from '@/store/app'
import { Button, Input } from '@/components/ui'
import { cn } from '@/lib/cn'

export function LoginPage() {
  const { login, signingIn } = useApp()
  const [code, setCode] = useState('')
  const [error, setError] = useState('')

  const submit = async (e: FormEvent) => {
    e.preventDefault()
    if (code.length < 6) {
      setError('家庭码是 6 位，还差一点')
      return
    }
    setError('')
    try {
      await login(code)
    } catch (err) {
      setError(err instanceof Error ? err.message : '登录失败，请稍后重试')
    }
  }

  return (
    <div className="flex min-h-full bg-bg">
      {/* 左侧介绍：只在宽屏出现，窄屏纯表单 */}
      <div className="relative hidden flex-1 overflow-hidden bg-[#0b1220] lg:flex">
        <div
          className="absolute inset-0 opacity-70"
          style={{
            background:
              'radial-gradient(circle at 20% 20%, #1e40af 0%, transparent 45%), radial-gradient(circle at 80% 70%, #0f766e 0%, transparent 50%)',
          }}
        />
        <div
          className="absolute inset-0 opacity-[0.07]"
          style={{
            backgroundImage:
              'linear-gradient(to right, #fff 1px, transparent 1px), linear-gradient(to bottom, #fff 1px, transparent 1px)',
            backgroundSize: '44px 44px',
          }}
        />
        <div className="relative z-10 flex flex-col justify-between p-12 xl:p-16">
          <div className="flex items-center gap-2.5 text-white">
            <div className="flex size-9 items-center justify-center rounded-[11px] bg-white/12 backdrop-blur">
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
            <span className="text-[15px] font-semibold">家庭作业</span>
          </div>

          <div className="max-w-md">
            <h1 className="text-[34px] font-semibold leading-[1.25] tracking-tight text-white">
              在电脑上布置作业，
              <br />
              比在手机上快得多。
            </h1>
            <p className="mt-4 text-[15px] leading-7 text-white/60">
              键盘打字、微信里的图文直接粘贴、一次布置一整周。
              布置完孩子手机上的作业就同步好了。
            </p>

            <div className="mt-9 flex flex-col gap-4">
              {[
                {
                  icon: Keyboard,
                  title: '大面积输入',
                  desc: '一屏写完几科作业，不用在小键盘上挤',
                },
                {
                  icon: Images,
                  title: '图片直接粘贴',
                  desc: '微信、QQ、网页里的图，Ctrl+V 就进来',
                },
                {
                  icon: MonitorSmartphone,
                  title: '和手机 App 同一份数据',
                  desc: '电脑上布置，孩子手机上立刻看到',
                },
              ].map(({ icon: Icon, title, desc }) => (
                <div key={title} className="flex items-start gap-3">
                  <div className="mt-0.5 flex size-8 shrink-0 items-center justify-center rounded-lg bg-white/10 text-white/80">
                    <Icon className="size-4" />
                  </div>
                  <div>
                    <p className="text-[13.5px] font-medium text-white/90">
                      {title}
                    </p>
                    <p className="mt-0.5 text-[12.5px] leading-5 text-white/45">
                      {desc}
                    </p>
                  </div>
                </div>
              ))}
            </div>
          </div>

          <p className="text-[11.5px] text-white/30">
            与「家庭作业」Android App 共享同一个云端家庭
          </p>
        </div>
      </div>

      {/* 右侧登录表单 */}
      <div className="flex w-full flex-col justify-center px-6 lg:w-[480px] lg:shrink-0">
        <div className="mx-auto w-full max-w-[352px]">
          <div className="mb-8 flex items-center gap-2.5 lg:hidden">
            <div className="flex size-9 items-center justify-center rounded-[11px] bg-primary text-primary-fg">
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
            <span className="text-[15px] font-semibold text-fg">家庭作业</span>
          </div>

          <h2 className="text-[22px] font-semibold tracking-tight text-fg">
            家长登录
          </h2>
          <p className="mt-1.5 text-[13.5px] leading-6 text-muted">
            输入 6 位家庭码。在手机 App 的「设置」里能看到。
          </p>

          <form onSubmit={submit} className="mt-7">
            <Input
              value={code}
              onChange={(e) => {
                setCode(
                  e.target.value
                    .toUpperCase()
                    .replace(/[^A-Z0-9]/g, '')
                    .slice(0, 6),
                )
                setError('')
              }}
              placeholder="例如 A1B2C3"
              autoFocus
              autoComplete="off"
              spellCheck={false}
              aria-label="家庭码"
              aria-invalid={Boolean(error)}
              className={cn(
                'h-12 rounded-xl text-center font-mono text-[19px] tracking-[0.4em] uppercase',
                'placeholder:tracking-normal placeholder:text-[14px] placeholder:font-sans',
                error && 'border-danger focus:border-danger focus:ring-danger/20',
              )}
            />

            <div className="mt-2 min-h-5">
              {error ? (
                <p className="text-[12.5px] text-danger-fg">{error}</p>
              ) : null}
            </div>

            <Button
              type="submit"
              variant="primary"
              size="lg"
              loading={signingIn}
              className="mt-3 w-full"
              icon={signingIn ? undefined : <ArrowRight className="size-4" />}
            >
              {signingIn ? '正在进入…' : '进入'}
            </Button>
          </form>

          <div className="mt-8 rounded-xl border border-line bg-surface-2 p-3.5">
            <p className="mb-2 text-[12px] font-medium text-fg">还没开通？</p>
            <ul className="flex flex-col gap-1.5 text-[12px] leading-5 text-muted">
              <li className="flex gap-1.5">
                <CheckCircle2 className="mt-0.5 size-3.5 shrink-0 text-success-fg" />
                手机 App 里「我是家长 → 创建家庭」，会生成家庭码
              </li>
              <li className="flex gap-1.5">
                <CheckCircle2 className="mt-0.5 size-3.5 shrink-0 text-success-fg" />
                已经有家庭的话，直接用那个码登进来
              </li>
            </ul>
          </div>
        </div>
      </div>
    </div>
  )
}
