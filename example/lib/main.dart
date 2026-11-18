import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_blekit/flutter_blekit.dart';
import 'package:flutter_blekit/testing.dart';

void main() => runApp(const BleKitDemoApp());

/// Heart-rate + battery monitor demo. "Simulated" mode runs entirely on
/// [MockBleCentral], so it works on emulators without Bluetooth.
class BleKitDemoApp extends StatelessWidget {
  const BleKitDemoApp({super.key, this.startSimulated = true});

  final bool startSimulated;

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'flutter_blekit demo',
    theme: ThemeData(colorSchemeSeed: Colors.red, useMaterial3: true),
    home: ScanScreen(startSimulated: startSimulated),
  );
}

/// Owns the simulated central and the fake HRM it advertises.
class Simulator {
  Simulator() {
    central.add(device);
  }

  final MockBleCentral central = MockBleCentral();
  final SimulatedPeripheral device = SimulatedPeripheral(
    identifier: 'SIM-HRM-0001',
    name: 'Simulated HRM',
    services: {
      BleUuid.heartRate: [BleUuid.heartRateMeasurement],
      BleUuid.batteryService: [BleUuid.batteryLevel],
    },
    values: {
      BleUuid.batteryLevel: Uint8List.fromList([87]),
    },
  );

  Timer? _advertiser;
  Timer? _heartbeat;
  final math.Random _random = math.Random();

  /// Advertises the HRM ~1s after scanning starts.
  void startAdvertising() {
    _advertiser?.cancel();
    _advertiser = Timer(const Duration(seconds: 1), () {
      central.simulateDiscovery(
        device,
        advertisement: AdvertisementData(
          localName: 'Simulated HRM',
          serviceUuids: [BleUuid.heartRate],
          isConnectable: true,
        ),
        rssi: -58,
      );
    });
  }

  void stopAdvertising() => _advertiser?.cancel();

  /// Pushes a heart-rate measurement (uint8 bpm + one RR interval) every 1s.
  void startHeartbeat() {
    _heartbeat ??= Timer.periodic(const Duration(seconds: 1), (_) {
      if (!central.isConnected(device.identifier)) return;
      final bpm = 68 + _random.nextInt(10);
      final rr = (60 / bpm * 1024).round(); // 1/1024 s units
      device.simulateValue(
        Uint8List.fromList([0x10, bpm, rr & 0xFF, rr >> 8]),
        BleUuid.heartRateMeasurement,
      );
    });
  }

  void stopHeartbeat() {
    _heartbeat?.cancel();
    _heartbeat = null;
  }

  void dispose() {
    stopAdvertising();
    stopHeartbeat();
  }
}

class ScanScreen extends StatefulWidget {
  const ScanScreen({super.key, this.startSimulated = true});

  final bool startSimulated;

  @override
  State<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends State<ScanScreen> {
  late bool _simulated = widget.startSimulated;
  Simulator? _simulator;
  LiveBleCentral? _live;
  StreamSubscription<BleDiscovery>? _scan;
  StreamSubscription<BleManagerState>? _stateSub;
  BleManagerState _managerState = BleManagerState.unknown;
  final Map<String, BleDiscovery> _found = {};
  final Map<String, String> _names = {};
  bool _scanning = false;
  String? _error;

  BleCentral get _central => _simulated
      ? (_simulator ??= Simulator()).central
      : (_live ??= LiveBleCentral());

  @override
  void initState() {
    super.initState();
    _watchState();
  }

  void _watchState() {
    _stateSub?.cancel();
    _stateSub = _central.stateUpdates().listen(
      (s) => setState(() => _managerState = s),
      onError: (Object e) => setState(() => _error = '$e'),
    );
  }

  Future<void> _startScan() async {
    await _stopScan();
    setState(() {
      _found.clear();
      _error = null;
    });
    if (!_simulated) {
      final granted = await _live!.requestPermissions();
      if (!granted) {
        setState(() => _error = 'Bluetooth permissions denied');
        return;
      }
    }
    setState(() => _scanning = true);
    _scan = _central
        .scan(services: [BleUuid.heartRate])
        .listen(
          (d) async {
            final name = await d.peripheral.name ?? d.advertisement.localName;
            if (!mounted) return;
            setState(() {
              _found[d.peripheral.identifier] = d;
              if (name != null) _names[d.peripheral.identifier] = name;
            });
          },
          onError: (Object e) => setState(() {
            _error = '$e';
            _scanning = false;
          }),
          onDone: () => setState(() => _scanning = false),
        );
    if (_simulated) _simulator!.startAdvertising();
  }

  Future<void> _stopScan() async {
    _simulator?.stopAdvertising();
    await _scan?.cancel();
    _scan = null;
    await _central.stopScan();
    if (mounted) setState(() => _scanning = false);
  }

  Future<void> _setSimulated(bool value) async {
    await _stopScan();
    setState(() {
      _simulated = value;
      _found.clear();
      _managerState = BleManagerState.unknown;
    });
    _watchState();
  }

  Future<void> _open(BleDiscovery d) async {
    await _stopScan();
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => DeviceScreen(
          central: _central,
          peripheral: d.peripheral,
          name: _names[d.peripheral.identifier] ?? d.peripheral.identifier,
          simulator: _simulated ? _simulator : null,
        ),
      ),
    );
  }

  @override
  void dispose() {
    _scan?.cancel();
    _stateSub?.cancel();
    _simulator?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('flutter_blekit demo')),
      body: Column(
        children: [
          SwitchListTile(
            key: const Key('simulatedSwitch'),
            title: const Text('Simulated'),
            subtitle: Text('Bluetooth: ${_managerState.name}'),
            value: _simulated,
            onChanged: _setSimulated,
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.all(8),
              child: Text(_error!, style: const TextStyle(color: Colors.red)),
            ),
          if (_scanning) const LinearProgressIndicator(),
          Expanded(
            child: ListView(
              children: [
                for (final d in _found.values)
                  ListTile(
                    leading: const Icon(Icons.favorite),
                    title: Text(
                      _names[d.peripheral.identifier] ??
                          d.peripheral.identifier,
                    ),
                    subtitle: Text('${d.peripheral.identifier}  ${d.rssi} dBm'),
                    trailing: const Text('Connect'),
                    onTap: () => _open(d),
                  ),
              ],
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _scanning ? _stopScan : _startScan,
        icon: Icon(_scanning ? Icons.stop : Icons.search),
        label: Text(_scanning ? 'Stop' : 'Scan'),
      ),
    );
  }
}

