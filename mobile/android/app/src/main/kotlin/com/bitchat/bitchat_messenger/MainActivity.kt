package com.bitchat.bitchat_messenger

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.EventChannel

class MainActivity : FlutterActivity() {
    private val METHOD_CHANNEL = "com.bitchat/ble_gatt"
    private val EVENT_CHANNEL = "com.bitchat/ble_gatt_events"
    private val FOREGROUND_CHANNEL = "com.bitchat/foreground"
    private var gattService: BleGattService? = null
    private var eventSink: EventChannel.EventSink? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        gattService = BleGattService(this)
        gattService?.setCallbacks(
            onMessage = { data, address ->
                runOnUiThread {
                    eventSink?.success(mapOf(
                        "type" to "message",
                        "data" to data.toList(),
                        "address" to address
                    ))
                }
            },
            onConnected = { address ->
                runOnUiThread {
                    eventSink?.success(mapOf(
                        "type" to "connected",
                        "address" to address
                    ))
                }
            },
            onDisconnected = { address ->
                runOnUiThread {
                    eventSink?.success(mapOf(
                        "type" to "disconnected",
                        "address" to address
                    ))
                }
            }
        )

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, METHOD_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "start" -> {
                        val success = gattService?.start() ?: false
                        result.success(success)
                    }
                    "stop" -> {
                        gattService?.stop()
                        result.success(true)
                    }
                    "sendToAll" -> {
                        val data = call.argument<List<Int>>("data")
                        if (data != null) {
                            gattService?.sendToAll(data.map { it.toByte() }.toByteArray())
                            result.success(true)
                        } else {
                            result.error("INVALID_DATA", "No data provided", null)
                        }
                    }
                    "getConnectedDevices" -> {
                        result.success(gattService?.getConnectedAddresses() ?: emptyList<String>())
                    }
                    else -> result.notImplemented()
                }
            }

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, EVENT_CHANNEL)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    eventSink = events
                }
                override fun onCancel(arguments: Any?) {
                    eventSink = null
                }
            })

        // Foreground service control — keeps BLE mesh alive when screen is locked
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, FOREGROUND_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "start" -> {
                        MeshForegroundService.start(this)
                        result.success(true)
                    }
                    "stop" -> {
                        MeshForegroundService.stop(this)
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    override fun onDestroy() {
        gattService?.stop()
        super.onDestroy()
    }
}
