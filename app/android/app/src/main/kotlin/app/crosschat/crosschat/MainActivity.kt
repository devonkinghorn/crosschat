package app.crosschat.crosschat

import android.Manifest
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.ImageDecoder
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.ContactsContract
import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val contactsRequestCode = 42
    private val pendingContactRequests = mutableListOf<MethodChannel.Result>()

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // New-chat contact picker: READ_CONTACTS (asked once; the app works without it).
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "app.crosschat/contacts")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "status" -> result.success(contactsStatus())
                    "request" -> {
                        if (contactsStatus() == "granted") {
                            result.success("granted")
                        } else {
                            pendingContactRequests.add(result)
                            if (pendingContactRequests.size == 1) {
                                requestPermissions(arrayOf(Manifest.permission.READ_CONTACTS), contactsRequestCode)
                            }
                        }
                    }
                    "list" -> {
                        if (contactsStatus() != "granted") {
                            result.success(emptyList<Map<String, Any>>())
                        } else {
                            Thread {
                                val out = try { readContacts() } catch (e: Exception) { emptyList() }
                                Handler(Looper.getMainLooper()).post { result.success(out) }
                            }.start()
                        }
                    }
                    else -> result.notImplemented()
                }
            }
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

    private fun contactsStatus(): String =
        if (checkSelfPermission(Manifest.permission.READ_CONTACTS) == PackageManager.PERMISSION_GRANTED) "granted"
        else if (getSharedPreferences("crosschat", MODE_PRIVATE).getBoolean("contacts_asked", false)) "denied"
        else "not_determined"

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != contactsRequestCode) return
        getSharedPreferences("crosschat", MODE_PRIVATE).edit().putBoolean("contacts_asked", true).apply()
        val status = contactsStatus()
        pendingContactRequests.forEach { it.success(status) }
        pendingContactRequests.clear()
    }

    /** id, name, phones, emails for every contact with a number or email. */
    private fun readContacts(): List<Map<String, Any>> {
        data class C(val name: String, val phones: MutableList<String> = mutableListOf(), val emails: MutableList<String> = mutableListOf())
        val byId = LinkedHashMap<String, C>()
        val projection = arrayOf(
            ContactsContract.Data.CONTACT_ID,
            ContactsContract.Data.DISPLAY_NAME_PRIMARY,
            ContactsContract.Data.MIMETYPE,
            ContactsContract.Data.DATA1,
        )
        val selection = "${ContactsContract.Data.MIMETYPE} IN (?, ?)"
        val args = arrayOf(
            ContactsContract.CommonDataKinds.Phone.CONTENT_ITEM_TYPE,
            ContactsContract.CommonDataKinds.Email.CONTENT_ITEM_TYPE,
        )
        contentResolver.query(ContactsContract.Data.CONTENT_URI, projection, selection, args, null)?.use { c ->
            while (c.moveToNext()) {
                val id = c.getString(0) ?: continue
                val value = c.getString(3) ?: continue
                val entry = byId.getOrPut(id) { C(c.getString(1) ?: "") }
                if (c.getString(2) == ContactsContract.CommonDataKinds.Phone.CONTENT_ITEM_TYPE) entry.phones.add(value) else entry.emails.add(value)
            }
        }
        return byId.map { (id, c) -> mapOf("id" to id, "name" to c.name, "phones" to c.phones, "emails" to c.emails) }
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
