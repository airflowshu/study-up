/**
 * 上传前压缩图像。
 *
 * 实测背景（2026-11-10）：
 *   - 隧道落地在 LAX（洛杉矶），跨太平洋，上行只有 30-100KB/s；
 *   - 已经被压过的图（微信截图、聊天图片）重编码几乎不省体积，
 *     2275x1280 的 JPEG 以 q0.85 重编码反而从 489KB 涨到 528KB；
 *   - 只有「手机原照」这类 3-6MB 的图才真的有压缩空间（4-8 倍）。
 *
 * 所以这里的策略是**只对大图动手**，小图原样上传：
 *   - 阈值 1.5MB：低于它的图重编码纯属有损无益；
 *   - 长边上限 2400px：手机屏幕物理宽度一般 1080px，2400px 留了 2 倍余量；
 *   - PNG 源质量 0.90（截图/文字，压狠了文字边缘会出噪点）；
 *   - GIF 不压（重编码会丢帧）；
 *   - 压完反而更大、或任何一步失败，都回退原图——压缩是优化，
 *     不能变成上传失败或画质下降的原因。
 */

/** 低于这个体积就原样上传。这是本文件最重要的一个数。 */
const SKIP_BYTES = 1536 * 1024

/** 长边上限。手机屏幕物理宽度一般 1080px，2400px 留了 2 倍余量。 */
const MAX_EDGE = 2400

/** PNG 多是截图/文字，压太狠会出现文字边缘噪点，质量给高。 */
const QUALITY_PNG = 0.9
const QUALITY_OTHER = 0.85

function isGif(blob: Blob): boolean {
  return blob.type.toLowerCase().includes('gif')
}

async function decode(blob: Blob): Promise<{ width: number; height: number; draw: CanvasImageSource; release: () => void }> {
  // createImageBitmap 在主流浏览器都支持，比 <img> 少一次解码
  if (typeof createImageBitmap === 'function') {
    const bmp = await createImageBitmap(blob)
    return { width: bmp.width, height: bmp.height, draw: bmp, release: () => bmp.close() }
  }
  const url = URL.createObjectURL(blob)
  try {
    const img = await new Promise<HTMLImageElement>((resolve, reject) => {
      const el = new Image()
      el.onload = () => resolve(el)
      el.onerror = () => reject(new Error('图片解码失败'))
      el.src = url
    })
    return {
      width: img.naturalWidth,
      height: img.naturalHeight,
      draw: img,
      release: () => URL.revokeObjectURL(url),
    }
  } catch (e) {
    URL.revokeObjectURL(url)
    throw e
  }
}

function toBlob(canvas: HTMLCanvasElement, quality: number): Promise<Blob | null> {
  return new Promise((resolve) => canvas.toBlob((b) => resolve(b), 'image/jpeg', quality))
}

export async function compressImage(input: Blob): Promise<Blob> {
  if (isGif(input)) return input
  if (!input.type.startsWith('image/')) return input

  let src: Awaited<ReturnType<typeof decode>> | null = null
  try {
    src = await decode(input)

    const longEdge = Math.max(src.width, src.height)
    const scale = longEdge > MAX_EDGE ? MAX_EDGE / longEdge : 1

    // 没超长边、体积也不大，原图直传。这条挡住了对普通截图的无效重编码。
    if (scale === 1 && input.size <= SKIP_BYTES) return input

    const w = Math.max(1, Math.round(src.width * scale))
    const h = Math.max(1, Math.round(src.height * scale))

    const canvas = document.createElement('canvas')
    canvas.width = w
    canvas.height = h
    const ctx = canvas.getContext('2d')
    if (!ctx) return input
    // 缩小图像要开高质量插值，否则细文字会发虚
    ctx.imageSmoothingEnabled = true
    ctx.imageSmoothingQuality = 'high'
    // JPEG 没有透明通道，先铺白底，避免 PNG 透明区变黑
    ctx.fillStyle = '#fff'
    ctx.fillRect(0, 0, w, h)
    ctx.drawImage(src.draw, 0, 0, w, h)

    const quality = input.type.toLowerCase().includes('png') ? QUALITY_PNG : QUALITY_OTHER
    const out = await toBlob(canvas, quality)
    if (!out) return input

    // 压完更大就没意义了
    if (out.size >= input.size) return input

    return new File([out], 'image.jpg', { type: 'image/jpeg', lastModified: Date.now() })
  } catch {
    return input
  } finally {
    src?.release()
  }
}
