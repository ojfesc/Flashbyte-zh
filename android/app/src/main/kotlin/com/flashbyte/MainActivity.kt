package com.flashbyte

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.net.wifi.WifiManager
import android.os.PowerManager
import android.os.StatFs
import android.provider.OpenableColumns
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.net.NetworkInterface

class MainActivity : FlutterActivity() {
    private var pickDocumentsResult: MethodChannel.Result? = null
    private var sharedFilesSink: EventChannel.EventSink? = null
    private var initialShareConsumed = false

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "flashbyte/network_status"
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "isHotspotEnabled" -> result.success(isHotspotEnabled())
                else -> result.notImplemented()
            }
        }

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "flashbyte/battery_optimization"
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                // 是否已把本应用排除在电池优化之外；false 时后台连接会被系统冻结
                "isIgnoringBatteryOptimizations" -> result.success(
                    isIgnoringBatteryOptimizations()
                )
                // 打开本应用的系统“应用信息”页，用户在这里把省电策略改为“无限制”
                "openAppInfoSettings" -> {
                    openAppInfoSettings()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }

        // 文档选择与分享：只把 content:// URI 交给 Dart 侧，由传输层流式读取，
        // 不复制文件内容，因此文件多大都能选、都能收。
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "flashbyte/documents"
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "pickDocuments" -> pickDocuments(result)
                "takeInitialSharedFiles" -> result.success(
                    takeInitialSharedFiles()
                )
                "statUri" -> {
                    val uri = call.argument<String>("uri")
                    result.success(uri?.let { statContentUri(it) })
                }
                else -> result.notImplemented()
            }
        }

        EventChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "flashbyte/documents/shared"
        ).setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                sharedFilesSink = events
            }

            override fun onCancel(arguments: Any?) {
                sharedFilesSink = null
            }
        })

        // 传输期间的前台服务启停：Dart 侧在文件开始传输时调用 start，
        // 传输结束或连接断开时调用 stop。
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "flashbyte/foreground_service"
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> {
                    TransferForegroundService.start(applicationContext)
                    result.success(null)
                }
                "stop" -> {
                    TransferForegroundService.stop(applicationContext)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }

        // 接收前的空间预检：即使目标是 SAF 目录，数据也先写应用存储。
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "flashbyte/storage"
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "availableBytes" -> result.success(availableStorageBytes())
                else -> result.notImplemented()
            }
        }
    }

    /** 应用存储所在卷的可用字节数；读取失败返回 -1，Dart 侧按“未知”处理。 */
    private fun availableStorageBytes(): Long {
        return try {
            StatFs(applicationContext.filesDir.absolutePath).availableBytes
        } catch (_: Exception) {
            -1L
        }
    }

    private fun isIgnoringBatteryOptimizations(): Boolean {
        val powerManager = getSystemService(Context.POWER_SERVICE) as PowerManager
        return powerManager.isIgnoringBatteryOptimizations(packageName)
    }

    private fun openAppInfoSettings() {
        val intent = Intent(
            Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
            Uri.fromParts("package", packageName, null)
        )
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        startActivity(intent)
    }

    private fun isHotspotEnabled(): Boolean {
        return try {
            val wifiManager = applicationContext.getSystemService(
                Context.WIFI_SERVICE
            ) as WifiManager
            val method = wifiManager.javaClass.getDeclaredMethod("isWifiApEnabled")
            method.isAccessible = true
            method.invoke(wifiManager) as? Boolean ?: false
        } catch (_: Exception) {
            NetworkInterface.getNetworkInterfaces()?.toList()?.any { network ->
                network.isUp && (
                    network.name.startsWith("ap") ||
                        network.name.startsWith("swlan")
                    )
            } ?: false
        }
    }

    /** 打开系统文件选择器（可多选），返回选中文档的 URI 元数据。 */
    private fun pickDocuments(result: MethodChannel.Result) {
        if (pickDocumentsResult != null) {
            result.error("busy", "Another document pick is already running.", null)
            return
        }
        pickDocumentsResult = result
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "*/*"
            putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
            addFlags(
                Intent.FLAG_GRANT_READ_URI_PERMISSION or
                    Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION
            )
        }
        try {
            startActivityForResult(intent, PICK_DOCUMENTS_REQUEST)
        } catch (e: Exception) {
            pickDocumentsResult = null
            result.error("unavailable", e.message, null)
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode != PICK_DOCUMENTS_REQUEST) {
            super.onActivityResult(requestCode, resultCode, data)
            return
        }
        val result = pickDocumentsResult
        pickDocumentsResult = null
        if (result == null) {
            return
        }
        if (resultCode != Activity.RESULT_OK || data == null) {
            result.success(emptyList<Map<String, Any?>>())
            return
        }
        val uris = mutableListOf<Uri>()
        val clipData = data.clipData
        if (clipData != null) {
            for (index in 0 until clipData.itemCount) {
                clipData.getItemAt(index)?.uri?.let { uris.add(it) }
            }
        }
        data.data?.let { uris.add(it) }
        persistReadPermission(uris)
        result.success(describeUris(uris))
    }

    /** 首次启动时把“分享到 Flashbyte”带进来的文件交给 Dart 侧，只交一次。 */
    private fun takeInitialSharedFiles(): List<Map<String, Any?>> {
        if (initialShareConsumed) {
            return emptyList()
        }
        initialShareConsumed = true
        return sharedUrisFrom(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        val uris = sharedUrisFrom(intent)
        if (uris.isNotEmpty()) {
            sharedFilesSink?.success(uris)
        }
    }

    private fun sharedUrisFrom(intent: Intent?): List<Map<String, Any?>> {
        if (intent == null) {
            return emptyList()
        }
        val action = intent.action ?: return emptyList()
        if (action != Intent.ACTION_SEND && action != Intent.ACTION_SEND_MULTIPLE) {
            return emptyList()
        }

        val uris = linkedSetOf<Uri>()
        if (action == Intent.ACTION_SEND) {
            @Suppress("DEPRECATION")
            intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM)?.let { uris.add(it) }
        } else {
            @Suppress("DEPRECATION")
            intent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM)?.let {
                uris.addAll(it)
            }
        }
        // 有些应用只把 URI 放进 ClipData，不写 EXTRA_STREAM。
        intent.clipData?.let { clip ->
            for (index in 0 until clip.itemCount) {
                clip.getItemAt(index)?.uri?.let { uris.add(it) }
            }
        }
        intent.removeExtra(Intent.EXTRA_STREAM)

        if (uris.isEmpty()) {
            // 纯文本/链接分享：交给 Dart 侧按粘贴板内容处理。
            var text = intent.getCharSequenceExtra(Intent.EXTRA_TEXT)?.toString()
            if (text.isNullOrEmpty()) {
                // 有些应用只把文本放进 ClipData。
                val clip = intent.clipData
                if (clip != null) {
                    for (index in 0 until clip.itemCount) {
                        val value = clip.getItemAt(index)?.text?.toString()
                        if (!value.isNullOrEmpty()) {
                            text = value
                            break
                        }
                    }
                }
            }
            if (!text.isNullOrEmpty()) {
                return listOf(
                    mapOf(
                        "text" to text,
                        "clipboard" to true
                    )
                )
            }
            return emptyList()
        }

        val persisted = persistReadPermission(uris)
        return describeUris(uris.toList()).map { entry ->
            val map = entry.toMutableMap()
            val uri = entry["uri"] as? String
            map["persistable"] = uri != null && persisted.contains(uri)
            map
        }
    }

    /** 尝试把读权限持久化；返回成功的 URI，未成功的只在本次运行内可读。 */
    private fun persistReadPermission(uris: Collection<Uri>): Set<String> {
        val persisted = mutableSetOf<String>()
        for (uri in uris) {
            try {
                contentResolver.takePersistableUriPermission(
                    uri,
                    Intent.FLAG_GRANT_READ_URI_PERMISSION
                )
                persisted.add(uri.toString())
            } catch (_: Exception) {
                // 分享方没给可持久化权限时忽略。
            }
        }
        return persisted
    }

    /**
     * 分享来源不一定是 DocumentsProvider，SAF 的 stat 会失败；这里只依赖
     * OpenableColumns 取名字和大小，拿不到时再尝试打开资产文件描述符。
     */
    private fun statContentUri(uriString: String): Map<String, Any?>? {
        return try {
            val uri = Uri.parse(uriString)
            val entry = describeUris(listOf(uri)).firstOrNull() ?: return null

            // 优先用文件描述符的真实大小；content provider 的 SIZE 可能不可信。
            var size: Long? = try {
                contentResolver.openFileDescriptor(uri, "r")?.use { it.statSize }
            } catch (_: Exception) {
                null
            }
            if (size == null || size <= 0) {
                val providerSize = entry["size"] as? Long
                if (providerSize != null && providerSize >= 0) {
                    size = providerSize
                }
            }
            if (size == null || size <= 0) {
                size = try {
                    contentResolver.openAssetFileDescriptor(uri, "r")?.use { it.length }
                } catch (_: Exception) {
                    null
                }
            }
            if (size == null || size < 0) {
                return null
            }
            mapOf(
                "name" to (entry["name"] as? String ?: uri.lastPathSegment ?: "file"),
                "size" to size
            )
        } catch (_: Exception) {
            null
        }
    }

    /** 只查询显示名和大小，不读取文件内容。 */
    private fun describeUris(uris: List<Uri>): List<Map<String, Any?>> {
        return uris.map { uri ->
            var displayName: String? = null
            var size: Long? = null
            try {
                contentResolver.query(
                    uri,
                    arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE),
                    null,
                    null,
                    null
                )?.use { cursor ->
                    if (cursor.moveToFirst()) {
                        val nameIndex = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                        val sizeIndex = cursor.getColumnIndex(OpenableColumns.SIZE)
                        if (nameIndex >= 0 && !cursor.isNull(nameIndex)) {
                            displayName = cursor.getString(nameIndex)
                        }
                        if (sizeIndex >= 0 && !cursor.isNull(sizeIndex)) {
                            size = cursor.getLong(sizeIndex)
                        }
                    }
                }
            } catch (_: Exception) {
                // 查询失败时只用 URI 的末段作名字
            }
            mapOf(
                "name" to (displayName ?: uri.lastPathSegment ?: "file"),
                "uri" to uri.toString(),
                "size" to size
            )
        }
    }

    companion object {
        private const val PICK_DOCUMENTS_REQUEST = 0x51D0
    }
}
