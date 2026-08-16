package me.osholt.ride_relay

import android.os.Handler
import android.os.Looper
import com.google.firebase.messaging.FirebaseMessagingService
import io.flutter.plugin.common.MethodChannel

object NativePushBridge {
    @Volatile
    var channel: MethodChannel? = null

    @Volatile
    var pendingOpenedNotification: Map<String, String>? = null

    fun tokenRotated(token: String) {
        if (token.isEmpty()) return
        Handler(Looper.getMainLooper()).post {
            channel?.invokeMethod(
                "tokenRotated",
                mapOf(
                    "permission" to "granted",
                    "platform" to "android",
                    "provider" to "fcm",
                    "token" to token,
                ),
            )
        }
    }

    fun notificationOpened(value: Map<String, String>) {
        pendingOpenedNotification = value
        Handler(Looper.getMainLooper()).post {
            channel?.invokeMethod("notificationOpened", value)
        }
    }
}

class RideRelayMessagingService : FirebaseMessagingService() {
    override fun onNewToken(token: String) {
        super.onNewToken(token)
        NativePushBridge.tokenRotated(token)
    }
}
