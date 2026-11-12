package dev.srplayer.sr_player

import android.content.ContentUris
import android.graphics.Bitmap
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.provider.MediaStore
import android.util.Size
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    /// 缩略图抽帧在后台单线程串行执行，避免解码阻塞平台主线程造成掉帧。
    private val thumbExecutor = Executors.newSingleThreadExecutor()

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "sr_player/media")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "listVideos" -> {
                        try {
                            result.success(queryVideos())
                        } catch (e: Exception) {
                            result.error("LIST_FAILED", e.message, null)
                        }
                    }
                    "thumbnail" -> {
                        val path = call.argument<String>("path")
                        val contentUri = call.argument<String>("contentUri")
                        thumbExecutor.execute {
                            val bytes = try {
                                queryThumbnail(path, contentUri)
                            } catch (e: Exception) {
                                null
                            }
                            // MethodChannel 的 result 必须回到主线程回调。
                            runOnUiThread { result.success(bytes) }
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    /// 查询 MediaStore 视频库：路径、时长、大小、修改时间、宽高。
    private fun queryVideos(): List<Map<String, Any>> {
        val list = mutableListOf<Map<String, Any>>()
        val projection = arrayOf(
            MediaStore.Video.Media._ID,
            MediaStore.Video.Media.DISPLAY_NAME,
            MediaStore.Video.Media.DATA,
            MediaStore.Video.Media.DURATION,
            MediaStore.Video.Media.SIZE,
            MediaStore.Video.Media.DATE_MODIFIED,
            MediaStore.Video.Media.WIDTH,
            MediaStore.Video.Media.HEIGHT,
        )
        contentResolver.query(
            MediaStore.Video.Media.EXTERNAL_CONTENT_URI,
            projection, null, null,
            "${MediaStore.Video.Media.DATE_MODIFIED} DESC",
        )?.use { c ->
            val idIdx = c.getColumnIndexOrThrow(MediaStore.Video.Media._ID)
            val nameIdx = c.getColumnIndexOrThrow(MediaStore.Video.Media.DISPLAY_NAME)
            val pathIdx = c.getColumnIndexOrThrow(MediaStore.Video.Media.DATA)
            val durIdx = c.getColumnIndexOrThrow(MediaStore.Video.Media.DURATION)
            val sizeIdx = c.getColumnIndexOrThrow(MediaStore.Video.Media.SIZE)
            val modIdx = c.getColumnIndexOrThrow(MediaStore.Video.Media.DATE_MODIFIED)
            val wIdx = c.getColumnIndexOrThrow(MediaStore.Video.Media.WIDTH)
            val hIdx = c.getColumnIndexOrThrow(MediaStore.Video.Media.HEIGHT)
            while (c.moveToNext()) {
                val path = c.getString(pathIdx) ?: continue
                list.add(
                    mapOf(
                        "path" to path,
                        "name" to (c.getString(nameIdx) ?: path.substringAfterLast('/')),
                        "durationMs" to (c.getLong(durIdx)),
                        "sizeBytes" to (c.getLong(sizeIdx)),
                        "modifiedSec" to (c.getLong(modIdx)),
                        "width" to c.getInt(wIdx),
                        "height" to c.getInt(hIdx),
                        "contentUri" to ContentUris.withAppendedId(
                            MediaStore.Video.Media.EXTERNAL_CONTENT_URI, c.getLong(idIdx)
                        ).toString(),
                    )
                )
            }
        }
        return list
    }

    /// 取视频缩略图：优先 MediaStore 系统缓存，失败时用 MediaMetadataRetriever 抽帧。
    private fun queryThumbnail(path: String?, contentUri: String?): ByteArray? {
        var bmp: Bitmap? = null
        if (contentUri != null) {
            try {
                bmp = contentResolver.loadThumbnail(Uri.parse(contentUri), Size(512, 288), null)
            } catch (_: Exception) {}
        }
        if (bmp == null && path != null) {
            val mmr = MediaMetadataRetriever()
            try {
                mmr.setDataSource(path)
                bmp = mmr.getFrameAtTime(1_000_000, MediaMetadataRetriever.OPTION_CLOSEST_SYNC)
            } catch (_: Exception) {
            } finally {
                mmr.release()
            }
        }
        if (bmp == null) return null
        val out = ByteArrayOutputStream()
        bmp.compress(Bitmap.CompressFormat.JPEG, 70, out)
        bmp.recycle()
        return out.toByteArray()
    }
}
