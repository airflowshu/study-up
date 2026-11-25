import { useState } from 'react'
import { Check, Pencil, Plus, Trash2, UserRound, Users } from 'lucide-react'
import { createChild, softDeleteChild, updateChild } from '@/lib/api'
import { CHILD_COLORS, childColor, initialOf } from '@/lib/subject'
import { timeAgo } from '@/lib/date'
import { useApp } from '@/store/app'
import { useToast } from '@/components/toast'
import { TopBar } from '@/components/AppShell'
import {
  Button,
  Card,
  EmptyState,
  Field,
  IconButton,
  Input,
  Modal,
} from '@/components/ui'
import { cn } from '@/lib/cn'
import type { Child } from '@/lib/types'

type Dialog =
  | { mode: 'create' }
  | { mode: 'edit'; child: Child }
  | { mode: 'delete'; child: Child }
  | null

export function ChildrenPage({ onAddHomework }: { onAddHomework: () => void }) {
  const { family, children, replaceChild, removeChildLocal, refreshing } = useApp()
  const toast = useToast()

  const [dialog, setDialog] = useState<Dialog>(null)
  const [name, setName] = useState('')
  const [colorIndex, setColorIndex] = useState(0)
  const [busy, setBusy] = useState(false)
  const [nameError, setNameError] = useState('')

  const openCreate = () => {
    setName('')
    // 避开已占用的颜色
    const used = new Set(children.map((c) => c.colorIndex))
    let next = 0
    while (used.has(next) && next < CHILD_COLORS.length) next++
    setColorIndex(next % CHILD_COLORS.length)
    setNameError('')
    setDialog({ mode: 'create' })
  }

  const openEdit = (child: Child) => {
    setName(child.name)
    setColorIndex(child.colorIndex)
    setNameError('')
    setDialog({ mode: 'edit', child })
  }

  const checkName = (value: string, excludeId?: string): string => {
    const v = value.trim()
    if (!v) return '名字不能为空'
    if (v.length > 12) return '名字太长了，12 个字以内'
    const dup = children.some((c) => c.name === v && c.id !== excludeId)
    if (dup) return '这个家里已经有同名孩子了'
    return ''
  }

  const submit = async () => {
    if (!family || !dialog) return
    const err = checkName(
      name,
      dialog.mode === 'edit' ? dialog.child.id : undefined,
    )
    if (err) {
      setNameError(err)
      return
    }

    setBusy(true)
    try {
      if (dialog.mode === 'create') {
        const child = await createChild({
          familyId: family.id,
          name: name.trim(),
          colorIndex,
        })
        replaceChild(child)
        toast.success(`已添加 ${child.name}`)
      } else {
        await updateChild(dialog.child.id, {
          name: name.trim(),
          colorIndex,
        })
        replaceChild({ ...dialog.child, name: name.trim(), colorIndex })
        toast.success('已保存')
      }
      setDialog(null)
    } catch (e) {
      toast.error(e instanceof Error ? e.message : '保存失败')
    } finally {
      setBusy(false)
    }
  }

  const doDelete = async (child: Child) => {
    setBusy(true)
    try {
      await softDeleteChild(child.id)
      removeChildLocal(child.id)
      toast.success(`已移除 ${child.name}`)
      setDialog(null)
    } catch (e) {
      toast.error(e instanceof Error ? e.message : '删除失败')
    } finally {
      setBusy(false)
    }
  }

  if (!family) return null

  return (
    <>
      <TopBar
        title="孩子"
        subtitle={`${family.name} · ${children.length} 个孩子`}
        actions={
          <Button
            variant="primary"
            icon={<Plus className="size-4" />}
            onClick={openCreate}
          >
            添加孩子
          </Button>
        }
      />

      <div className="min-h-0 flex-1 overflow-y-auto">
        <div className="mx-auto max-w-[980px] px-7 py-6">
          {children.length === 0 ? (
            <Card>
              <EmptyState
                icon={<Users className="size-5" />}
                title="还没有孩子"
                description="加上孩子之后，就能给他布置作业了。孩子在自己手机上输入名字登录。"
                action={
                  <Button variant="primary" onClick={openCreate}>
                    添加第一个孩子
                  </Button>
                }
              />
            </Card>
          ) : (
            <div className="grid gap-2 sm:grid-cols-2">
              {children.map((c) => (
                <Card
                  key={c.id}
                  className="group flex items-center gap-3.5 px-4 py-3.5"
                >
                  <div
                    className="flex size-10 shrink-0 items-center justify-center rounded-full text-[15px] font-medium text-white"
                    style={{ backgroundColor: childColor(c.colorIndex) }}
                  >
                    {initialOf(c.name)}
                  </div>
                  <div className="min-w-0 flex-1">
                    <p className="truncate text-[14.5px] font-medium text-fg">
                      {c.name}
                    </p>
                    <p className="mt-0.5 text-[11.5px] text-subtle">
                      添加于 {timeAgo(c.createdAt)}
                    </p>
                  </div>
                  <div className="flex items-center gap-0.5 opacity-0 transition-opacity group-hover:opacity-100 focus-within:opacity-100">
                    <IconButton label="编辑" onClick={() => openEdit(c)}>
                      <Pencil className="size-4" />
                    </IconButton>
                    <IconButton
                      label="移除"
                      onClick={() => setDialog({ mode: 'delete', child: c })}
                      className="hover:bg-danger-soft hover:text-danger-fg"
                    >
                      <Trash2 className="size-4" />
                    </IconButton>
                  </div>
                </Card>
              ))}
            </div>
          )}

          {children.length > 0 ? (
            <button
              type="button"
              onClick={onAddHomework}
              className="mt-4 flex w-full items-center justify-center gap-2 rounded-xl border border-dashed border-line-strong py-3 text-[13px] text-muted transition-colors hover:border-primary/40 hover:bg-primary-soft/40 hover:text-primary-soft-fg"
            >
              <Plus className="size-3.5" />
              给 {children.map((c) => c.name).join(' / ')} 布置作业
            </button>
          ) : null}

          {refreshing ? (
            <p className="mt-3 text-center text-[11px] text-subtle">同步中…</p>
          ) : null}
        </div>
      </div>

      {/* 新增 / 编辑 */}
      <Modal
        open={dialog?.mode === 'create' || dialog?.mode === 'edit'}
        onClose={() => setDialog(null)}
        title={dialog?.mode === 'edit' ? '编辑孩子' : '添加孩子'}
        description="孩子在手机上用自己的名字登录，所以名字要和孩子说清楚。"
        footer={
          <>
            <Button onClick={() => setDialog(null)}>取消</Button>
            <Button variant="primary" loading={busy} onClick={() => void submit()}>
              {dialog?.mode === 'edit' ? '保存' : '添加'}
            </Button>
          </>
        }
      >
        <div className="flex flex-col gap-4">
          <Field label="名字">
            <Input
              value={name}
              onChange={(e) => {
                setName(e.target.value)
                setNameError('')
              }}
              onKeyDown={(e) => {
                if (e.key === 'Enter') void submit()
              }}
              placeholder="孩子的名字"
              autoFocus
              maxLength={12}
              className={cn(nameError && 'border-danger focus:border-danger')}
            />
            {nameError ? (
              <p className="text-[12px] text-danger-fg">{nameError}</p>
            ) : null}
          </Field>

          <Field label="头像颜色">
            <div className="flex gap-2">
              {CHILD_COLORS.map((color, i) => (
                <button
                  key={color}
                  type="button"
                  onClick={() => setColorIndex(i)}
                  aria-label={`颜色 ${i + 1}`}
                  aria-pressed={colorIndex === i}
                  className="flex size-8 items-center justify-center rounded-full transition-transform hover:scale-110"
                  style={{ backgroundColor: color }}
                >
                  {colorIndex === i ? (
                    <Check className="size-4 text-white" strokeWidth={3} />
                  ) : null}
                </button>
              ))}
            </div>
          </Field>

          <div className="flex items-center gap-3 rounded-xl bg-surface-2 p-3">
            <div
              className="flex size-9 items-center justify-center rounded-full text-sm font-medium text-white"
              style={{ backgroundColor: childColor(colorIndex) }}
            >
              {initialOf(name || '?')}
            </div>
            <p className="text-[12px] leading-5 text-muted">
              孩子打开 App 后选「我是孩子」，输入
              <span className="mx-1 font-medium text-fg">{name.trim() || '名字'}</span>
              就能看到自己的作业。
            </p>
          </div>
        </div>
      </Modal>

      {/* 删除确认 */}
      <Modal
        open={dialog?.mode === 'delete'}
        onClose={() => setDialog(null)}
        title={
          dialog?.mode === 'delete' ? `移除 ${dialog.child.name}？` : '移除孩子'
        }
        description="孩子将无法再用这个名字登录。已经布置过的作业会保留在云端，不会丢。"
        footer={
          <>
            <Button onClick={() => setDialog(null)}>取消</Button>
            <Button
              variant="danger"
              loading={busy}
              onClick={() => {
                if (dialog?.mode === 'delete') void doDelete(dialog.child)
              }}
            >
              移除
            </Button>
          </>
        }
      >
        <div className="flex items-center gap-2.5 rounded-xl border border-line bg-surface-2 p-3 text-[12.5px] text-muted">
          <UserRound className="size-4 shrink-0 text-subtle" />
          如果只是改名，用「编辑」而不是移除。
        </div>
      </Modal>
    </>
  )
}
