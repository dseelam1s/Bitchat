package com.bitchat.bitchat_messenger

import android.bluetooth.*
import android.bluetooth.le.*
import android.content.Context
import android.os.ParcelUuid
import android.util.Log
import java.util.UUID

class BleGattService(private val context: Context) {

    companion object {
        private const val TAG = "BleGattService"
        val SERVICE_UUID: UUID = UUID.fromString("6e400001-b5a3-f393-e0a9-e50e24dcca9e")
        val WRITE_CHAR_UUID: UUID = UUID.fromString("6e400002-b5a3-f393-e0a9-e50e24dcca9e")
        val NOTIFY_CHAR_UUID: UUID = UUID.fromString("6e400003-b5a3-f393-e0a9-e50e24dcca9e")
        val CCCD_UUID: UUID = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")
    }

    private var bluetoothManager: BluetoothManager? = null
    private var gattServer: BluetoothGattServer? = null
    private var advertiser: BluetoothLeAdvertiser? = null
    private var isAdvertising = false
    private val connectedDevices = mutableSetOf<BluetoothDevice>()
    private var onMessageReceived: ((ByteArray, String) -> Unit)? = null
    private var onDeviceConnected: ((String) -> Unit)? = null
    private var onDeviceDisconnected: ((String) -> Unit)? = null

    fun setCallbacks(
        onMessage: (ByteArray, String) -> Unit,
        onConnected: (String) -> Unit,
        onDisconnected: (String) -> Unit
    ) {
        onMessageReceived = onMessage
        onDeviceConnected = onConnected
        onDeviceDisconnected = onDisconnected
    }

    fun start(): Boolean {
        bluetoothManager = context.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
        val adapter = bluetoothManager?.adapter ?: return false
        if (!adapter.isEnabled) return false

        advertiser = adapter.bluetoothLeAdvertiser ?: return false

        return try {
            startGattServer()
            startAdvertising()
            true
        } catch (e: SecurityException) {
            Log.e(TAG, "Permission denied: ${e.message}")
            false
        }
    }

    private fun startGattServer() {
        gattServer = bluetoothManager?.openGattServer(context, gattServerCallback)

        val service = BluetoothGattService(SERVICE_UUID, BluetoothGattService.SERVICE_TYPE_PRIMARY)

        // Characteristic for receiving messages (write from client)
        val writeChar = BluetoothGattCharacteristic(
            WRITE_CHAR_UUID,
            BluetoothGattCharacteristic.PROPERTY_WRITE or BluetoothGattCharacteristic.PROPERTY_WRITE_NO_RESPONSE,
            BluetoothGattCharacteristic.PERMISSION_WRITE
        )

        // Characteristic for sending messages (notify to client)
        val notifyChar = BluetoothGattCharacteristic(
            NOTIFY_CHAR_UUID,
            BluetoothGattCharacteristic.PROPERTY_NOTIFY or BluetoothGattCharacteristic.PROPERTY_READ,
            BluetoothGattCharacteristic.PERMISSION_READ
        )
        val cccd = BluetoothGattDescriptor(
            CCCD_UUID,
            BluetoothGattDescriptor.PERMISSION_WRITE or BluetoothGattDescriptor.PERMISSION_READ
        )
        notifyChar.addDescriptor(cccd)

        service.addCharacteristic(writeChar)
        service.addCharacteristic(notifyChar)

        gattServer?.addService(service)
    }

    private fun startAdvertising() {
        val settings = AdvertiseSettings.Builder()
            .setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_LOW_LATENCY)
            .setConnectable(true)
            .setTimeout(0)
            .setTxPowerLevel(AdvertiseSettings.ADVERTISE_TX_POWER_HIGH)
            .build()

        val data = AdvertiseData.Builder()
            .setIncludeDeviceName(false)
            .addServiceUuid(ParcelUuid(SERVICE_UUID))
            .build()

        try {
            advertiser?.startAdvertising(settings, data, advertiseCallback)
        } catch (e: SecurityException) {
            Log.e(TAG, "Advertise permission denied: ${e.message}")
        }
    }

    fun sendToAll(data: ByteArray) {
        val notifyChar = gattServer?.getService(SERVICE_UUID)
            ?.getCharacteristic(NOTIFY_CHAR_UUID) ?: return

        notifyChar.value = data
        for (device in connectedDevices.toList()) {
            try {
                gattServer?.notifyCharacteristicChanged(device, notifyChar, false)
            } catch (e: SecurityException) {
                Log.e(TAG, "Notify permission denied: ${e.message}")
            }
        }
    }

    fun stop() {
        try {
            if (isAdvertising) {
                advertiser?.stopAdvertising(advertiseCallback)
                isAdvertising = false
            }
            gattServer?.close()
            connectedDevices.clear()
        } catch (e: SecurityException) {
            Log.e(TAG, "Stop permission denied: ${e.message}")
        }
    }

    fun getConnectedAddresses(): List<String> {
        return connectedDevices.map { it.address }
    }

    private val advertiseCallback = object : AdvertiseCallback() {
        override fun onStartSuccess(settingsInEffect: AdvertiseSettings?) {
            isAdvertising = true
            Log.d(TAG, "BLE advertising started")
        }

        override fun onStartFailure(errorCode: Int) {
            isAdvertising = false
            Log.e(TAG, "BLE advertising failed: $errorCode")
        }
    }

    private val gattServerCallback = object : BluetoothGattServerCallback() {
        override fun onConnectionStateChange(device: BluetoothDevice, status: Int, newState: Int) {
            try {
                if (newState == BluetoothProfile.STATE_CONNECTED) {
                    connectedDevices.add(device)
                    onDeviceConnected?.invoke(device.address)
                } else if (newState == BluetoothProfile.STATE_DISCONNECTED) {
                    connectedDevices.remove(device)
                    onDeviceDisconnected?.invoke(device.address)
                }
            } catch (e: SecurityException) {
                Log.e(TAG, "Connection state permission denied: ${e.message}")
            }
        }

        override fun onCharacteristicWriteRequest(
            device: BluetoothDevice,
            requestId: Int,
            characteristic: BluetoothGattCharacteristic,
            preparedWrite: Boolean,
            responseNeeded: Boolean,
            offset: Int,
            value: ByteArray?
        ) {
            try {
                if (characteristic.uuid == WRITE_CHAR_UUID && value != null) {
                    onMessageReceived?.invoke(value, device.address)
                }
                if (responseNeeded) {
                    gattServer?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, 0, null)
                }
            } catch (e: SecurityException) {
                Log.e(TAG, "Write request permission denied: ${e.message}")
            }
        }

        override fun onDescriptorWriteRequest(
            device: BluetoothDevice,
            requestId: Int,
            descriptor: BluetoothGattDescriptor,
            preparedWrite: Boolean,
            responseNeeded: Boolean,
            offset: Int,
            value: ByteArray?
        ) {
            try {
                if (responseNeeded) {
                    gattServer?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, 0, null)
                }
            } catch (e: SecurityException) {
                Log.e(TAG, "Descriptor write permission denied: ${e.message}")
            }
        }
    }
}
