package com.deepakpal.flutter_blekit

import android.Manifest
import android.annotation.SuppressLint
import android.app.Activity
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.bluetooth.BluetoothStatusCodes
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanFilter
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.ParcelUuid
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.PluginRegistry
import java.util.UUID

/**
 * Android host for flutter_blekit. All Bluetooth callbacks are marshalled onto
 * the main thread, which also serialises access to the plugin's state.
 *
 * Permission checks: every Bluetooth call site is guarded by [hasPermissions]
 * (via [requireReady]/[gattOf]), so `MissingPermission` lint is suppressed at
 * class level rather than on each line.
 */
@SuppressLint("MissingPermission")
class FlutterBlekitPlugin :
  FlutterPlugin,
  ActivityAware,
  BleHostApi,
  PluginRegistry.RequestPermissionsResultListener {

  private lateinit var context: Context
  private lateinit var flutterApi: BleFlutterApi
  private val main = Handler(Looper.getMainLooper())
  private var adapter: BluetoothAdapter? = null

  private var activityBinding: ActivityPluginBinding? = null
  private var pendingPermission: ((Result<Boolean>) -> Unit)? = null

  private var scanCallback: ScanCallback? = null
  private val devices = mutableMapOf<String, BluetoothDevice>()
  private val names = mutableMapOf<String, String>()
  private val sessions = mutableMapOf<String, GattSession>()

  // region FlutterPlugin / ActivityAware

  override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    context = binding.applicationContext
    adapter = (context.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager)?.adapter
    flutterApi = BleFlutterApi(binding.binaryMessenger)
    BleHostApi.setUp(binding.binaryMessenger, this)
    val filter = IntentFilter(BluetoothAdapter.ACTION_STATE_CHANGED)
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
      // System broadcast; must be exported to be received on API 33+.
      context.registerReceiver(stateReceiver, filter, Context.RECEIVER_EXPORTED)
    } else {
      context.registerReceiver(stateReceiver, filter)
    }
  }

  override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    BleHostApi.setUp(binding.binaryMessenger, null)
    runCatching { context.unregisterReceiver(stateReceiver) }
    stopScanInternal()
    sessions.values.toList().forEach { it.close(null) }
    sessions.clear()
  }

  override fun onAttachedToActivity(binding: ActivityPluginBinding) {
    activityBinding = binding
    binding.addRequestPermissionsResultListener(this)
  }

  override fun onDetachedFromActivityForConfigChanges() = onDetachedFromActivity()

  override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) =
    onAttachedToActivity(binding)

  override fun onDetachedFromActivity() {
    activityBinding?.removeRequestPermissionsResultListener(this)
    activityBinding = null
  }

  // endregion

  // region State

  private val stateReceiver = object : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
      if (intent.action != BluetoothAdapter.ACTION_STATE_CHANGED) return
      val state = currentState()
      if (state != BleManagerStateMessage.POWERED_ON) {
        stopScanInternal()
        // The stack drops every link when the radio goes down.
        sessions.values.toList().forEach {
          it.close(BleErrorMessage(BleErrorCodeMessage.BLUETOOTH_UNAVAILABLE, managerState = state))
        }
      }
      flutterApi.onManagerStateChanged(state) {}
    }
  }

  private fun currentState(): BleManagerStateMessage {
    val a = adapter ?: return BleManagerStateMessage.UNSUPPORTED
    if (!context.packageManager.hasSystemFeature(PackageManager.FEATURE_BLUETOOTH_LE)) {
      return BleManagerStateMessage.UNSUPPORTED
    }
    if (!hasPermissions()) return BleManagerStateMessage.UNAUTHORIZED
    return when (a.state) {
      BluetoothAdapter.STATE_ON -> BleManagerStateMessage.POWERED_ON
      BluetoothAdapter.STATE_OFF -> BleManagerStateMessage.POWERED_OFF
      BluetoothAdapter.STATE_TURNING_ON, BluetoothAdapter.STATE_TURNING_OFF ->
        BleManagerStateMessage.RESETTING
      else -> BleManagerStateMessage.UNKNOWN
    }
  }

  private fun requiredPermissions(): Array<String> =
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
      arrayOf(Manifest.permission.BLUETOOTH_SCAN, Manifest.permission.BLUETOOTH_CONNECT)
    } else {
      arrayOf(Manifest.permission.ACCESS_FINE_LOCATION)
    }

  private fun hasPermissions(): Boolean = requiredPermissions().all {
    context.checkSelfPermission(it) == PackageManager.PERMISSION_GRANTED
  }

  /** Throws a `bluetoothUnavailable` error unless the radio is usable. */
  private fun requireReady(): BluetoothAdapter {
    val state = currentState()
    val a = adapter
    if (state != BleManagerStateMessage.POWERED_ON || a == null) {
      throw FlutterError("bluetoothUnavailable", stateName(state))
    }
    return a
  }

  // endregion

  // region BleHostApi: central

  override fun getState(): BleManagerStateMessage = currentState()

  override fun requestPermissions(callback: (Result<Boolean>) -> Unit) {
    if (hasPermissions()) return callback(Result.success(true))
    val activity: Activity = activityBinding?.activity
      ?: return callback(Result.failure(FlutterError("underlying", "No activity to request permissions from")))
    pendingPermission?.invoke(Result.success(false))
    pendingPermission = callback
    activity.requestPermissions(requiredPermissions(), PERMISSION_REQUEST_CODE)
  }

  override fun onRequestPermissionsResult(
    requestCode: Int,
    permissions: Array<out String>,
    grantResults: IntArray,
  ): Boolean {
    if (requestCode != PERMISSION_REQUEST_CODE) return false
    val granted = grantResults.isNotEmpty() && grantResults.all { it == PackageManager.PERMISSION_GRANTED }
    pendingPermission?.invoke(Result.success(granted))
    pendingPermission = null
    flutterApi.onManagerStateChanged(currentState()) {}
    return true
  }

  override fun startScan(serviceUuids: List<String>?) {
    val scanner = requireReady().bluetoothLeScanner
      ?: throw FlutterError("bluetoothUnavailable", stateName(currentState()))
    stopScanInternal()
    val filters = serviceUuids?.map {
      ScanFilter.Builder().setServiceUuid(ParcelUuid(toUuid(it))).build()
    }
    val settings = ScanSettings.Builder().setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY).build()
    val callback = object : ScanCallback() {
      override fun onScanResult(callbackType: Int, result: ScanResult) = onScan(result)
      override fun onBatchScanResults(results: MutableList<ScanResult>) = results.forEach(::onScan)
      override fun onScanFailed(errorCode: Int) {
        scanCallback = null
      }
    }
    scanCallback = callback
    scanner.startScan(filters, settings, callback)
  }

  private fun onScan(result: ScanResult) {
    val device = result.device
    val id = device.address
    devices[id] = device
    val record = result.scanRecord
    val localName = record?.deviceName
    val name = runCatching { device.name }.getOrNull() ?: localName
    if (name != null) names[id] = name
    val manufacturer = record?.manufacturerSpecificData?.let { data ->
      if (data.size() == 0) null else {
        // CoreBluetooth convention: 2-byte little-endian company id, then payload.
        val company = data.keyAt(0)
        byteArrayOf((company and 0xFF).toByte(), (company shr 8 and 0xFF).toByte()) + data.valueAt(0)
      }
    }
    val connectable = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) result.isConnectable else true
    val message = DiscoveryMessage(
      peripheralId = id,
      peripheralName = name,
      advertisement = AdvertisementDataMessage(
        localName = localName,
        serviceUuids = record?.serviceUuids?.map { it.uuid.toString() } ?: emptyList(),
        manufacturerData = manufacturer,
        isConnectable = connectable,
      ),
      rssi = result.rssi.toLong(),
    )
    main.post { flutterApi.onDiscovery(message) {} }
  }

  override fun stopScan() = stopScanInternal()

  private fun stopScanInternal() {
    val callback = scanCallback ?: return
    scanCallback = null
    if (adapter?.isEnabled == true && hasPermissions()) {
      runCatching { adapter?.bluetoothLeScanner?.stopScan(callback) }
    }
  }

  override fun retrievePeripheral(identifier: String, callback: (Result<PeripheralInfoMessage?>) -> Unit) {
    val a = adapter
    if (a == null || !BluetoothAdapter.checkBluetoothAddress(identifier)) {
      return callback(Result.success(null))
    }
    val device = devices.getOrPut(identifier) { a.getRemoteDevice(identifier) }
    val name = names[identifier] ?: if (hasPermissions()) runCatching { device.name }.getOrNull() else null
    callback(Result.success(PeripheralInfoMessage(identifier, name)))
  }

  override fun connect(peripheralId: String, timeoutMs: Long?, callback: (Result<Unit>) -> Unit) {
    val a = try { requireReady() } catch (e: FlutterError) { return callback(Result.failure(e)) }
    val device = devices[peripheralId]
      ?: if (BluetoothAdapter.checkBluetoothAddress(peripheralId)) a.getRemoteDevice(peripheralId) else null
    if (device == null) return callback(Result.failure(FlutterError("peripheralNotFound", peripheralId)))
    devices[peripheralId] = device
    sessions.remove(peripheralId)?.close(null, notify = false)
    val session = GattSession(peripheralId, device)
    sessions[peripheralId] = session
    session.connect(timeoutMs ?: DEFAULT_CONNECT_TIMEOUT_MS, callback)
  }

  override fun disconnect(peripheralId: String, callback: (Result<Unit>) -> Unit) {
    val session = sessions[peripheralId] ?: return callback(Result.success(Unit))
    session.disconnect(callback)
  }

  override fun peripheralName(peripheralId: String, callback: (Result<String?>) -> Unit) {
    val device = devices[peripheralId]
    val name = (if (device != null && hasPermissions()) runCatching { device.name }.getOrNull() else null)
      ?: names[peripheralId]
    callback(Result.success(name))
  }

  // endregion

  // region BleHostApi: GATT

  private fun gattOf(peripheralId: String): GattSession {
    val session = sessions[peripheralId]
    if (session == null || !session.isConnected) throw FlutterError("disconnected", "Not connected")
    if (!hasPermissions()) throw FlutterError("bluetoothUnavailable", stateName(BleManagerStateMessage.UNAUTHORIZED))
    return session
  }

  private inline fun <T> guarded(callback: (Result<T>) -> Unit, body: () -> Unit) {
    try {
      body()
    } catch (e: FlutterError) {
      callback(Result.failure(e))
    }
  }

  override fun discoverServices(
    peripheralId: String,
    serviceUuids: List<String>?,
    callback: (Result<List<String>>) -> Unit,
  ) = guarded(callback) {
    val session = gattOf(peripheralId)
    session.discover { result ->
      callback(result.map { services ->
        val wanted = serviceUuids?.map(::toUuid)?.toSet()
        services.map { it.uuid }.filter { wanted == null || it in wanted }.map { it.toString() }
      })
    }
  }

  override fun discoverCharacteristics(
    peripheralId: String,
    serviceUuid: String,
    characteristicUuids: List<String>?,
    callback: (Result<List<String>>) -> Unit,
  ) = guarded(callback) {
    val session = gattOf(peripheralId)
    session.discover { result ->
      callback(result.mapCatching { services ->
        val service = services.firstOrNull { it.uuid == toUuid(serviceUuid) }
          ?: throw FlutterError("serviceNotFound", serviceUuid)
        val wanted = characteristicUuids?.map(::toUuid)?.toSet()
        service.characteristics.map { it.uuid }.filter { wanted == null || it in wanted }.map { it.toString() }
      })
    }
  }

  override fun readValue(peripheralId: String, characteristicUuid: String, callback: (Result<ByteArray>) -> Unit) =
    guarded(callback) {
      val session = gattOf(peripheralId)
      val c = session.characteristic(characteristicUuid)
      session.enqueue(Op.Read(c, callback))
    }

  override fun writeValue(
    peripheralId: String,
    characteristicUuid: String,
    value: ByteArray,
    withResponse: Boolean,
    callback: (Result<Unit>) -> Unit,
  ) = guarded(callback) {
    val session = gattOf(peripheralId)
    val c = session.characteristic(characteristicUuid)
    session.enqueue(Op.Write(c, value, withResponse, callback))
  }

  override fun setNotify(
    peripheralId: String,
    characteristicUuid: String,
    enabled: Boolean,
    callback: (Result<Unit>) -> Unit,
  ) = guarded(callback) {
    val session = gattOf(peripheralId)
    val c = session.characteristic(characteristicUuid)
    session.enqueue(Op.Notify(c, enabled, callback))
  }

  override fun requestMtu(peripheralId: String, mtu: Long, callback: (Result<Long>) -> Unit) =
    guarded(callback) {
      gattOf(peripheralId).enqueue(Op.Mtu(mtu.toInt().coerceIn(23, 517), callback))
    }

  // endregion

  /** One queued GATT operation; Android allows only one in flight per link. */
  private sealed class Op {
    abstract fun fail(error: Throwable)

    class Read(val c: BluetoothGattCharacteristic, val cb: (Result<ByteArray>) -> Unit) : Op() {
      override fun fail(error: Throwable) = cb(Result.failure(error))
    }

    class Write(
      val c: BluetoothGattCharacteristic,
      val value: ByteArray,
      val withResponse: Boolean,
      val cb: (Result<Unit>) -> Unit,
    ) : Op() {
      override fun fail(error: Throwable) = cb(Result.failure(error))
    }

    class Notify(val c: BluetoothGattCharacteristic, val enabled: Boolean, val cb: (Result<Unit>) -> Unit) : Op() {
      override fun fail(error: Throwable) = cb(Result.failure(error))
    }

    class Mtu(val mtu: Int, val cb: (Result<Long>) -> Unit) : Op() {
      override fun fail(error: Throwable) = cb(Result.failure(error))
    }

    class Discover(val cb: (Result<List<android.bluetooth.BluetoothGattService>>) -> Unit) : Op() {
      override fun fail(error: Throwable) = cb(Result.failure(error))
    }
  }

  /** A single peripheral link: connection lifecycle plus a serial op queue. */
  private inner class GattSession(val id: String, val device: BluetoothDevice) {
    private var gatt: BluetoothGatt? = null
    private var connectCallback: ((Result<Unit>) -> Unit)? = null
    private var disconnectCallback: ((Result<Unit>) -> Unit)? = null
    private var timeout: Runnable? = null
    private var retries = 0
    private var expectedDisconnect = false
    private val queue = ArrayDeque<Op>()
    private var current: Op? = null
    private var discovered: List<android.bluetooth.BluetoothGattService>? = null
    var isConnected = false
      private set

    fun connect(timeoutMs: Long, callback: (Result<Unit>) -> Unit) {
      connectCallback = callback
      retries = 0
      val t = Runnable {
        connectCallback?.let { cb ->
          connectCallback = null
          teardown()
          sessions.remove(id)
          cb(Result.failure(FlutterError("connectionTimeout")))
        }
      }
      timeout = t
      main.postDelayed(t, timeoutMs)
      open()
    }

    private fun open() {
      gatt = device.connectGatt(context, false, gattCallback, BluetoothDevice.TRANSPORT_LE)
    }

    fun disconnect(callback: (Result<Unit>) -> Unit) {
      expectedDisconnect = true
      val g = gatt
      if (g == null || !isConnected) {
        // Still connecting (or already gone): cancel and report completion.
        connectCallback?.invoke(Result.failure(FlutterError("cancelled")))
        connectCallback = null
        close(null, notify = false)
        sessions.remove(id)
        return callback(Result.success(Unit))
      }
      disconnectCallback = callback
      g.disconnect()
    }

    fun characteristic(uuid: String): BluetoothGattCharacteristic {
      val target = toUuid(uuid)
      return gatt?.services?.firstNotNullOfOrNull { s -> s.characteristics.firstOrNull { it.uuid == target } }
        ?: throw FlutterError("characteristicNotFound", uuid)
    }

    fun discover(cb: (Result<List<android.bluetooth.BluetoothGattService>>) -> Unit) {
      val cached = discovered
      if (cached != null) cb(Result.success(cached)) else enqueue(Op.Discover(cb))
    }

    fun enqueue(op: Op) {
      queue.addLast(op)
      pump()
    }

    private fun pump() {
      if (current != null) return
      val g = gatt ?: return
      val op = queue.removeFirstOrNull() ?: return
      current = op
      val started = when (op) {
        is Op.Discover -> g.discoverServices()
        is Op.Read -> g.readCharacteristic(op.c)
        is Op.Write -> write(g, op)
        is Op.Notify -> notify(g, op)
        is Op.Mtu -> g.requestMtu(op.mtu)
      }
      if (!started) finish { it.fail(FlutterError("underlying", "GATT operation could not be started")) }
    }

    @Suppress("DEPRECATION")
    private fun write(g: BluetoothGatt, op: Op.Write): Boolean {
      val type = if (op.withResponse) {
        BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT
      } else {
        BluetoothGattCharacteristic.WRITE_TYPE_NO_RESPONSE
      }
      return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
        g.writeCharacteristic(op.c, op.value, type) == BluetoothStatusCodes.SUCCESS
      } else {
        op.c.writeType = type
        op.c.value = op.value
        g.writeCharacteristic(op.c)
      }
    }

    @Suppress("DEPRECATION")
    private fun notify(g: BluetoothGatt, op: Op.Notify): Boolean {
      if (!g.setCharacteristicNotification(op.c, op.enabled)) return false
      val cccd = op.c.getDescriptor(CCCD) ?: run {
        // No CCCD: local enablement is all we can do.
        main.post { finish { op.cb(Result.success(Unit)) } }
        return true
      }
      val value = when {
        !op.enabled -> BluetoothGattDescriptor.DISABLE_NOTIFICATION_VALUE
        op.c.properties and BluetoothGattCharacteristic.PROPERTY_NOTIFY != 0 ->
          BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
        else -> BluetoothGattDescriptor.ENABLE_INDICATION_VALUE
      }
      return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
        g.writeDescriptor(cccd, value) == BluetoothStatusCodes.SUCCESS
      } else {
        cccd.value = value
        g.writeDescriptor(cccd)
      }
    }

    /** Completes the in-flight op and starts the next one. */
    private fun finish(complete: (Op) -> Unit) {
      val op = current ?: return
      current = null
      complete(op)
      pump()
    }

    private fun teardown() {
      timeout?.let(main::removeCallbacks)
      timeout = null
      isConnected = false
      discovered = null
      gatt?.close()
      gatt = null
      val error = FlutterError("disconnected", "Disconnected")
      current?.fail(error)
      current = null
      while (queue.isNotEmpty()) queue.removeFirst().fail(error)
    }

    /** Tears the link down; optionally reports the drop to Dart. */
    fun close(error: BleErrorMessage?, notify: Boolean = true) {
      val wasConnected = isConnected
      connectCallback?.invoke(
        Result.failure(FlutterError(error?.let { codeName(it.code) } ?: "cancelled", error?.message)),
      )
      connectCallback = null
      teardown()
      if (notify && wasConnected) {
        flutterApi.onDisconnection(DisconnectionMessage(id, error)) {}
      }
    }

    private val gattCallback = object : BluetoothGattCallback() {
      override fun onConnectionStateChange(g: BluetoothGatt, status: Int, newState: Int) = main.post {
        if (gatt !== g) return@post
        if (newState == BluetoothProfile.STATE_CONNECTED && status == BluetoothGatt.GATT_SUCCESS) {
          timeout?.let(main::removeCallbacks)
          timeout = null
          isConnected = true
          connectCallback?.invoke(Result.success(Unit))
          connectCallback = null
          return@post
        }
        if (newState != BluetoothProfile.STATE_DISCONNECTED && status == BluetoothGatt.GATT_SUCCESS) return@post

        // Status 133 (GATT_ERROR) on a fresh connect is a well-known transient
        // Android stack failure; retry once before giving up.
        val pending = connectCallback
        if (pending != null && status == GATT_ERROR_133 && retries < 1) {
          retries++
          g.close()
          gatt = null
          main.postDelayed({ if (connectCallback != null) open() }, 250)
          return@post
        }
        val wasConnected = isConnected
        val expected = expectedDisconnect
        teardown()
        sessions.remove(id)
        if (pending != null) {
          connectCallback = null
          pending(Result.failure(FlutterError("underlying", "Connection failed (GATT status $status)")))
        }
        disconnectCallback?.invoke(Result.success(Unit))
        disconnectCallback = null
        if (wasConnected) {
          val error = if (expected) {
            null
          } else {
            BleErrorMessage(
              code = BleErrorCodeMessage.DISCONNECTED,
              message = "GATT status $status",
              isExpectedDisconnect = false,
            )
          }
          flutterApi.onDisconnection(DisconnectionMessage(id, error)) {}
        }
      }.let {}

      override fun onServicesDiscovered(g: BluetoothGatt, status: Int) = main.post {
        finish { op ->
          if (op !is Op.Discover) return@finish op.fail(FlutterError("underlying", "Unexpected discovery result"))
          if (status == BluetoothGatt.GATT_SUCCESS) {
            discovered = g.services
            op.cb(Result.success(g.services))
          } else {
            op.cb(Result.failure(FlutterError("underlying", "Service discovery failed (GATT status $status)")))
          }
        }
      }.let {}

      // API 33+ delivers the value as an argument.
      override fun onCharacteristicRead(
        g: BluetoothGatt,
        c: BluetoothGattCharacteristic,
        value: ByteArray,
        status: Int,
      ) = onRead(status, value)

      @Suppress("DEPRECATION", "OVERRIDE_DEPRECATION")
      override fun onCharacteristicRead(g: BluetoothGatt, c: BluetoothGattCharacteristic, status: Int) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) onRead(status, c.value ?: ByteArray(0))
      }

      private fun onRead(status: Int, value: ByteArray) {
        val copy = value.copyOf()
        main.post {
          finish { op ->
            val read = op as? Op.Read ?: return@finish op.fail(FlutterError("underlying", "Unexpected read"))
            read.cb(
              if (status == BluetoothGatt.GATT_SUCCESS) Result.success(copy)
              else Result.failure(FlutterError("underlying", "Read failed (GATT status $status)")),
            )
          }
        }
      }

      override fun onCharacteristicWrite(g: BluetoothGatt, c: BluetoothGattCharacteristic, status: Int) =
        main.post {
          finish { op ->
            val write = op as? Op.Write ?: return@finish op.fail(FlutterError("underlying", "Unexpected write"))
            write.cb(
              if (status == BluetoothGatt.GATT_SUCCESS) Result.success(Unit)
              else Result.failure(FlutterError("underlying", "Write failed (GATT status $status)")),
            )
          }
        }.let {}

      override fun onDescriptorWrite(g: BluetoothGatt, d: BluetoothGattDescriptor, status: Int) = main.post {
        finish { op ->
          val n = op as? Op.Notify ?: return@finish op.fail(FlutterError("underlying", "Unexpected descriptor write"))
          n.cb(
            if (status == BluetoothGatt.GATT_SUCCESS) Result.success(Unit)
            else Result.failure(FlutterError("underlying", "Notification setup failed (GATT status $status)")),
          )
        }
      }.let {}

      override fun onMtuChanged(g: BluetoothGatt, mtu: Int, status: Int) = main.post {
        finish { op ->
          val m = op as? Op.Mtu ?: return@finish
          m.cb(
            if (status == BluetoothGatt.GATT_SUCCESS) Result.success(mtu.toLong())
            else Result.failure(FlutterError("underlying", "MTU request failed (GATT status $status)")),
          )
        }
      }.let {}

      // API 33+ delivers the value as an argument.
      override fun onCharacteristicChanged(g: BluetoothGatt, c: BluetoothGattCharacteristic, value: ByteArray) =
        onChanged(c.uuid, value)

      @Suppress("DEPRECATION", "OVERRIDE_DEPRECATION")
      override fun onCharacteristicChanged(g: BluetoothGatt, c: BluetoothGattCharacteristic) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) onChanged(c.uuid, c.value ?: ByteArray(0))
      }

      private fun onChanged(uuid: UUID, value: ByteArray) {
        val message = NotificationMessage(id, uuid.toString(), value.copyOf())
        main.post { flutterApi.onNotificationValue(message) {} }
      }
    }
  }

  private companion object {
    const val PERMISSION_REQUEST_CODE = 0xB1E
    const val DEFAULT_CONNECT_TIMEOUT_MS = 10_000L
    const val GATT_ERROR_133 = 133
    val CCCD: UUID = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")

    /** Expands 16/32-bit short UUIDs onto the Bluetooth Base UUID. */
    fun toUuid(raw: String): UUID {
      val s = raw.trim()
      return when (s.length) {
        4 -> UUID.fromString("0000$s-0000-1000-8000-00805f9b34fb")
        8 -> UUID.fromString("$s-0000-1000-8000-00805f9b34fb")
        else -> UUID.fromString(s)
      }
    }

    /** Dart enum case name, as `bleErrorFromPlatform` expects. */
    fun stateName(s: BleManagerStateMessage) = when (s) {
      BleManagerStateMessage.UNKNOWN -> "unknown"
      BleManagerStateMessage.RESETTING -> "resetting"
      BleManagerStateMessage.UNSUPPORTED -> "unsupported"
      BleManagerStateMessage.UNAUTHORIZED -> "unauthorized"
      BleManagerStateMessage.POWERED_OFF -> "poweredOff"
      BleManagerStateMessage.POWERED_ON -> "poweredOn"
    }

    fun codeName(c: BleErrorCodeMessage) = when (c) {
      BleErrorCodeMessage.BLUETOOTH_UNAVAILABLE -> "bluetoothUnavailable"
      BleErrorCodeMessage.CONNECTION_TIMEOUT -> "connectionTimeout"
      BleErrorCodeMessage.DISCONNECTED -> "disconnected"
      BleErrorCodeMessage.PERIPHERAL_NOT_FOUND -> "peripheralNotFound"
      BleErrorCodeMessage.SERVICE_NOT_FOUND -> "serviceNotFound"
      BleErrorCodeMessage.CHARACTERISTIC_NOT_FOUND -> "characteristicNotFound"
      BleErrorCodeMessage.RECONNECTION_EXHAUSTED -> "reconnectionExhausted"
      BleErrorCodeMessage.CANCELLED -> "cancelled"
      BleErrorCodeMessage.UNDERLYING -> "underlying"
    }
  }
}
