package com.shuge.homework_app

import android.content.ClipboardManager
import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream
import java.util.UUID
import java.util.concurrent.Executors
import kotlin.math.max

/**
 * 剪贴板桥接。
 *
 * Flutter 自带的 Clipboard 只认纯文本；Android 上「复制多张图片」放进剪贴板的是
 * 若干 content:// URI，Dart 侧完全看不到。这里补两条通道：
 *  - peek   轻量探查（不落盘、不解码），用于「剪贴板里有 N 张图片」提示与去重
 *  - import 真正读取 → 按长边压缩 → 写进缓存目录，返回本地路径
 *
 * 压缩放在原生层做：剪贴板里的原图往往是几 MB 的截图，先压到长边 1600 再交给
 * Flutter 上传，既快又不卡主线程。
 */
class MainActivity : FlutterActivity() {
    private val channelName = "com.shuge.homework_app/clipboard"
    private val worker = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())

    private val imgSrcRegex =
        Regex("""<img[^>]+src\s*=\s*["']([^"']+)["']""", RegexOption.IGNORE_CASE)

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "peek" -> result.success(peekClipboard())
                    "import" -> {
                        val uris = call.argument<List<String>>("uris")
                        val maxSide = call.argument<Int>("maxSide") ?: 1600
                        val quality = call.argument<Int>("quality") ?: 85
                        val targets = if (!uris.isNullOrEmpty()) uris else collectImageUris()
                        worker.execute {
                            val saved = try {
                                importImages(targets, maxSide, quality)
                            } catch (e: Throwable) {
                                emptyList<String>()
                            }
                            main.post { result.success(saved) }
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    // ---------------- 探查 ----------------

    private fun peekClipboard(): Map<String, Any> {
        val blank = mapOf(
            "hasImages" to false,
            "imageCount" to 0,
            "fingerprint" to "",
            "hasText" to false,
            "text" to "",
            "uris" to emptyList<String>(),
            "ageMs" to Long.MAX_VALUE,
            "html" to "",
        )
        val cm = getSystemService(Context.CLIPBOARD_SERVICE) as? ClipboardManager ?: return blank
        val clip = cm.primaryClip ?: return blank
        if (clip.itemCount == 0) return blank

        val texts = ArrayList<String>()
        val rawUris = ArrayList<String>()
        val htmlUris = ArrayList<String>()
        val htmls = ArrayList<String>()

        for (i in 0 until clip.itemCount) {
            val item = clip.getItemAt(i) ?: continue
            // 纯文本项：也可能本身就是一段 content:// 地址（某些文件管理器这么复制）
            val t = item.text?.toString()
            if (!t.isNullOrBlank()) {
                if (t.startsWith("content://") || t.startsWith("file://")) {
                    rawUris.add(t.trim())
                } else {
                    texts.add(t)
                }
            }
            item.htmlText?.toString()?.let { html ->
                htmls.add(html)
                for (m in imgSrcRegex.findAll(html)) {
                    htmlUris.add(m.groupValues[1])
                }
            }
            item.uri?.toString()?.let { rawUris.add(it) }
        }

        val imageUris = rawUris.distinct().filter { isImageUri(it) }
        val finalUris = if (imageUris.isNotEmpty()) {
            imageUris
        } else {
            htmlUris.distinct().filter { isImageUri(it) }
        }

        val text = texts.joinToString("\n")
        val ts = try {
            clip.description.timestamp
        } catch (e: Throwable) {
            0L
        }
        val ageMs = if (ts <= 0) Long.MAX_VALUE else (System.currentTimeMillis() - ts).coerceAtLeast(0L)
        val fingerprint = "$ts|${clip.itemCount}|${finalUris.joinToString(",")}|${text.length}|${text.hashCode()}"

        return mapOf(
            "hasImages" to finalUris.isNotEmpty(),
            "imageCount" to finalUris.size,
            "fingerprint" to fingerprint,
            "hasText" to text.isNotBlank(),
            "text" to text,
            "uris" to finalUris,
            "ageMs" to ageMs,
            "html" to htmls.joinToString("\n<!--SPLIT-->\n"),
        )
    }

    private fun collectImageUris(): List<String> {
        val cm = getSystemService(Context.CLIPBOARD_SERVICE) as? ClipboardManager ?: return emptyList()
        val clip = cm.primaryClip ?: return emptyList()
        val raw = ArrayList<String>()
        for (i in 0 until clip.itemCount) {
            val item = clip.getItemAt(i) ?: continue
            item.uri?.toString()?.let { raw.add(it) }
            item.text?.toString()?.takeIf {
                it.startsWith("content://") || it.startsWith("file://")
            }?.let { raw.add(it.trim()) }
            item.htmlText?.toString()?.let { html ->
                imgSrcRegex.findAll(html).forEach { raw.add(it.groupValues[1]) }
            }
        }
        return raw.distinct().filter { isImageUri(it) }
    }

    private fun isImageUri(raw: String): Boolean {
        return try {
            val uri = Uri.parse(raw)
            when (uri.scheme) {
                "content" -> {
                    val type = contentResolver.getType(uri)
                    if (!type.isNullOrEmpty()) {
                        type.startsWith("image/")
                    } else {
                        looksLikeImageFile(uri.path ?: "")
                    }
                }
                "file" -> looksLikeImageFile(uri.path ?: "")
                else -> false
            }
        } catch (e: Throwable) {
            false
        }
    }

    private fun looksLikeImageFile(path: String): Boolean {
        val p = path.lowercase()
        return p.endsWith(".jpg") || p.endsWith(".jpeg") || p.endsWith(".png") ||
            p.endsWith(".webp") || p.endsWith(".heic") || p.endsWith(".bmp")
    }

    // ---------------- 导入 ----------------

    private fun importImages(uris: List<String>, maxSide: Int, quality: Int): List<String> {
        val dir = File(cacheDir, "clip_images")
        if (!dir.exists()) dir.mkdirs()
        cleanOldFiles(dir)
        val out = ArrayList<String>()
        for (raw in uris) {
            val saved = try {
                saveOne(raw, dir, maxSide, quality)
            } catch (e: Throwable) {
                android.util.Log.e("ClipImport", "fail $raw", e)
                null
            }
            if (saved != null) out.add(saved)
        }
        return out
    }

    private fun saveOne(raw: String, dir: File, maxSide: Int, quality: Int): String? {
        val uri = Uri.parse(raw)
        val decoded = decodeSampled(uri, maxSide) ?: return null
        val target = if (max(decoded.width, decoded.height) > maxSide) {
            scaleTo(decoded, maxSide)
        } else {
            decoded
        }
        val file = File(dir, UUID.randomUUID().toString() + ".jpg")
        FileOutputStream(file).use { fos ->
            target.compress(Bitmap.CompressFormat.JPEG, quality, fos)
        }
        if (target !== decoded) target.recycle()
        decoded.recycle()
        return if (file.length() > 0L) file.absolutePath else null
    }

    private fun decodeSampled(uri: Uri, maxSide: Int): Bitmap? {
        // 注意：inJustDecodeBounds 时 decodeStream 本来就返回 null，只负责回填宽高。
        // 这里必须分开判断「流打不开」和「解析结果」，否则每张图都会当成失败。
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        val boundStream = contentResolver.openInputStream(uri) ?: return null
        boundStream.use { BitmapFactory.decodeStream(it, null, bounds) }
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null

        var sample = 1
        while (max(bounds.outWidth, bounds.outHeight) / (sample * 2) >= maxSide) {
            sample *= 2
        }
        val opts = BitmapFactory.Options().apply { inSampleSize = sample }
        val pixelStream = contentResolver.openInputStream(uri) ?: return null
        return pixelStream.use { BitmapFactory.decodeStream(it, null, opts) }
    }

    private fun scaleTo(src: Bitmap, maxSide: Int): Bitmap {
        val ratio = maxSide.toFloat() / max(src.width, src.height)
        val w = (src.width * ratio).toInt().coerceAtLeast(1)
        val h = (src.height * ratio).toInt().coerceAtLeast(1)
        return Bitmap.createScaledBitmap(src, w, h, true)
    }

    private fun cleanOldFiles(dir: File) {
        val cutoff = System.currentTimeMillis() - 3L * 24 * 3600 * 1000
        dir.listFiles()?.forEach { f ->
            if (f.isFile && f.lastModified() < cutoff) f.delete()
        }
    }
}
