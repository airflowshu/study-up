import {
  useCallback,
  useEffect,
  useMemo,
  useRef,
  useState,
  type ClipboardEvent,
  type DragEvent,
} from 'react'
import {
  ArrowLeft,
  ImagePlus,
  Link2,
  Loader2,
  Paperclip,
  RotateCw,
  Trash2,
  UploadCloud,
} from 'lucide-react'
import {
  fetchHomeworkById,
  fetchLinkPreview,
  MAX_ATTACHMENT_BYTES,
  newId,
  saveHomework,
  uploadHomeworkFile,
  uploadHomeworkImage,
} from '@/lib/api'
import { imageUrl } from '@/components/image'
import { fullDate, friendlyDate, todayStr, addDays } from '@/lib/date'
import {
  dropTrailingHoles,
  fillImageHoles,
  imageHoles,
  insertMarkersAt,
  normalizeBody,
  plainLength,
  removeImageMarker,
} from '@/lib/richBody'
import { SUBJECTS, subjectColor } from '@/lib/subject'
import {
  fetchImageAsFile,
  readClipboard,
  stripEmojiPlaceholders,
  type ClipboardDraft,
} from '@/lib/clipboard'
import { useApp } from '@/store/app'
import { useToast } from '@/components/toast'
import { TopBar } from '@/components/AppShell'
import {
  Button,
  Card,
  Field,
  Input,
  Modal,
  Spinner,
  Textarea,
} from '@/components/ui'
import { RichBodyView } from '@/components/RichBodyView'
import { AttachmentCard, AttachmentList } from '@/components/AttachmentCard'
import { cn } from '@/lib/cn'
import type { Attachment, Homework } from '@/lib/types'

interface EditImage {
  uid: string
  /** 云端 key；上传完成前是空串 */
  key: string
  /** 本地预览地址（blob URL）或云端直链 */
  preview: string
  upload: 'pending' | 'done' | 'failed'
  file?: File
  slot: string
}

/** 附件在编辑页的临时状态：多了「传没传完」和本地 File，存库前要剔掉。 */
interface EditAttachment extends Attachment {
  upload: 'pending' | 'done' | 'failed'
  file?: File
}

/**
 * 说清楚「图为什么没进来」。
 *
 * 两种失败的原因天差地别，用户能采取的动作却只有一个（回源程序单张复制 / 截图），
 * 所以提示里必须点名是哪一种，否则只会被当成程序坏了。
 *
 * - `file:` —— 源程序（微信 PC、QQ 等）只往剪贴板里放了本地缓存路径。
 *   网页按浏览器的安全模型无权读本地文件，这不是权限申请一下就能解决的。
 * - 其他 —— 源站不允许跨域取图（公众号图床等），同样是浏览器层面的硬边界。
 */
function blockedReason(blocked: string[]): string {
  const n = blocked.length
  const tail = '文字已粘好；图请单张右键「复制图片」再粘，或直接截图'
  if (n === 0) return `有图没取到。${tail}`
  const local = blocked.filter((s) => /^file:/i.test(s)).length
  if (local === n) return `${n} 张图是程序本地缓存文件，网页无权读取。${tail}`
  if (local === 0) return `${n} 张图的源站不允许跨域取图。${tail}`
  return `${n} 张图取不到（本地缓存 / 跨域）。${tail}`
}

/**
 * 内置表情没能带过来。
 *
 * 和「图取不到」是两件事：图是**有地址但读不了**，表情是**地址都没有** ——
 * QQ / 微信在写剪贴板时就把动态表情换成了一个 `[表情]` 文字标记。
 * 所以这里不能说「右键复制图片」，得说清楚信息已经丢了，想要只能截图。
 */
function emojiLossMessage(count: number): string {
  return `${count} 个内置表情没能带过来：QQ 复制时把它们换成了「[表情]」文字标记，具体是哪个表情已丢失，网页无法还原。文字已完整粘好；要保留表情请截图补上。`
}

/** 粘贴后统一报告「没带过来的部分」，图与表情可以同时出现 */
function pasteLossMessages(draft: ClipboardDraft): string[] {
  const msgs: string[] = []
  if (draft.unreadable) {
    if (draft.blocked.length) {
      console.info('[粘贴] 以下图片地址被拒，可据此判断来源：', draft.blocked)
    }
    msgs.push(`取不到图的提示：${blockedReason(draft.blocked)}`)
  }
  if (draft.emojiCount) msgs.push(emojiLossMessage(draft.emojiCount))
  return msgs
}

