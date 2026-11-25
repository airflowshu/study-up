import { useState } from 'react'
import { parseBody } from '@/lib/richBody'
import { cn } from '@/lib/cn'
import { Lightbox, Thumb, type LightboxImage } from './image'

/**
 * 图文混排渲染。
 *
 * 解析规则与 Flutter 端 `rich_body.dart` / `rich_body_view.dart` 同一套：
 * 正文里的 `[图N]` 在原位置换成第 N 张图，紧挨着的多张图并成一组。
 * 孩子手机上看到什么，家长电脑上就预览到什么。
 */
export function RichBodyView({
  content,
  imageKeys,
  className,
  clamp,
}: {
  content: string
  imageKeys: string[]
  className?: string
  /** 列表摘要用：最多显示几行文字 */
  clamp?: number
}) {
  const [lightbox, setLightbox] = useState<number | null>(null)
  const blocks = parseBody(content, imageKeys.length)

  const images: LightboxImage[] = imageKeys
    .filter(Boolean)
    .map((key) => ({ key }))
  // 灯箱里的下标要按「剔掉空 key 之后」的顺序算
  const orderOf = new Map<string, number>()
  images.forEach((im, i) => orderOf.set(im.key, i))

  const open = (storageKey: string) => {
    const i = orderOf.get(storageKey)
    if (i !== undefined) setLightbox(i)
  }

  if (!blocks.length) {
    return (
      <p className={cn('text-[15px] leading-7 text-subtle', className)}>
        （这条作业没有正文）
      </p>
    )
  }

  return (
    <div className={cn('flex flex-col gap-3', className)}>
      {blocks.map((b, bi) => {
        if (b.kind === 'text') {
          return (
            <p
              key={`t${bi}`}
              className="whitespace-pre-wrap break-words text-[15px] leading-7 text-fg"
              style={
                clamp
                  ? {
                      display: '-webkit-box',
                      WebkitLineClamp: clamp,
                      WebkitBoxOrient: 'vertical',
                      overflow: 'hidden',
                    }
                  : undefined
              }
            >
              {b.text}
            </p>
          )
        }

        const n = b.images.length
        return (
          <div
            key={`i${bi}`}
            className={cn(
              'grid gap-2',
              n === 1 ? 'max-w-[320px] grid-cols-1' : '',
              n === 2 ? 'max-w-[420px] grid-cols-2' : '',
              n >= 3 ? 'grid-cols-2 sm:grid-cols-3' : '',
            )}
          >
            {b.images.map((idx) => {
              const key = imageKeys[idx - 1] ?? ''
              return (
                <Thumb
                  key={idx}
                  storageKey={key}
                  index={idx}
                  onOpen={() => open(key)}
                  className={n === 1 ? 'h-[200px] w-full' : 'aspect-[4/3] w-full'}
                />
              )
            })}
          </div>
        )
      })}

      {lightbox !== null ? (
        <Lightbox
          images={images}
          index={lightbox}
          onClose={() => setLightbox(null)}
          onChange={setLightbox}
        />
      ) : null}
    </div>
  )
}
