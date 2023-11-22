import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // if your terminal doesn't support color you'll see annoying logs like `\x1B[1;35m`
  FlutterBluePlus.setLogLevel(LogLevel.verbose, color: false);
  // first, check if bluetooth is supported by your hardware
  // Note: The platform is initialized on the first call to any FlutterBluePlus method.
  if (await FlutterBluePlus.isSupported == false) {
    if (kDebugMode) {
      print("Bluetooth not supported by this device");
    }
    return;
  }
  runApp(const ProviderScope(child: MainApp()));
}

/// Stream of bluetooth devices
/// This stream will emit a list of bluetooth devices every time a new device is discovered.
final bluetoothDevicesProvider = StreamProvider<List<BluetoothDevice>>((ref) {
  return FlutterBluePlus.scanResults.map((event) => event.map((e) => e.device).toList());
});

class MainApp extends ConsumerWidget {
  const MainApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData.light(useMaterial3: true),
      home: const HomeApp(),
    );
  }
}

class HomeApp extends ConsumerStatefulWidget {
  const HomeApp({super.key});

  @override
  ConsumerState<ConsumerStatefulWidget> createState() => _HomeAppState();
}

class _HomeAppState extends ConsumerState<HomeApp> {
  /// Wether the bluetooth device is on or off
  ValueNotifier<bool> bluetoothOn = ValueNotifier(false);

  /// Controller to programatically control the map
  /// Used for zooming and panning
  late final MapController mapController;

  /// List of markers to be added in the map
  /// Would be programatically updated by the bluetooth device connected
  final ValueNotifier<List<LatLng>> markers = ValueNotifier([]);

  @override
  void initState() {
    mapController = MapController();
    super.initState();
  }

  @override
  void didChangeDependencies() {
    FlutterBluePlus.adapterState.listen((event) {
      bluetoothOn.value = event == BluetoothAdapterState.on;
    });
    super.didChangeDependencies();
  }

  @override
  void dispose() {
    mapController.dispose();
    bluetoothOn.dispose();
    markers.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('BattleField Test'),
        actions: [
          ValueListenableBuilder(
              valueListenable: bluetoothOn,
              builder: (context, value, _) {
                return IconButton(
                    icon: Icon(value ? Icons.bluetooth : Icons.bluetooth_disabled),
                    onPressed: () async {
                      if (Platform.isAndroid) {
                        if (!value) FlutterBluePlus.turnOn();
                      }
                    });
              })
        ],
      ),
      drawer: Drawer(
        semanticLabel: 'Bluetooth Device Scanner',
        child: Column(
          mainAxisAlignment: MainAxisAlignment.start,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            StreamBuilder<bool>(
                stream: FlutterBluePlus.isScanning,
                builder: (context, snapshot) {
                  return DrawerHeader(
                    child: Row(
                      children: [
                        Flexible(
                            child: Text(snapshot.hasData && snapshot.data!
                                ? 'Scanning for Bluetooth Devices...'
                                : 'Press Button to start scanning')),
                        IconButton.filledTonal(
                            onPressed: () {
                              if (!bluetoothOn.value) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                    content: Text('Please Turn on Bluetooth'),
                                    showCloseIcon: true,
                                    behavior: SnackBarBehavior.floating,
                                  ),
                                );
                                return;
                              }
                              if (!FlutterBluePlus.isScanningNow) {
                                FlutterBluePlus.startScan(continuousUpdates: true);
                              }
                            },
                            icon: Icon(snapshot.hasData && snapshot.data! ? Icons.refresh : Icons.add))
                      ],
                    ),
                  );
                }),
            ref.watch(bluetoothDevicesProvider).when(
                data: (data) {
                  return Expanded(
                    child: ListView(
                      children: data
                          .map((e) => ListTile(
                                title: Text(e.platformName),
                                subtitle: Text(e.remoteId.str),
                                onTap: () {
                                  e.connect(autoConnect: true).onError((error, stackTrace) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(
                                        content: Text(error.toString()),
                                        showCloseIcon: true,
                                        behavior: SnackBarBehavior.floating,
                                      ),
                                    );
                                  }).then((value) => ScaffoldMessenger.of(context).showSnackBar(
                                        SnackBar(
                                          content: Text('Connected to ${e.platformName}'),
                                          showCloseIcon: true,
                                          behavior: SnackBarBehavior.floating,
                                        ),
                                      ));

                                  Navigator.of(context).pop();
                                },
                              ))
                          .toList(),
                    ),
                  );
                },
                error: (error, stackTrace) {
                  return ErrorWidget(error);
                },
                loading: () => const Center(
                      child: CircularProgressIndicator.adaptive(),
                    )),
          ],
        ),
      ),
      body: FlutterMap(
        mapController: mapController,
        options: const MapOptions(
          initialCenter: LatLng(28.631131939823522, 77.09205778819896),
          initialZoom: 9.2,
        ),
        children: [
          TileLayer(
            urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
            userAgentPackageName: 'com.biswa.battlefield_awareness_test',
          ),
          ValueListenableBuilder(
              valueListenable: markers,
              builder: (context, value, _) {
                return MarkerLayer(
                    markers: value.map((e) => Marker(point: e, child: const Icon(Icons.pin_drop))).toList());
              }),
        ],
      ),
    );
  }
}