export function HomeworkEditPage({
  id,
  presetDate,
  onDone,
  onCancel,
}: {
  id?: string
  presetDate?: string
  onDone: () => void
  onCancel: () => void
}) {
  const { family, children } = useApp()
  const toast = useToast()

  const isNew = !id
  const homeworkId = useRef(id ?? newId())
  const taRef = useRef<HTMLTextAreaElement>(null)
  const fileRef = useRef<HTMLInputElement>(null)
  const docRef = useRef<HTMLInputElement>(null)

  const [loading, setLoading] = useState(!isNew)
  const [saving, setSaving] = useState(false)
  const [loadError, setLoadError] = useState('')

  const [subject, setSubject] = useState<string>('语文')
  const [useCustom, setUseCustom] = useState(false)
  const [customSubject, setCustomSubject] = useState('')
  const [childId, setChildId] = useState('')
  const [date, setDate] = useState(presetDate ?? todayStr())
  const [text, setText] = useState('')
  const [images, setImages] = useState<EditImage[]>([])
  const [attachments, setAttachments] = useState<EditAttachment[]>([])
  const [linkOpen, setLinkOpen] = useState(false)
  const [linkUrl, setLinkUrl] = useState('')
  const [linkBusy, setLinkBusy] = useState(false)
  const [dragging, setDragging] = useState(false)
  const [dirty, setDirty] = useState(false)
  const [confirmLeave, setConfirmLeave] = useState(false)

  // blob URL 用完要回收，否则长会话会一直攒内存
  useEffect(() => {
    return () => {
      for (const im of images) {
        if (im.preview.startsWith('blob:')) URL.revokeObjectURL(im.preview)
      }
    }
    // 只在卸载时回收
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [])

  // 默认选第一个孩子
  useEffect(() => {
    if (!childId && children[0]) setChildId(children[0].id)
  }, [children, childId])

  useEffect(() => {
    if (isNew || !id) return
    let alive = true
    ;(async () => {
      try {
        const hw: Homework | null = await fetchHomeworkById(id)
        if (!alive) return
        if (!hw) {
          setLoadError('这条作业已经不在了，可能被别处删掉了')
          return
        }
        setSubject(hw.subject)
        if (!SUBJECTS.includes(hw.subject as (typeof SUBJECTS)[number])) {
          setUseCustom(true)
          setCustomSubject(hw.subject)
        }
        setChildId(hw.childId)
        setDate(hw.date)
        setText(hw.content)
        setImages(
          hw.imageKeys.map((key, i) => ({
            uid: `existing-${i}-${key}`,
            key,
            preview: key ? imageUrl(key) : '',
            upload: key ? 'done' : 'failed',
            slot: '',
          })),
        )
        setAttachments(
          hw.attachments.map((a) => ({
            ...a,
            // 文件类没有 key 说明当时没传成功，标成待重试，别让它静默消失
            upload: a.kind === 'file' && !a.key ? 'failed' : 'done',
          })),
        )
      } catch (e) {
        if (alive) {
          setLoadError(e instanceof Error ? e.message : '加载失败')
        }
      } finally {
        if (alive) setLoading(false)
      }
    })()
    return () => {
      alive = false
    }
  }, [id, isNew])

  // 有改动时关标签页给个提醒
  useEffect(() => {
    if (!dirty) return
    const onBeforeUnload = (e: BeforeUnloadEvent) => {
      e.preventDefault()
      e.returnValue = ''
    }
    window.addEventListener('beforeunload', onBeforeUnload)
    return () => window.removeEventListener('beforeunload', onBeforeUnload)
  }, [dirty])

  const finalSubject = useCustom ? customSubject.trim() : subject

  /** 上传一张。失败留成可重试状态，不静默吞掉。 */
  const uploadOne = useCallback(
    async (item: EditImage) => {
      if (!item.file || !family) return
      try {
        // 图片路径带上家庭 id：服务端据此校验归属，别人的 token 写不进这个前缀
        const key = await uploadHomeworkImage(
          family.id,
          homeworkId.current,
          item.slot,
          item.file,
        )
        setImages((prev) =>
          prev.map((x) => (x.uid === item.uid ? { ...x, key, upload: 'done' } : x)),
        )
      } catch (e) {
        // 一定要留痕：UI 上只有「重试」两个字，没有这条日志就只能靠猜。
        // 浏览器 CSP 拦跨域请求时报的是 `TypeError: Failed to fetch`，
        // 网络面板里连请求都看不到，是最难查的一类失败。
        console.error('[上传失败]', {
          key: item.slot,
          name: item.file.name,
          type: item.file.type,
          size: item.file.size,
          error: e,
        })
        setImages((prev) =>
          prev.map((x) => (x.uid === item.uid ? { ...x, upload: 'failed' } : x)),
        )
      }
    },
    [family],
  )

  /**
   * 加图。三件事要一起做对：
   * 1. 槽位追加到末尾（下标 + 1 就是正文里的 [图N]）
   * 2. 正文标记优先填 `[图片]` 占位（微信复制过来的位置），没有占位才插在光标处
   * 3. 立刻开始上传，家长不用等保存才发现有图没传上去
   */
  const attachFiles = useCallback(
    (files: File[]) => {
      const imgs = files.filter((f) => f.type.startsWith('image/'))
      if (!imgs.length) return

      const base = images.length
      const created: EditImage[] = imgs.map((file, i) => ({
        uid: `${Date.now()}-${i}-${Math.random().toString(36).slice(2, 7)}`,
        key: '',
        preview: URL.createObjectURL(file),
        upload: 'pending',
        file,
        slot: `${Date.now().toString(36)}${Math.random().toString(36).slice(2, 8)}`,
      }))

      setImages((prev) => [...prev, ...created])
      setDirty(true)

      setText((prev) => {
        const holes = imageHoles(prev)
        if (holes.length) {
          const use = Math.min(holes.length, created.length)
          const filled = fillImageHoles(prev, base + 1, use).content
          const rest = created.length - use
          if (!rest) return filled
          const idx = Array.from(
            { length: rest },
            (_, i) => base + use + i + 1,
          )
          return insertMarkersAt(filled, filled.length, idx).content
        }
        const cursor = taRef.current?.selectionStart ?? prev.length
        const idx = Array.from({ length: created.length }, (_, i) => base + i + 1)
        return insertMarkersAt(prev, cursor, idx).content
      })

      for (const item of created) void uploadOne(item)
    },
    [images.length, uploadOne],
  )

  /** 粘贴下载是异步的，届时 attachFiles 可能已经换了闭包（images.length 变了），用 ref 拿最新的 */
  const attachRef = useRef(attachFiles)
  useEffect(() => {
    attachRef.current = attachFiles
  }, [attachFiles])

  /**
   * 粘贴。分两种情况处理，因为剪贴板里「有没有图片字节」是两回事：
   *
   * 1. 有字节（截图、右键复制图片、资源管理器复制文件）→ 直接用，最可靠；
   * 2. 只有地址（从网页、Word、微信里选中「文字+图片」复制）→ `files` 是空的，
   *    图片只在 text/html 的 `<img>` 里。这时把文字按原样铺进来、图片位置留 `[图片]`
   *    占位，再按地址把图下载回来上传，最后由 attachFiles 填成 `[图N]`。
   *
   * 第 2 种是 Windows 上的常见情形，也是「图粘不上来」的真正原因。
   */
  const onPaste = (e: ClipboardEvent<HTMLTextAreaElement>) => {
    const { files, draft } = readClipboard(e.nativeEvent)

    if (files.length) {
      // 剪贴板里同时有文字和图片：文字手动插回光标处，图片自己接管
      e.preventDefault()
      const raw = e.clipboardData.getData('text/plain')
      const { text: plain, count: emojiCount } = stripEmojiPlaceholders(raw)
      const ta = taRef.current
      if (plain && ta) {
        const start = ta.selectionStart
        const end = ta.selectionEnd
        setText((prev) => prev.slice(0, start) + plain + prev.slice(end))
        setDirty(true)
      }
      if (emojiCount) toast.error(emojiLossMessage(emojiCount))
      attachFiles(files)
      return
    }

    // 纯文字：不接管，交回浏览器原生粘贴（撤销栈还能用）
    if (!draft) return

    e.preventDefault()
    const ta = taRef.current
    const start = ta?.selectionStart ?? text.length
    const end = ta?.selectionEnd ?? text.length
    const inserted = draft.text
    setText((prev) => prev.slice(0, start) + inserted + prev.slice(end))
    setDirty(true)

    const caret = start + inserted.length
    requestAnimationFrame(() => {
      ta?.focus()
      ta?.setSelectionRange(caret, caret)
    })

    if (!draft.imageSrcs.length) {
      pasteLossMessages(draft).forEach((m) => toast.error(m))
      return
    }

    // 串行下载：并发容易被浏览器连接数限制，也会让上传顺序和正文里的占位对不上
    void (async () => {
      const got: File[] = []
      for (let i = 0; i < draft.imageSrcs.length; i += 1) {
        const src = draft.imageSrcs[i]
        const file = src ? await fetchImageAsFile(src, i) : null
        if (file) got.push(file)
      }

      if (got.length) attachRef.current(got)

      // 没取到的图不会有人来填占位，留着会让孩子端看到「[图片]」三个字
      const missing = draft.imageSrcs.length - got.length
      if (missing > 0) setText((prev) => dropTrailingHoles(prev, missing))

      const lost = missing + draft.unreadable
      if (lost > 0 && got.length) {
        toast.error(`${got.length} 张图已取到，${lost} 张取不到，可单张复制或截图补上`)
      } else if (lost > 0) {
        toast.error(`取不到图的提示：${blockedReason(draft.blocked)}`)
      }

      // 表情和图片可以同时出现在一次粘贴里，图处理完再说表情的事
      if (draft.emojiCount) toast.error(emojiLossMessage(draft.emojiCount))
    })()
  }

  const onDrop = (e: DragEvent) => {
    e.preventDefault()
    setDragging(false)
    const files = Array.from(e.dataTransfer.files)
    if (files.length) attachFiles(files)
  }

  const removeImage = (idx: number) => {
    const target = images[idx]
    if (target?.preview.startsWith('blob:')) URL.revokeObjectURL(target.preview)
    setImages((prev) => prev.filter((_, i) => i !== idx))
    // 后面图片的标记序号要整体减一，否则 [图3] 会指到已删的那张
    setText((prev) => removeImageMarker(prev, idx + 1))
    setDirty(true)
  }

  const retry = (item: EditImage) => {
    setImages((prev) =>
      prev.map((x) => (x.uid === item.uid ? { ...x, upload: 'pending' } : x)),
    )
    void uploadOne(item)
  }

  /** 传一个附件。失败就留在列表里标红，家长能重试或删掉 —— 不能静默丢弃。 */
  const uploadDoc = useCallback(
    async (item: EditAttachment) => {
      if (!family || !item.file) return
      try {
        const key = await uploadHomeworkFile(
          family.id,
          homeworkId.current,
          item.id,
          item.file,
        )
        setAttachments((prev) =>
          prev.map((x) => (x.id === item.id ? { ...x, key, upload: 'done' } : x)),
        )
      } catch {
        setAttachments((prev) =>
          prev.map((x) => (x.id === item.id ? { ...x, upload: 'failed' } : x)),
        )
      }
    },
    [family],
  )

  /**
   * 加文档。和图片不同：附件不改正文，只往列表末尾追加。
   *
   * 当场就传，不等保存 —— 20 MB 的 PDF 在家宽上要几十秒，
   * 传到一半才报错的话，家长已经写了一大段内容了。
   */
  const addDocuments = (files: File[]) => {
    const docs = files.filter((f) => /\.(pdf|docx)$/i.test(f.name))
    if (!docs.length) {
      toast.error('只支持 PDF 和 DOCX')
      return
    }
    const big = docs.filter((f) => f.size > MAX_ATTACHMENT_BYTES)
    if (big.length) {
      toast.error(`${big.map((f) => f.name).join('、')} 超过 20 MB，没加上`)
    }
    const ok = docs.filter((f) => f.size <= MAX_ATTACHMENT_BYTES)
    if (!ok.length) return

    const created: EditAttachment[] = ok.map((file) => ({
      id: newId().replace(/-/g, ''),
      kind: 'file',
      key: '',
      name: file.name,
      size: file.size,
      mime: file.name.toLowerCase().endsWith('.docx')
        ? 'application/vnd.openxmlformats-officedocument.wordprocessingml.document'
        : 'application/pdf',
      url: '',
      title: '',
      desc: '',
      site: '',
      image: '',
      upload: 'pending',
      file,
    }))
    setAttachments((prev) => [...prev, ...created])
    setDirty(true)
    for (const item of created) void uploadDoc(item)
  }

  const removeAttachment = (index: number) => {
    setAttachments((prev) => prev.filter((_, i) => i !== index))
    setDirty(true)
  }

  const retryDoc = (item: EditAttachment) => {
    if (!item.file) {
      toast.error('这条附件的原文件已经不在了，删掉重加一次')
      return
    }
    setAttachments((prev) =>
      prev.map((x) => (x.id === item.id ? { ...x, upload: 'pending' } : x)),
    )
    void uploadDoc(item)
  }

  /** 加一条链接卡片：先让服务端抓标题，抓不到就退回「域名 + 网址」。 */
  const addLink = async () => {
    const raw = linkUrl.trim()
    if (!raw) return
    let parsed: URL
    try {
      parsed = new URL(raw)
    } catch {
      toast.error('这不是一个有效的网址')
      return
    }
    if (parsed.protocol !== 'http:' && parsed.protocol !== 'https:') {
      toast.error('只支持 http / https 链接')
      return
    }

    setLinkBusy(true)
    try {
      let preview = {
        url: parsed.toString(),
        title: '',
        desc: '',
        image: '',
        site: parsed.hostname,
      }
      try {
        preview = await fetchLinkPreview(parsed.toString())
      } catch {
        // 对方站点拒绝抓取很常见，不该因此发不出去
        toast.error('抓不到标题，先按域名显示')
      }
      const created: EditAttachment = {
        id: newId().replace(/-/g, ''),
        kind: 'link',
        key: '',
        name: '',
        size: 0,
        mime: '',
        url: preview.url || parsed.toString(),
        title: preview.title,
        desc: preview.desc,
        site: preview.site || parsed.hostname,
        image: preview.image,
        upload: 'done',
      }
      setAttachments((prev) => [...prev, created])
      setDirty(true)
      setLinkOpen(false)
      setLinkUrl('')
    } finally {
      setLinkBusy(false)
    }
  }

  const pendingImageCount = images.filter((i) => i.upload !== 'done').length
  const pendingDocCount = attachments.filter(
    (a) => a.kind === 'file' && a.upload !== 'done',
  ).length
  const pendingCount = pendingImageCount + pendingDocCount

  const save = async () => {
    if (!family) return
    if (!childId) {
      toast.error('先选一个孩子')
      return
    }
    if (!finalSubject) {
      toast.error('学科不能为空')
      return
    }
    const hasText = plainLength(text) > 0
    if (!hasText && images.length === 0 && attachments.length === 0) {
      toast.error('写点内容，或者加张图、附件')
      return
    }
    if (pendingCount > 0) {
      toast.error(`还有 ${pendingCount} 个文件没传完，等一下再保存`)
      return
    }

    setSaving(true)
    try {
      const content = normalizeBody(text, images.length)
      await saveHomework(
        {
          childId,
          familyId: family.id,
          date,
          subject: finalSubject,
          content,
          imageKeys: images.map((i) => i.key),
          // 编辑态字段（upload / file）不能进库，显式挑一遍
          attachments: attachments.map((a) => ({
            id: a.id,
            kind: a.kind,
            key: a.key,
            name: a.name,
            size: a.size,
            mime: a.mime,
            url: a.url,
            title: a.title,
            desc: a.desc,
            site: a.site,
            image: a.image,
          })),
        },
        homeworkId.current,
        isNew,
      )
      setDirty(false)
      toast.success(isNew ? '作业已布置，孩子手机上能看到了' : '已保存')
      onDone()
    } catch (e) {
      toast.error(e instanceof Error ? e.message : '保存失败，请重试')
    } finally {
      setSaving(false)
    }
  }

  const requestLeave = () => {
    if (dirty) setConfirmLeave(true)
    else onCancel()
  }

  const previewKeys = useMemo(() => images.map((i) => i.key), [images])
  const charCount = plainLength(text)

  if (loading) {
    return (
      <>
        <TopBar title="编辑作业" />
        <div className="flex flex-1 items-center justify-center text-muted">
          <Spinner className="size-5" />
        </div>
      </>
    )
  }

  if (loadError) {
    return (
      <>
        <TopBar title="编辑作业" />
        <div className="flex flex-1 flex-col items-center justify-center gap-3">
          <p className="text-sm text-danger-fg">{loadError}</p>
          <Button onClick={onCancel}>返回列表</Button>
        </div>
      </>
    )
  }

  return (
    <>
      <TopBar
        title={isNew ? '布置作业' : '编辑作业'}
        subtitle={`${friendlyDate(date)} · ${fullDate(date)}`}
        actions={
          <>
            <Button icon={<ArrowLeft className="size-4" />} onClick={requestLeave}>
              返回
            </Button>
            <Button
              variant="primary"
              loading={saving}
              onClick={() => void save()}
              disabled={pendingCount > 0}
            >
              {saving ? '保存中…' : isNew ? '布置' : '保存'}
            </Button>
          </>
        }
      />

      <div className="flex min-h-0 flex-1">
        <div className="min-h-0 flex-1 overflow-y-auto">
          <div
            className="mx-auto flex max-w-[820px] flex-col gap-5 px-8 py-6"
            onDragOver={(e) => {
              e.preventDefault()
              setDragging(true)
            }}
            onDragLeave={(e) => {
              if (e.currentTarget.contains(e.relatedTarget as Node)) return
              setDragging(false)
            }}
            onDrop={onDrop}
          >
            {/* 学科 */}
            <Field label="学科">
              <div className="flex flex-wrap gap-1.5">
                {SUBJECTS.map((s) => {
                  const active = !useCustom && subject === s
                  const color = subjectColor(s)
                  return (
                    <button
                      key={s}
                      type="button"
                      onClick={() => {
                        setSubject(s)
                        setUseCustom(false)
                        setDirty(true)
                      }}
                      className={cn(
                        'h-8 rounded-lg border px-3 text-[13px] transition-colors',
                        active
                          ? 'font-medium'
                          : 'border-line bg-surface text-muted hover:border-line-strong hover:text-fg',
                      )}
                      style={
                        active
                          ? {
                              color,
                              borderColor: `${color}66`,
                              backgroundColor: `${color}14`,
                            }
                          : undefined
                      }
                    >
                      {s}
                    </button>
                  )
                })}
                <button
                  type="button"
                  onClick={() => {
                    setUseCustom(true)
                    setDirty(true)
                  }}
                  className={cn(
                    'h-8 rounded-lg border px-3 text-[13px] transition-colors',
                    useCustom
                      ? 'border-primary/40 bg-primary-soft font-medium text-primary-soft-fg'
                      : 'border-dashed border-line-strong bg-transparent text-subtle hover:text-fg',
                  )}
                >
                  其他
                </button>
              </div>
              {useCustom ? (
                <Input
                  value={customSubject}
                  onChange={(e) => {
                    setCustomSubject(e.target.value.slice(0, 12))
                    setDirty(true)
                  }}
                  placeholder="学科名称，比如「书法」"
                  className="mt-2 h-9 max-w-56 text-[13px]"
                  autoFocus
                />
              ) : null}
            </Field>

            {/* 孩子 + 日期 */}
            <div className="grid grid-cols-2 gap-4">
              <Field label="给谁布置">
                {children.length === 0 ? (
                  <p className="text-[13px] text-danger-fg">
                    还没添加孩子，先去「孩子」页加一个
                  </p>
                ) : (
                  <div className="flex flex-wrap gap-1.5">
                    {children.map((c) => {
                      const active = childId === c.id
                      return (
                        <button
                          key={c.id}
                          type="button"
                          onClick={() => {
                            setChildId(c.id)
                            setDirty(true)
                          }}
                          className={cn(
                            'h-9 rounded-lg border px-3 text-[13px] transition-colors',
                            active
                              ? 'border-primary/40 bg-primary-soft font-medium text-primary-soft-fg'
                              : 'border-line bg-surface text-muted hover:border-line-strong hover:text-fg',
                          )}
                        >
                          {c.name}
                        </button>
                      )
                    })}
                  </div>
                )}
              </Field>

              <Field label="日期" hint={
                <span className="flex gap-2">
                  <button
                    type="button"
                    className="hover:text-primary"
                    onClick={() => {
                      setDate(todayStr())
                      setDirty(true)
                    }}
                  >
                    今天
                  </button>
                  <button
                    type="button"
                    className="hover:text-primary"
                    onClick={() => {
                      setDate(addDays(todayStr(), 1))
                      setDirty(true)
                    }}
                  >
                    明天
                  </button>
                </span>
              }>
                <Input
                  type="date"
                  value={date}
                  onChange={(e) => {
                    if (e.target.value) {
                      setDate(e.target.value)
                      setDirty(true)
                    }
                  }}
                />
              </Field>
            </div>

            {/* 正文 + 图片 */}
            <div className="flex flex-col gap-2">
              <div className="flex items-baseline justify-between">
                <label className="text-[13px] font-medium text-fg">作业内容</label>
                <span className="text-xs text-subtle">
                  {charCount} 字{images.length ? ` · ${images.length} 张图` : ''}
                  {attachments.length ? ` · ${attachments.length} 个附件` : ''}
                </span>
              </div>

              <div
                className={cn(
                  'relative rounded-xl transition-colors',
                  dragging && 'ring-2 ring-primary/40',
                )}
              >
                <Textarea
                  ref={taRef}
                  value={text}
                  onChange={(e) => {
                    setText(e.target.value)
                    setDirty(true)
                  }}
                  onPaste={onPaste}
                  placeholder={
                    '例：数学练习册 P32–34，第 8 题不用做。\n\n直接把微信里的图文消息 Ctrl+V 粘进来也行。'
                  }
                  className="min-h-[220px] pb-11"
                />

                {dragging ? (
                  <div className="pointer-events-none absolute inset-0 flex items-center justify-center rounded-xl bg-primary-soft/80 text-[13px] font-medium text-primary-soft-fg">
                    松手即可添加图片
                  </div>
                ) : null}

                <div className="absolute inset-x-2 bottom-2 flex items-center justify-between">
                  <div className="flex items-center gap-1">
                    <Button
                      size="sm"
                      variant="ghost"
                      icon={<ImagePlus className="size-3.5" />}
                      onClick={() => fileRef.current?.click()}
                    >
                      添加图片
                    </Button>
                    <input
                      ref={fileRef}
                      type="file"
                      accept="image/*"
                      multiple
                      className="hidden"
                      onChange={(e) => {
                        attachFiles(Array.from(e.target.files ?? []))
                        e.target.value = ''
                      }}
                    />
                  </div>
                  <span className="text-[11px] text-subtle">
                    Ctrl+V 粘贴 · 也可以把图拖进来
                  </span>
                </div>
              </div>
            </div>

            {images.length ? (
              <div>
                <div className="mb-2 flex items-baseline justify-between">
                  <span className="text-[13px] font-medium text-fg">图片</span>
                  <span className="text-[11px] text-subtle">
                    序号对应正文里的 [图N]
                  </span>
                </div>
                <div className="grid grid-cols-[repeat(auto-fill,minmax(92px,1fr))] gap-2">
                  {images.map((im, i) => (
                    <div
                      key={im.uid}
                      className="group relative aspect-square overflow-hidden rounded-lg border border-line bg-surface-2"
                    >
                      <img
                        src={im.preview}
                        alt=""
                        className={cn(
                          'size-full object-cover',
                          im.upload !== 'done' && 'opacity-40',
                        )}
                      />
                      <span className="absolute left-1 top-1 rounded bg-black/60 px-1.5 py-0.5 text-[10px] font-medium text-white">
                        {i + 1}
                      </span>

                      {im.upload === 'pending' ? (
                        <div className="absolute inset-0 flex items-center justify-center">
                          <Loader2 className="size-4 animate-spin text-white drop-shadow" />
                        </div>
                      ) : null}
                      {im.upload === 'failed' ? (
                        <button
                          type="button"
                          onClick={() => retry(im)}
                          className="absolute inset-0 flex flex-col items-center justify-center gap-1 bg-black/55 text-[10px] text-white"
                        >
                          <RotateCw className="size-4" />
                          重试
                        </button>
                      ) : null}

                      <button
                        type="button"
                        aria-label={`删除第 ${i + 1} 张图`}
                        onClick={() => removeImage(i)}
                        className="absolute right-1 top-1 flex size-5 items-center justify-center rounded bg-black/60 text-white opacity-0 transition-opacity hover:bg-black/80 group-hover:opacity-100"
                      >
                        <Trash2 className="size-3" />
                      </button>
                    </div>
                  ))}
                </div>
              </div>
            ) : null}

            {/* 附件与链接 */}
            <div className="flex flex-col gap-2">
              <div className="flex items-baseline justify-between">
                <label className="text-[13px] font-medium text-fg">
                  附件与链接
                </label>
                <span className="text-[11px] text-subtle">统一排在图片之后</span>
              </div>

              <div className="flex items-center gap-1">
                <Button
                  size="sm"
                  variant="ghost"
                  icon={<Paperclip className="size-3.5" />}
                  onClick={() => docRef.current?.click()}
                >
                  添加文件
                </Button>
                <Button
                  size="sm"
                  variant="ghost"
                  icon={<Link2 className="size-3.5" />}
                  onClick={() => setLinkOpen(true)}
                >
                  添加链接
                </Button>
                <input
                  ref={docRef}
                  type="file"
                  accept=".pdf,.docx,application/pdf,application/vnd.openxmlformats-officedocument.wordprocessingml.document"
                  multiple
                  className="hidden"
                  onChange={(e) => {
                    addDocuments(Array.from(e.target.files ?? []))
                    e.target.value = ''
                  }}
                />
              </div>

              {attachments.length ? (
                <div className="flex flex-col gap-1.5">
                  {attachments.map((a, i) => (
                    <div key={a.id} className="relative">
                      <AttachmentCard
                        attachment={a}
                        onRemove={() => removeAttachment(i)}
                      />
                      {a.upload === 'pending' ? (
                        <Loader2 className="absolute right-9 top-1/2 size-3.5 -translate-y-1/2 animate-spin text-subtle" />
                      ) : null}
                      {a.upload === 'failed' ? (
                        <button
                          type="button"
                          onClick={() => retryDoc(a)}
                          className="absolute right-9 top-1/2 -translate-y-1/2 rounded px-1.5 py-0.5 text-[11px] font-medium text-danger-fg hover:bg-danger-soft"
                        >
                          重试
                        </button>
                      ) : null}
                    </div>
                  ))}
                </div>
              ) : null}

              <span className="text-[11px] text-subtle">
                支持 PDF、DOCX（单个不超过 20 MB）和网页链接。附件排在图片下方，
                孩子点开时用手机上的应用打开。
              </span>
            </div>

            {pendingCount > 0 ? (
              <p className="flex items-center gap-1.5 text-[12px] text-warning-fg">
                <UploadCloud className="size-3.5" />
                还有 {pendingCount} 个文件正在上传，传完才能保存
              </p>
            ) : null}
          </div>
        </div>

        {/* 预览 */}
        <aside className="hidden w-[400px] shrink-0 overflow-y-auto border-l border-line bg-bg-soft px-5 py-6 xl:block">
          <div className="mb-3 flex items-center justify-between">
            <span className="text-[12.5px] font-medium text-muted">
              孩子会看到
            </span>
            <span className="text-[11px] text-subtle">与手机端同一套渲染</span>
          </div>
          <Card className="p-4">
            <div className="mb-3 flex items-center gap-2">
              <span
                className="rounded-md px-2 py-0.5 text-xs font-medium"
                style={{
                  color: subjectColor(finalSubject || subject),
                  backgroundColor: `${subjectColor(finalSubject || subject)}1f`,
                }}
              >
                {finalSubject || '未选'}
              </span>
              <span className="text-[11px] text-subtle">{friendlyDate(date)}</span>
            </div>
            <RichBodyView
              content={text || ''}
              imageKeys={previewKeys}
            />
            {attachments.length ? (
              <div className="mt-3">
                <AttachmentList attachments={attachments} compact />
              </div>
            ) : null}
            {!text.trim() && images.length === 0 && attachments.length === 0 ? (
              <p className="text-[13px] text-subtle">写完内容，这里会实时显示</p>
            ) : null}
          </Card>
          <p className="mt-3 leading-5 text-[11px] text-subtle">
            图片位置用 [图1] [图2] 这样的标记控制；标记写在哪儿，图就出现在哪儿。
            保存时会自动补上漏掉的标记。
          </p>
        </aside>
      </div>

      <Modal
        open={linkOpen}
        onClose={() => {
          if (!linkBusy) setLinkOpen(false)
        }}
        title="添加链接"
        description="粘贴网址，会自动抓取标题和站点信息；抓不到就只显示域名。"
        footer={
          <>
            <Button disabled={linkBusy} onClick={() => setLinkOpen(false)}>
              取消
            </Button>
            <Button
              variant="primary"
              loading={linkBusy}
              disabled={!linkUrl.trim()}
              onClick={() => void addLink()}
            >
              添加
            </Button>
          </>
        }
      >
        <Input
          value={linkUrl}
          onChange={(e) => setLinkUrl(e.target.value)}
          placeholder="https://…"
          autoFocus
          onKeyDown={(e) => {
            if (e.key === 'Enter' && !linkBusy) void addLink()
          }}
        />
      </Modal>

      <Modal
        open={confirmLeave}
        onClose={() => setConfirmLeave(false)}
        title="放弃这次编辑？"
        description="内容还没保存，离开就没了。"
        footer={
          <>
            <Button onClick={() => setConfirmLeave(false)}>继续编辑</Button>
            <Button
              variant="danger"
              onClick={() => {
                setConfirmLeave(false)
                onCancel()
              }}
            >
              放弃
            </Button>
          </>
        }
      />
    </>
  )
}
