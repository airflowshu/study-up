import { useCallback, useEffect, useMemo, useState, type ReactNode } from 'react'
import {
  Check,
  ChevronLeft,
  ChevronRight,
  Circle,
  Pencil,
  Plus,
  RefreshCw,
  Search,
  Trash2,
  CalendarDays,
  Inbox,
} from 'lucide-react'
import { addDays, fullDate, friendlyDate, todayStr, weekday } from '@/lib/date'
import { fetchHomework, softDeleteHomework } from '@/lib/api'
import { plainText } from '@/lib/richBody'
import { childColor, subjectColor } from '@/lib/subject'
import { useApp } from '@/store/app'
import { useToast } from '@/components/toast'
import { TopBar } from '@/components/AppShell'
import { Button, Card, EmptyState, IconButton, Input, Modal, SubjectTag } from '@/components/ui'
import { Thumb, Lightbox } from '@/components/image'
import { HomeworkDetailDrawer } from '@/components/HomeworkDetailDrawer'
import { AttachmentList } from '@/components/AttachmentCard'
import { cn } from '@/lib/cn'
import type { Homework } from '@/lib/types'

export function HomeworkListPage({
  onEdit,
  onOpenChild,
}: {
  onEdit: (id?: string, date?: string) => void
  onOpenChild: () => void
}) {
  const { family, children } = useApp()
  const toast = useToast()

  const [date, setDate] = useState(todayStr())
  const [childFilter, setChildFilter] = useState<string>('all')
  const [query, setQuery] = useState('')
  const [items, setItems] = useState<Homework[]>([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState('')
  const [pendingDelete, setPendingDelete] = useState<Homework | null>(null)
  const [deleting, setDeleting] = useState(false)
  const [detail, setDetail] = useState<Homework | null>(null)
  const [lightbox, setLightbox] = useState<{ keys: string[]; index: number } | null>(
    null,
  )

  const load = useCallback(async () => {
    if (!family) return
    setLoading(true)
    setError('')
    try {
      const ids =
        childFilter === 'all' ? children.map((c) => c.id) : [childFilter]
      const rows = await fetchHomework(family.id, {
        childIds: ids,
        from: date,
        to: date,
      })
      setItems(rows)
    } catch (e) {
      setError(e instanceof Error ? e.message : '加载失败')
    } finally {
      setLoading(false)
    }
  }, [family, children, childFilter, date])

  useEffect(() => {
    void load()
  }, [load])

  const childOf = useMemo(() => {
    const map = new Map(children.map((c) => [c.id, c]))
    return (id: string) => map.get(id)
  }, [children])

  const visible = useMemo(() => {
    const q = query.trim().toLowerCase()
    if (!q) return items
    return items.filter(
      (h) =>
        h.subject.toLowerCase().includes(q) ||
        h.content.toLowerCase().includes(q),
    )
  }, [items, query])

  const doneCount = visible.filter((h) => h.isDone).length

  const doDelete = async () => {
    if (!pendingDelete) return
    setDeleting(true)
    try {
      await softDeleteHomework(pendingDelete.id)
      setItems((prev) => prev.filter((h) => h.id !== pendingDelete.id))
      toast.success('已删除')
      setPendingDelete(null)
    } catch (e) {
      toast.error(e instanceof Error ? e.message : '删除失败')
    } finally {
      setDeleting(false)
    }
  }

  if (!family) return null

  return (
    <>
      <TopBar
        title="作业"
        subtitle={
          loading
            ? '正在加载…'
            : `${fullDate(date)} · ${visible.length} 条${
                visible.length ? `，已完成 ${doneCount}` : ''
              }`
        }
        actions={
          <>
            <IconButton label="刷新" onClick={() => void load()}>
              <RefreshCw className={cn('size-4', loading && 'animate-spin')} />
            </IconButton>
            <Button
              variant="primary"
              icon={<Plus className="size-4" />}
              onClick={() => onEdit(undefined, date)}
            >
              布置作业
            </Button>
          </>
        }
      />

      <div className="min-h-0 flex-1 overflow-y-auto">
        <div className="mx-auto max-w-[980px] px-7 pb-16 pt-6">
          {/* 日期条：整体一个分段控件，两端与下方内容严格对齐 */}
          <div className="mb-4 flex items-center gap-0.5 rounded-xl border border-line bg-surface p-1 card-shadow">
            <button
              type="button"
              aria-label="前一天"
              onClick={() => setDate((d) => addDays(d, -1))}
              className="flex h-10 w-7 shrink-0 items-center justify-center rounded-lg text-muted transition-colors hover:bg-surface-3 hover:text-fg"
            >
              <ChevronLeft className="size-4" />
            </button>

            <div className="flex flex-1 gap-1">
              {Array.from({ length: 7 }, (_, i) => addDays(todayStr(), i - 3)).map(
                (d) => {
                  const active = d === date
                  const isToday = d === todayStr()
                  return (
                    <button
                      key={d}
                      type="button"
                      onClick={() => setDate(d)}
                      className={cn(
                        'flex h-10 flex-1 flex-col items-center justify-center rounded-lg text-center transition-colors',
                        active
                          ? 'bg-primary text-primary-fg shadow-sm'
                          : 'text-muted hover:bg-surface-3 hover:text-fg',
                      )}
                    >
                      <span
                        className={cn(
                          'text-[10.5px] leading-none',
                          active ? 'text-primary-fg/75' : 'text-subtle',
                        )}
                      >
                        {isToday ? '今天' : weekday(d).replace('周', '')}
                      </span>
                      <span className="mt-1 text-[14px] font-semibold leading-none tabular-nums">
                        {Number(d.slice(8))}
                      </span>
                    </button>
                  )
                },
              )}
            </div>

            <button
              type="button"
              aria-label="后一天"
              onClick={() => setDate((d) => addDays(d, 1))}
              className="flex h-10 w-7 shrink-0 items-center justify-center rounded-lg text-muted transition-colors hover:bg-surface-3 hover:text-fg"
            >
              <ChevronRight className="size-4" />
            </button>

            <label
              className="relative flex h-10 w-8 shrink-0 cursor-pointer items-center justify-center rounded-lg text-muted transition-colors hover:bg-surface-3 hover:text-fg"
              title="跳到指定日期"
            >
              <CalendarDays className="size-4" />
              <input
                type="date"
                value={date}
                onChange={(e) => {
                  if (e.target.value) setDate(e.target.value)
                }}
                className="absolute inset-0 cursor-pointer opacity-0"
                aria-label="选择日期"
              />
            </label>
          </div>

          {/* 孩子筛选 + 搜索 */}
          <div className="mb-4 flex items-center gap-2">
            <div className="flex flex-1 flex-wrap items-center gap-1.5">
              <FilterChip
                active={childFilter === 'all'}
                onClick={() => setChildFilter('all')}
              >
                全部孩子
              </FilterChip>
              {children.map((c) => (
                <FilterChip
                  key={c.id}
                  active={childFilter === c.id}
                  onClick={() => setChildFilter(c.id)}
                  dot={childColor(c.colorIndex)}
                >
                  {c.name}
                </FilterChip>
              ))}
            </div>
            <div className="relative w-56">
              <Search className="pointer-events-none absolute left-2.5 top-1/2 size-3.5 -translate-y-1/2 text-subtle" />
              <Input
                value={query}
                onChange={(e) => setQuery(e.target.value)}
                placeholder="搜索学科或内容"
                className="h-8 pl-8 text-[13px]"
              />
            </div>
          </div>

          {error ? (
            <Card className="border-danger/40 bg-danger-soft px-4 py-3">
              <p className="text-[13px] text-danger-fg">{error}</p>
              <Button size="sm" className="mt-2" onClick={() => void load()}>
                重试
              </Button>
            </Card>
          ) : loading ? (
            <SkeletonList />
          ) : visible.length === 0 ? (
            <Card>
              <EmptyState
                icon={<Inbox className="size-5" />}
                title={
                  children.length === 0
                    ? '还没有添加孩子'
                    : date === todayStr()
                      ? '今天还没有作业'
                      : `${friendlyDate(date)}没有作业`
                }
                description={
                  children.length === 0
                    ? '先在「孩子」里把孩子加上，才能给他布置作业。'
                    : query
                      ? '没有匹配的作业，换个关键词试试。'
                      : '可以在电脑上一次性把今天的几科都布置好。'
                }
                action={
                  children.length === 0 ? (
                    <Button variant="primary" onClick={onOpenChild}>
                      去添加孩子
                    </Button>
                  ) : (
                    <Button
                      variant="primary"
                      icon={<Plus className="size-4" />}
                      onClick={() => onEdit(undefined, date)}
                    >
                      布置作业
                    </Button>
                  )
                }
              />
            </Card>
          ) : (
            <div className="flex flex-col gap-2">
              {visible.map((h, i) => {
                const child = childOf(h.childId)
                return (
                  <Card
                    key={h.id}
                    role="button"
                    tabIndex={0}
                    aria-label={`查看${h.subject}作业详情`}
                    onClick={() => setDetail(h)}
                    onKeyDown={(e) => {
                      if (e.key === 'Enter' || e.key === ' ') {
                        e.preventDefault()
                        setDetail(h)
                      }
                    }}
                    className={cn(
                      'group relative animate-fade-up cursor-pointer overflow-hidden px-4 py-3.5 pl-5 transition-colors',
                      'hover:border-line-strong focus:outline-none',
                      'focus-visible:border-primary focus-visible:ring-3 focus-visible:ring-[var(--c-ring)]',
                    )}
                    style={{ animationDelay: `${Math.min(i, 8) * 22}ms` }}
                  >
                    {/* 学科色条：和手机端一致的视觉锚点，扫一眼就知道哪科 */}
                    <span
                      className="absolute inset-y-0 left-0 w-[3px]"
                      style={{ backgroundColor: subjectColor(h.subject) }}
                    />
                    <div className="flex items-start gap-3">
                      <div className="min-w-0 flex-1">
                        <div className="flex items-center gap-2">
                          <SubjectTag subject={h.subject} />
                          {child ? (
                            <span className="inline-flex items-center gap-1 text-[11.5px] text-subtle">
                              <span
                                className="size-1.5 rounded-full"
                                style={{ backgroundColor: childColor(child.colorIndex) }}
                              />
                              {child.name}
                            </span>
                          ) : null}
                          <span
                            className={cn(
                              'inline-flex items-center gap-1 rounded-md px-1.5 py-0.5 text-[11px] font-medium',
                              h.isDone
                                ? 'bg-success-soft text-success-fg'
                                : 'bg-surface-3 text-subtle',
                            )}
                          >
                            {h.isDone ? (
                              <Check className="size-3" strokeWidth={2.6} />
                            ) : (
                              <Circle className="size-2.5" />
                            )}
                            {h.isDone ? '已完成' : '未完成'}
                          </span>
                        </div>

                        <p className="mt-2 line-clamp-2 whitespace-pre-wrap break-words text-[14px] leading-6 text-fg">
                          {plainText(h.content) ||
                            (h.attachments.length
                              ? '（正文为空，附件见下）'
                              : '（只有图片，没有文字）')}
                        </p>

                        {h.imageKeys.filter(Boolean).length ? (
                          // 点缩略图开灯箱，不要顺带把详情抽屉也打开
                          <div
                            className="mt-2.5 flex gap-1.5"
                            onClick={(e) => e.stopPropagation()}
                          >
                            {h.imageKeys.filter(Boolean).map((key, idx) => (
                              <Thumb
                                key={`${key}-${idx}`}
                                storageKey={key}
                                onOpen={() =>
                                  setLightbox({
                                    keys: h.imageKeys.filter(Boolean),
                                    index: idx,
                                  })
                                }
                                className="size-11"
                              />
                            ))}
                            <span className="self-end pb-1 text-[11px] text-subtle">
                              {h.imageKeys.filter(Boolean).length} 张图
                            </span>
                          </div>
                        ) : null}

                        {h.attachments.length ? (
                          // 摘要里只露两个，点卡片进详情看全量
                          <div
                            className="mt-2 max-w-[420px]"
                            onClick={(e) => e.stopPropagation()}
                          >
                            <AttachmentList
                              attachments={h.attachments}
                              max={2}
                              compact
                            />
                          </div>
                        ) : null}
                      </div>

                      {/* 编辑/删除是卡片内的独立动作，不能连带触发「打开详情」 */}
                      <div
                        className="flex shrink-0 items-center gap-0.5 opacity-0 transition-opacity group-hover:opacity-100 focus-within:opacity-100"
                        onClick={(e) => e.stopPropagation()}
                      >
                        <IconButton
                          label="编辑"
                          onClick={() => onEdit(h.id, h.date)}
                        >
                          <Pencil className="size-4" />
                        </IconButton>
                        <IconButton
                          label="删除"
                          onClick={() => setPendingDelete(h)}
                          className="hover:bg-danger-soft hover:text-danger-fg"
                        >
                          <Trash2 className="size-4" />
                        </IconButton>
                      </div>
                    </div>
                  </Card>
                )
              })}
            </div>
          )}
        </div>
      </div>

      {detail ? (
        <HomeworkDetailDrawer
          homework={detail}
          child={childOf(detail.childId)}
          onClose={() => setDetail(null)}
          onEdit={() => {
            const { id, date } = detail
            setDetail(null)
            onEdit(id, date)
          }}
          onDelete={() => {
            const target = detail
            setDetail(null)
            setPendingDelete(target)
          }}
        />
      ) : null}

      <Modal
        open={pendingDelete !== null}
        onClose={() => setPendingDelete(null)}
        title="删除这条作业？"
        description="删掉后孩子手机上就看不到了。历史记录里也不会再出现。"
        footer={
          <>
            <Button onClick={() => setPendingDelete(null)}>取消</Button>
            <Button variant="danger" loading={deleting} onClick={() => void doDelete()}>
              删除
            </Button>
          </>
        }
      >
        {pendingDelete ? (
          <div className="rounded-xl border border-line bg-surface-2 p-3">
            <SubjectTag subject={pendingDelete.subject} />
            <p className="mt-2 line-clamp-3 whitespace-pre-wrap text-[13px] leading-5 text-muted">
              {plainText(pendingDelete.content) || '（只有图片）'}
            </p>
          </div>
        ) : null}
      </Modal>

      {lightbox ? (
        <Lightbox
          images={lightbox.keys.map((key) => ({ key }))}
          index={lightbox.index}
          onClose={() => setLightbox(null)}
          onChange={(i) => setLightbox({ ...lightbox, index: i })}
        />
      ) : null}
    </>
  )
}

function FilterChip({
  active,
  onClick,
  dot,
  children,
}: {
  active: boolean
  onClick: () => void
  dot?: string
  children: ReactNode
}) {
  return (
    <button
      type="button"
      onClick={onClick}
      className={cn(
        'inline-flex h-7 items-center gap-1.5 rounded-full border px-2.5 text-[12.5px] transition-colors',
        active
          ? 'border-primary/25 bg-primary-soft font-medium text-primary-soft-fg'
          : 'border-line bg-surface text-muted hover:border-line-strong hover:text-fg',
      )}
    >
      {dot ? (
        <span
          className="size-1.5 rounded-full"
          style={{ backgroundColor: dot }}
        />
      ) : null}
      {children}
    </button>
  )
}

function SkeletonList() {
  return (
    <div className="flex flex-col gap-2">
      {[0, 1, 2].map((i) => (
        <Card key={i} className="px-4 py-3.5">
          <div className="flex items-center gap-2">
            <div className="h-4.5 w-14 animate-pulse rounded bg-surface-3" />
            <div className="h-4 w-12 animate-pulse rounded bg-surface-3" />
          </div>
          <div className="mt-3 h-3.5 w-3/4 animate-pulse rounded bg-surface-3" />
          <div className="mt-2 h-3.5 w-1/2 animate-pulse rounded bg-surface-3" />
        </Card>
      ))}
    </div>
  )
}
