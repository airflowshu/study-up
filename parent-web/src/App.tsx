import { useState } from 'react'
import { AppProvider, useApp } from '@/store/app'
import { ToastProvider } from '@/components/toast'
import { AppShell, type ViewName } from '@/components/AppShell'
import { LoginPage } from '@/pages/LoginPage'
import { HomeworkListPage } from '@/pages/HomeworkListPage'
import { HomeworkEditPage } from '@/pages/HomeworkEditPage'
import { ChildrenPage } from '@/pages/ChildrenPage'
import { SettingsPage } from '@/pages/SettingsPage'
import { Spinner } from '@/components/ui'

type Route =
  | { name: 'homework' }
  | { name: 'children' }
  | { name: 'settings' }
  | { name: 'edit'; id?: string; date?: string }

const VIEW_ROUTES: Record<ViewName, Route> = {
  homework: { name: 'homework' },
  children: { name: 'children' },
  settings: { name: 'settings' },
}

function Router() {
  const { family, booting } = useApp()
  const [route, setRoute] = useState<Route>({ name: 'homework' })

  if (booting) {
    return (
      <div className="flex h-full items-center justify-center bg-bg">
        <div className="flex flex-col items-center gap-3">
          <Spinner className="size-5 text-primary" />
          <p className="text-[13px] text-muted">正在打开…</p>
        </div>
      </div>
    )
  }

  if (!family) return <LoginPage />

  if (route.name === 'edit') {
    return (
      <HomeworkEditPage
        id={route.id}
        presetDate={route.date}
        onDone={() => setRoute({ name: 'homework' })}
        onCancel={() => setRoute({ name: 'homework' })}
      />
    )
  }

  const navigate = (v: ViewName) => setRoute(VIEW_ROUTES[v])

  return (
    <AppShell current={route.name} onNavigate={navigate}>
      {route.name === 'homework' ? (
        <HomeworkListPage
          onEdit={(id, date) => setRoute({ name: 'edit', id, date })}
          onOpenChild={() => setRoute({ name: 'children' })}
        />
      ) : null}
      {route.name === 'children' ? (
        <ChildrenPage
          onAddHomework={() => setRoute({ name: 'edit', date: undefined })}
        />
      ) : null}
      {route.name === 'settings' ? <SettingsPage /> : null}
    </AppShell>
  )
}

export function App() {
  return (
    <ToastProvider>
      <AppProvider>
        <Router />
      </AppProvider>
    </ToastProvider>
  )
}
