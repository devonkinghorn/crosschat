package app.crosschat.crosschat

import android.Manifest
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.ImageDecoder
import android.os.Build
import android.os.Handler
import android.os.Looper
import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // Decode images Flutter can't (HEIC/HEIF) with the platform decoder; returns JPEG.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "app.crosschat/image")
            .setMethodCallHandler { call, result ->
                if (call.method != "toJpeg") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                val bytes = call.argument<ByteArray>("bytes")
                val maxDimension = call.argument<Int>("maxDimension") ?: 2048
                if (bytes == null) {
                    result.error("bad_args", "no bytes", null)
                    return@setMethodCallHandler
                }
                Thread {
                    val jpeg = try { toJpeg(bytes, maxDimension) } catch (e: Exception) { null }
                    Handler(Looper.getMainLooper()).post {
                        if (jpeg != null) result.success(jpeg) else result.error("decode_failed", "Couldn't decode the image", null)
                    }
                }.start()
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "app.crosschat/sync_service")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "start" -> {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
                            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
                        ) {
                            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 1)
                        }
                        SyncService.start(this)
                        result.success(true)
                    }
                    "stop" -> {
                        SyncService.stop(this)
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun toJpeg(bytes: ByteArray, maxDimension: Int): ByteArray? {
        val bitmap: Bitmap = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            ImageDecoder.decodeBitmap(ImageDecoder.createSource(ByteBuffer.wrap(bytes))) { decoder, info, _ ->
                val w = info.size.width
                val h = info.size.height
                val scale = minOf(1.0, maxDimension.toDouble() / maxOf(w, h))
                decoder.setTargetSize(maxOf(1, (w * scale).toInt()), maxOf(1, (h * scale).toInt()))
            }
        } else {
            BitmapFactory.decodeByteArray(bytes, 0, bytes.size) ?: return null
        }
        val out = ByteArrayOutputStream()
        bitmap.compress(Bitmap.CompressFormat.JPEG, 88, out)
        return out.toByteArray()
    }
}
