package com.flashbyte

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.IBinder

/**
 * 传输期间的前台服务。
 *
 * 没有前台服务时，Android 可以在应用不可见后冻结或回收进程，即使已经获得电池
 * 优化豁免。服务只在有文件真正开始传输时启动，传输结束或连接断开时停止。
 */
class TransferForegroundService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        return try {
            createChannel()
            startForeground(NOTIFICATION_ID, buildNotification())
            START_NOT_STICKY
        } catch (_: Exception) {
            // 系统拒绝启动前台服务（例如后台启动限制）时直接退出，不影响传输逻辑。
            stopSelf()
            START_NOT_STICKY
        }
    }

    override fun onDestroy() {
        @Suppress("DEPRECATION")
        stopForeground(true)
        super.onDestroy()
    }

    private fun createChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            return
        }
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (manager.getNotificationChannel(CHANNEL_ID) != null) {
            return
        }
        val channel = NotificationChannel(
            CHANNEL_ID,
            getString(R.string.transfer_service_channel_name),
            // 传输进度另有通知；这里只满足前台服务的前台通知要求，尽量不打扰。
            NotificationManager.IMPORTANCE_MIN
        )
        channel.setShowBadge(false)
        manager.createNotificationChannel(channel)
    }

    private fun buildNotification(): Notification {
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        return builder
            .setContentTitle(getString(R.string.transfer_service_title))
            .setContentText(getString(R.string.transfer_service_text))
            .setSmallIcon(R.drawable.ic_notification)
            .setOngoing(true)
            .build()
    }

    companion object {
        private const val CHANNEL_ID = "flashbyte_transfer_service"
        private const val NOTIFICATION_ID = 8060

        fun start(context: Context) {
            try {
                val intent = Intent(context, TransferForegroundService::class.java)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    context.startForegroundService(intent)
                } else {
                    context.startService(intent)
                }
            } catch (_: Exception) {
                // 后台启动受限等情况下忽略：普通通知仍然会显示传输状态。
            }
        }

        fun stop(context: Context) {
            try {
                context.stopService(Intent(context, TransferForegroundService::class.java))
            } catch (_: Exception) {
                // 服务已经不存在时忽略。
            }
        }
    }
}
