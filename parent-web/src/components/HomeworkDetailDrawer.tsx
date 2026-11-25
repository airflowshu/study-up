import { useEffect, useRef } from 'react'
import { Check, Circle, Clock, ImageIcon, Pencil, Trash2, X } from 'lucide-react'
import { fullDate, timeAgo } from '@/lib/date'
import { childColor, subjectColor } from '@/lib/subject'
import { plainLength } from '@/lib/richBody'
import { cn } from '@/lib/cn'
import { enterModal, exitModal, isTopModal } from '@/lib/modal'
import { Button, IconButton, SubjectTag } from '@/components/ui'
import { RichBodyView } from '@/components/RichBodyView'
import { AttachmentList } from '@/components/AttachmentCard'
import type { Child, Homework } from '@/lib/types'

/**
 * 作业详情抽屉。
 *
 * 列表卡片上的两行摘要只够扫一眼，真正要看懂「这题到底布置了什么」——
 * 尤其是图插在哪一段后面——必须看完整渲染。所以单击卡片开抽屉，
 * 不直接跳编辑页：先看清楚，再决定要不要改。
 *
 * 渲染用和手机端同一套 `RichBodyView`，所见即孩子所见。
 */
export function HomeworkDetailDrawer({
  homework,
  child,
  onClose,
  onEdit,
  onDelete,
}: {
  homework: Homework
  child?: Child
  onClose: () => void
  onEdit: () => void
  onDelete: () => void
}) {
  const token = useRef(Symbol('drawer')).current

  // 抽屉开在模态栈里：灯箱叠上来时它是下层，Esc 该关灯箱而不是连抽屉一起关
  useEffect(() => {
    enterModal(token)
    return () => exitModal(token)
  }, [token])

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key !== 'Escape' || !isTopModal(token)) return
      onClose()
    }
    document.addEventListener('keydown', onKey)
    return () => document.removeEventListener('keydown', onKey)
  }, [onClose, token])

  const imageCount = homework.imageKeys.filter(Boolean).length
  const chars = plainLength(homework.content)

  return (
    <div
      className="fixed inset-0 z-50"
      role="dialog"
      aria-modal="true"
      aria-label={`${homework.subject}作业详情`}
    >
      <div
        className="absolute inset-0 animate-fade-in bg-black/35 backdrop-blur-[2px]"
        onClick={onClose}
      />

      <div
        className={cn(
          'absolute inset-y-0 right-0 flex w-full max-w-[540px] animate-slide-in-right flex-col',
          'border-l border-line bg-surface shadow-2xl',
        )}
      >
        {/* 学科色条：和列表卡片同一个视觉锚点，抽屉打开时不丢上下文 */}
        <span
          className="h-[3px] w-full shrink-0"
          style={{ backgroundColor: subjectColor(homework.subject) }}
        />

        <header className="shrink-0 px-6 pb-4 pt-5">
          <div className="flex items-center justify-between gap-3">
            <h2 className="text-[15px] font-semibold text-fg">作业详情</h2>
            <IconButton label="关闭" onClick={onClose} className="-mr-1.5 shrink-0">
              <X className="size-4" />
            </IconButton>
          </div>

          <div className="mt-3 flex flex-wrap items-center gap-2">
            <SubjectTag subject={homework.subject} />
            <span
              className={cn(
                'inline-flex items-center gap-1 rounded-md px-1.5 py-0.5 text-[11px] font-medium',
                homework.isDone
                  ? 'bg-success-soft text-success-fg'
                  : 'bg-surface-3 text-subtle',
              )}
            >
              {homework.isDone ? (
                <Check className="size-3" strokeWidth={2.6} />
              ) : (
                <Circle className="size-2.5" />
              )}
              {homework.isDone ? '已完成' : '未完成'}
            </span>
          </div>

          <div className="mt-2 flex flex-wrap items-center gap-x-3 gap-y-1 text-[12px] text-subtle">
            {child ? (
              <span className="inline-flex items-center gap-1.5">
                <span
                  className="size-2 rounded-full"
                  style={{ backgroundColor: childColor(child.colorIndex) }}
                />
                {child.name}
              </span>
            ) : null}
            <span>{fullDate(homework.date)}</span>
            {chars ? <span>{chars} 字</span> : null}
            {imageCount ? (
              <span className="inline-flex items-center gap-1">
                <ImageIcon className="size-3" />
                {imageCount} 张图
              </span>
            ) : null}
          </div>
        </header>

        <div className="min-h-0 flex-1 overflow-y-auto px-6 pb-6">
          <RichBodyView
            content={homework.content}
            imageKeys={homework.imageKeys}
          />

          {homework.attachments.length ? (
            <div className="mt-4">
              <AttachmentList attachments={homework.attachments} />
            </div>
          ) : null}

          <div className="mt-6 flex flex-wrap items-center gap-x-4 gap-y-1 border-t border-line pt-3 text-[11.5px] text-subtle">
            <span className="inline-flex items-center gap-1">
              <Clock className="size-3" />
              布置于 {timeAgo(homework.updatedAt || homework.createdAt)}
            </span>
            {homework.isDone && homework.doneAt ? (
              <span>完成于 {timeAgo(homework.doneAt)}</span>
            ) : null}
          </div>
        </div>

        <footer className="flex shrink-0 items-center justify-end gap-2 border-t border-line bg-bg-soft px-6 py-3">
          <Button
            variant="ghost"
            size="sm"
            icon={<Trash2 className="size-3.5" />}
            onClick={onDelete}
            className="mr-auto hover:bg-danger-soft hover:text-danger-fg"
          >
            删除
          </Button>
          <Button onClick={onClose}>关闭</Button>
          <Button
            variant="primary"
            size="md"
            icon={<Pencil className="size-3.5" />}
            onClick={onEdit}
          >
            编辑
          </Button>
        </footer>
      </div>
    </div>
  )
}