class DeviceScreen extends StatefulWidget {
  const DeviceScreen({
    super.key,
    required this.central,
    required this.peripheral,
    required this.name,
    this.simulator,
  });

  final BleCentral central;
  final BlePeripheral peripheral;
  final String name;
  final Simulator? simulator;

  @override
  State<DeviceScreen> createState() => _DeviceScreenState();
}

class _DeviceScreenState extends State<DeviceScreen> {
  late final ConnectionCoordinator _coordinator = ConnectionCoordinator(
    central: widget.central,
    peripheral: widget.peripheral,
  );
  StreamSubscription<BleConnectionState>? _states;
  GattSession? _session;
  BleConnectionState _state = BleConnectionState.disconnected;
  HeartRateMeasurement? _hr;
  int? _battery;
  String? _gattError;

  @override
  void initState() {
    super.initState();
    _states = _coordinator.states().listen(_onState);
    _coordinator.start();
  }

  void _onState(BleConnectionState s) {
    debugPrint('[blekit-demo] state: $s');
    if (!mounted) return;
    setState(() => _state = s);
    if (s == BleConnectionState.connected) {
      unawaited(_attach());
    } else {
      unawaited(_detach());
    }
  }

  Future<void> _attach() async {
    await _detach();
    try {
      final session = await widget.peripheral.attach(
        GattProfile([
          StandardProfile.heartRate((m) {
            debugPrint(
              '[blekit-demo] bpm=${m.beatsPerMinute} rr=${m.rrIntervals}',
            );
            if (mounted) setState(() => _hr = m);
          }),
          service(BleUuid.batteryService, [
            characteristic(BleUuid.batteryLevel)
                .readAs(BatteryLevel.fromBytes, _onBattery)
                .notifyAs(BatteryLevel.fromBytes, _onBattery),
          ]),
        ]),
      );
      if (!mounted || _state != BleConnectionState.connected) {
        await session.cancel();
        return;
      }
      _session = session;
      widget.simulator?.startHeartbeat();
      setState(() => _gattError = null);
    } on BleError catch (e) {
      debugPrint('[blekit-demo] attach failed: $e');
      if (mounted) setState(() => _gattError = '$e');
    }
  }

  void _onBattery(BatteryLevel level) {
    debugPrint('[blekit-demo] battery=${level.percent}%');
    if (mounted) setState(() => _battery = level.percent);
  }

  Future<void> _detach() async {
    final session = _session;
    _session = null;
    await session?.cancel();
  }

  Future<void> _disconnect() async {
    await _detach();
    widget.simulator?.stopHeartbeat();
    await _coordinator.stop();
    if (mounted) Navigator.of(context).pop();
  }

  @override
  void dispose() {
    _states?.cancel();
    widget.simulator?.stopHeartbeat();
    unawaited(_detach());
    unawaited(_coordinator.stop());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hr = _hr;
    final rr = hr?.rrIntervals
        .map((s) => '${(s * 1000).round()} ms')
        .join(', ');
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_disconnect());
      },
      child: Scaffold(
        appBar: AppBar(title: Text(widget.name)),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text('State: $_state', key: const Key('stateText')),
            const SizedBox(height: 24),
            Text(
              hr == null ? '-- bpm' : '${hr.beatsPerMinute} bpm',
              style: Theme.of(context).textTheme.displayMedium,
            ),
            Text('RR: ${rr == null || rr.isEmpty ? '--' : rr}'),
            const SizedBox(height: 16),
            Text('Battery: ${_battery == null ? '--' : '$_battery%'}'),
            if (_gattError != null)
              Text(_gattError!, style: const TextStyle(color: Colors.red)),
            const SizedBox(height: 24),
            if (widget.simulator != null)
              OutlinedButton(
                onPressed: _state == BleConnectionState.connected
                    ? () => widget.simulator!.central.simulateDisconnect(
                        widget.simulator!.device,
                      )
                    : null,
                child: const Text('Simulate drop'),
              ),
            const SizedBox(height: 8),
            FilledButton(
              onPressed: _disconnect,
              child: const Text('Disconnect'),
            ),
          ],
        ),
      ),
    );
  }
}
