import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useMemo,
  useState,
  type ReactNode,
} from 'react'
import { fetchChildren, fetchMyFamily, loginFamily } from '@/lib/api'
import { cloud } from '@/lib/cloud'
import type { Child, Family } from '@/lib/types'

type ThemeMode = 'light' | 'dark' | 'system'

const KEY_FAMILY = 'hw_web_family'
const KEY_THEME = 'hw_web_theme'

interface AppValue {
  family: Family | null
  children: Child[]
  /** 会话恢复中，界面先别闪登录页 */
  booting: boolean
  signingIn: boolean
  /** 孩子列表刷新中 */
  refreshing: boolean
  theme: ThemeMode
  setTheme: (t: ThemeMode) => void
  isDark: boolean
  login: (code: string) => Promise<void>
  logout: () => void
  reloadChildren: () => Promise<void>
  replaceChild: (child: Child) => void
  removeChildLocal: (id: string) => void
}

const AppContext = createContext<AppValue | null>(null)

function readTheme(): ThemeMode {
  const v = localStorage.getItem(KEY_THEME)
  return v === 'light' || v === 'dark' ? v : 'system'
}

export function AppProvider({ children }: { children: ReactNode }) {
  const [family, setFamily] = useState<Family | null>(null)
  const [kids, setKids] = useState<Child[]>([])
  const [booting, setBooting] = useState(true)
  const [signingIn, setSigningIn] = useState(false)
  const [refreshing, setRefreshing] = useState(false)
  const [theme, setThemeState] = useState<ThemeMode>(readTheme)
  const [systemDark, setSystemDark] = useState(
    () => window.matchMedia('(prefers-color-scheme: dark)').matches,
  )

  // 跟随系统时实时响应系统切换
  useEffect(() => {
    const mq = window.matchMedia('(prefers-color-scheme: dark)')
    const onChange = (e: MediaQueryListEvent) => setSystemDark(e.matches)
    mq.addEventListener('change', onChange)
    return () => mq.removeEventListener('change', onChange)
  }, [])

  const isDark = theme === 'dark' || (theme === 'system' && systemDark)

  useEffect(() => {
    const root = document.documentElement
    root.classList.toggle('dark', isDark)
    root.style.colorScheme = isDark ? 'dark' : 'light'
  }, [isDark])

  const setTheme = useCallback((t: ThemeMode) => {
    setThemeState(t)
    localStorage.setItem(KEY_THEME, t)
  }, [])

  const logout = useCallback(() => {
    localStorage.removeItem(KEY_FAMILY)
    setFamily(null)
    setKids([])
    // 通知服务端吊销会话。失败也不拦着本地退出。
    void cloud.signOut()
  }, [])

  // token 彻底失效（refresh 也救不回来）时，由 cloud 层回调到这里回登录页
  useEffect(() => {
    cloud.onAuthLost = () => {
      localStorage.removeItem(KEY_FAMILY)
      setFamily(null)
      setKids([])
    }
    return () => {
      cloud.onAuthLost = null
    }
  }, [])

  // 启动时恢复会话：token 决定"我是哪个家庭"，不再依赖 localStorage 里的 id。
  // 家庭名和家庭码都重新拉，免得家长在别处改了名字，这台电脑还显示旧的。
  useEffect(() => {
    let alive = true
    ;(async () => {
      if (!cloud.hasSession()) {
        setBooting(false)
        return
      }
      try {
        const f = await fetchMyFamily()
        if (!alive) return
        if (!f) {
          localStorage.removeItem(KEY_FAMILY)
          setBooting(false)
          return
        }
        setFamily(f)
        localStorage.setItem(KEY_FAMILY, f.id)
        setKids(await fetchChildren(f.id))
      } catch {
        // 网络问题不清会话，下次打开再试；401 已由 onAuthLost 处理
      } finally {
        if (alive) setBooting(false)
      }
    })()
    return () => {
      alive = false
    }
  }, [])

  const login = useCallback(async (code: string) => {
    setSigningIn(true)
    try {
      const f = await loginFamily(code)
      const list = await fetchChildren(f.id)
      localStorage.setItem(KEY_FAMILY, f.id)
      setFamily(f)
      setKids(list)
    } finally {
      setSigningIn(false)
    }
  }, [])

  const reloadChildren = useCallback(async () => {
    if (!family) return
    setRefreshing(true)
    try {
      setKids(await fetchChildren(family.id))
    } finally {
      setRefreshing(false)
    }
  }, [family])

  const replaceChild = useCallback((child: Child) => {
    setKids((prev) => {
      const i = prev.findIndex((c) => c.id === child.id)
      if (i < 0) return [...prev, child]
      const next = [...prev]
      next[i] = child
      return next
    })
  }, [])

  const removeChildLocal = useCallback((id: string) => {
    setKids((prev) => prev.filter((c) => c.id !== id))
  }, [])

  const value = useMemo<AppValue>(
    () => ({
      family,
      children: kids,
      booting,
      signingIn,
      refreshing,
      theme,
      setTheme,
      isDark,
      login,
      logout,
      reloadChildren,
      replaceChild,
      removeChildLocal,
    }),
    [
      family,
      kids,
      booting,
      signingIn,
      refreshing,
      theme,
      setTheme,
      isDark,
      login,
      logout,
      reloadChildren,
      replaceChild,
      removeChildLocal,
    ],
  )

  return <AppContext.Provider value={value}>{children}</AppContext.Provider>
}

export function useApp(): AppValue {
  const ctx = useContext(AppContext)
  if (!ctx) throw new Error('useApp 必须在 AppProvider 内使用')
  return ctx
}
