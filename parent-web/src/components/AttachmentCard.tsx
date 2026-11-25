import { ExternalLink, FileText, Link2, X } from 'lucide-react'
import { imageUrl } from '@/components/image'
import { cn } from '@/lib/cn'
import type { Attachment } from '@/lib/types'

/**
 * 附件卡片：文档和链接两种形态共用一块。
 *
 * 视觉刻意和手机端保持一致 —— 家长在电脑上布置的作业，孩子手机上看到的是
 * 同一张卡片（类型图标 + 名字 + 类型·大小 / 标题 + 站点），不会出现
 * 「电脑上像附件、手机上像正文」的错位。
 */

export function formatBytes(bytes: number): string {
  if (!bytes || bytes <= 0) return ''
  if (bytes < 1024) return `${bytes} B`
  if (bytes < 1024 * 1024) {
    const kb = bytes / 1024
    return kb < 10 ? `${kb.toFixed(1)} KB` : `${Math.round(kb)} KB`
  }
  return `${(bytes / 1048576).toFixed(1)} MB`
}

function kindLabel(a: Attachment): string {
  const n = `${a.mime} ${a.name}`.toLowerCase()
  let type = '文件'
  if (n.includes('pdf')) type = 'PDF'
  else if (n.includes('doc')) type = 'DOCX'
  const size = formatBytes(a.size)
  return size ? `${type} · ${size}` : type
}

function open(attachment: Attachment): void {
  const href = attachment.kind === 'link'
    ? attachment.url
    : attachment.key
      ? imageUrl(attachment.key)
      : ''
  if (!href) return
  // noopener：别把 window.opener 交给第三方页面
  window.open(href, '_blank', 'noopener,noreferrer')
}

export function AttachmentCard({
  attachment,
  onRemove,
  compact = false,
}: {
  attachment: Attachment
  /** 传了才显示删除按钮；详情页和摘要里不给删 */
  onRemove?: () => void
  compact?: boolean
}) {
  const isLink = attachment.kind === 'link'
  const title = isLink
    ? attachment.title || attachment.site || attachment.url
    : attachment.name || '未命名文件'
  const meta = isLink
    ? attachment.site || (() => {
        try {
          return new URL(attachment.url).hostname
        } catch {
          return attachment.url
        }
      })()
    : kindLabel(attachment)

  const enabled = isLink ? Boolean(attachment.url) : Boolean(attachment.key)

  return (
    <div
      className={cn(
        'group flex items-center gap-2.5 rounded-lg border border-line bg-surface px-2.5',
        compact ? 'py-1.5' : 'py-2',
        enabled && 'cursor-pointer transition-colors hover:border-line-strong',
      )}
      role={enabled ? 'button' : undefined}
      tabIndex={enabled ? 0 : undefined}
      onClick={() => enabled && open(attachment)}
      onKeyDown={(e) => {
        if (enabled && (e.key === 'Enter' || e.key === ' ')) {
          e.preventDefault()
          open(attachment)
        }
      }}
      title={isLink ? attachment.url : attachment.name}
    >
      <span
        className={cn(
          'flex shrink-0 items-center justify-center rounded-md',
          compact ? 'size-7' : 'size-9',
          isLink ? 'bg-primary-soft text-primary-soft-fg' : 'bg-surface-3 text-muted',
        )}
      >
        {isLink ? (
          <Link2 className={compact ? 'size-3.5' : 'size-4'} />
        ) : (
          <FileText className={compact ? 'size-3.5' : 'size-4'} />
        )}
      </span>

      <div className="min-w-0 flex-1">
        <p className="truncate text-[13px] font-medium text-fg">{title}</p>
        <p className="truncate text-[11.5px] text-subtle">
          {!enabled ? '还没传完' : meta}
        </p>
      </div>

      {onRemove ? (
        <button
          type="button"
          aria-label="移除这个附件"
          className="flex size-6 shrink-0 items-center justify-center rounded text-subtle opacity-0 transition-opacity hover:bg-surface-3 hover:text-danger-fg group-hover:opacity-100"
          onClick={(e) => {
            e.stopPropagation()
            onRemove()
          }}
        >
          <X className="size-3.5" />
        </button>
      ) : enabled ? (
        <ExternalLink className="size-3.5 shrink-0 text-subtle" />
      ) : null}
    </div>
  )
}

/**
 * 一列附件卡片。
 *
 * `max` 只给列表摘要用：卡片上露前两个，剩下的折成一行「还有 N 个」，
 * 免得一条作业把整个列表撑长。详情页传 undefined，全量铺开。
 */
export function AttachmentList({
  attachments,
  max,
  compact = false,
  onRemove,
}: {
  attachments: Attachment[]
  max?: number
  compact?: boolean
  onRemove?: (index: number) => void
}) {
  if (!attachments.length) return null
  const limit = max ?? attachments.length
  const shown = attachments.slice(0, limit)
  const rest = attachments.length - shown.length

  return (
    <div className={cn('flex flex-col', compact ? 'gap-1' : 'gap-1.5')}>
      {shown.map((a, i) => (
        <AttachmentCard
          key={a.id || `${a.kind}-${i}`}
          attachment={a}
          compact={compact}
          onRemove={onRemove ? () => onRemove(i) : undefined}
        />
      ))}
      {rest > 0 ? (
        <span className="pl-1 text-[11.5px] text-subtle">还有 {rest} 个附件</span>
      ) : null}
    </div>
  )
}
