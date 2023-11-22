import 'dart:convert';
import 'dart:developer';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';
import 'package:snapping_sheet/snapping_sheet.dart';

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

/// Fetch the current bluetooth device connected
/// Could be null for the first time
/// Would be used to listen to the services and characteristics
final currentBluetoothProvider = StateProvider<BluetoothDevice?>((ref) {
  return;
});

/// Fetch the services of the bluetoothDevice passed
final bluetoothServicesProvider = FutureProvider.family<List<BluetoothService>, BluetoothDevice>((ref, device) async {
  return device.discoverServices();
});

final characteristsicsProvider = StreamProvider.family<String, BluetoothCharacteristic>((ref, characteristic) {
  return characteristic.onValueReceived.map((event) {
    final data = utf8.decode(event);
    log(data);
    return data;
  });
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

class _HomeAppState extends ConsumerState<HomeApp> with TickerProviderStateMixin {
  /// Wether the bluetooth device is on or off
  ValueNotifier<bool> bluetoothOn = ValueNotifier(false);

  /// Controller to programatically control the map
  /// Used for zooming and panning
  late final MapController mapController;

  /// List of markers to be added in the map
  /// Would be programatically updated by the bluetooth device connected
  final ValueNotifier<List<LatLng>> markers = ValueNotifier([]);

  late final ScrollController scrollController;

  @override
  void initState() {
    scrollController = ScrollController();
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
    scrollController.dispose();
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
                      tooltip: 'Bluetooth Toggle',
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
                        children: data.map((e) => TileWidget(device: e)).toList(),
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
        body: SnappingSheet(
          /// Show Sheet only when bluetooth device is connected
          sheetBelow: ref.watch(currentBluetoothProvider) != null
              ? SnappingSheetContent(
                  childScrollController: scrollController,
                  draggable: true,
                  child: Consumer(builder: (context, ref, _) {
                    final futureservices = ref.watch(bluetoothServicesProvider(ref.watch(currentBluetoothProvider)!));
                    return futureservices.when(
                      data: (services) {
                        return ListView(
                          controller: scrollController,
                          reverse: true,
                          children: services.map((service) {
                            return Column(
                              children: [
                                Text(service.uuid.str),
                                ...service.characteristics
                                    .map((characteristic) => CharacteristicTileWidget(
                                          characteristic: characteristic,
                                          onNotify: (data) {
                                            final stringData = utf8.decode(data);

                                            /// the string data is : lat:lat_numberlon:lon_number
                                            /// so parse the data and update the markers
                                            final LatLng latlng = LatLng(
                                                double.parse(stringData.split('lat:')[1].split('lon:')[0]),
                                                double.parse(stringData.split('lon:')[1]));

                                            markers.value = [...markers.value, latlng];
                                            log(stringData);
                                          },
                                        ))
                                    .toList()
                              ],
                            );
                          }).toList(),
                        );
                      },
                      loading: () => const Center(
                        child: CircularProgressIndicator.adaptive(),
                      ),
                      error: (error, stackTrace) {
                        return ErrorWidget(error);
                      },
                    );
                  }))
              : null,
          grabbing: ref.watch(currentBluetoothProvider) != null ? const GrabbingWidget() : const SizedBox.shrink(),
          // grabbing: const GrabbingWidget(),
          grabbingHeight: 75,
          snappingPositions: const [
            SnappingPosition.factor(
              positionFactor: 0.0,
              snappingCurve: Curves.easeOutExpo,
              snappingDuration: Duration(seconds: 1),
              grabbingContentOffset: GrabbingContentOffset.top,
            ),
            SnappingPosition.factor(
              snappingCurve: Curves.elasticOut,
              snappingDuration: Duration(milliseconds: 1750),
              positionFactor: 0.5,
            ),
            SnappingPosition.factor(
              grabbingContentOffset: GrabbingContentOffset.bottom,
              snappingCurve: Curves.easeInExpo,
              snappingDuration: Duration(seconds: 1),
              positionFactor: 0.9,
            ),
          ],
          child: FlutterMap(
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
        ));
  }
}

class TileWidget extends ConsumerStatefulWidget {
  final BluetoothDevice device;
  const TileWidget({super.key, required this.device});

  @override
  ConsumerState<ConsumerStatefulWidget> createState() => _TileWidgetState();
}

class _TileWidgetState extends ConsumerState<TileWidget> {
  ValueNotifier<bool> loading = ValueNotifier(false);

  bool connecting = false;

  @override
  void dispose() {
    loading.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final currentSelectedDevice = ref.watch(currentBluetoothProvider);
    return ListTile(
      title: Text(widget.device.platformName),
      subtitle: Text(widget.device.remoteId.str),
      trailing: currentSelectedDevice != null && currentSelectedDevice == widget.device
          ? const Text('Connected')
          : ValueListenableBuilder(
              valueListenable: loading,
              builder: (context, value, _) {
                return value ? const CircularProgressIndicator.adaptive() : const SizedBox.shrink();
              }),
      onTap: () {
        if (connecting) return;
        loading.value = true;
        connecting = true;
        widget.device.connect(autoConnect: true).onError((error, stackTrace) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(error.toString()),
              showCloseIcon: true,
              behavior: SnackBarBehavior.floating,
            ),
          );
        }).then((_) {
          ref.read(currentBluetoothProvider.notifier).update((_) => widget.device);
          return ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Connected to ${widget.device.platformName}'),
              showCloseIcon: true,
              behavior: SnackBarBehavior.floating,
            ),
          );
        });
        connecting = false;
        loading.value = false;

        Navigator.of(context).pop();
      },
    );
  }
}

class GrabbingWidget extends StatelessWidget {
  const GrabbingWidget({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        boxShadow: [
          BoxShadow(blurRadius: 25, color: Colors.black.withOpacity(0.2)),
        ],
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Container(
            margin: const EdgeInsets.only(top: 20),
            width: 100,
            height: 7,
            decoration: BoxDecoration(
              color: Colors.grey,
              borderRadius: BorderRadius.circular(5),
            ),
          ),
          Container(
            color: Colors.grey[200],
            height: 2,
            margin: const EdgeInsets.all(15).copyWith(top: 0, bottom: 0),
          )
        ],
      ),
    );
  }
}

class CharacteristicTileWidget extends ConsumerStatefulWidget {
  final BluetoothCharacteristic characteristic;
  final void Function(List<int>)? onNotify;
  const CharacteristicTileWidget({super.key, required this.characteristic, required this.onNotify});

  @override
  ConsumerState<ConsumerStatefulWidget> createState() => _CharacteristicTileWidgetState();
}

class _CharacteristicTileWidgetState extends ConsumerState<CharacteristicTileWidget> {
  bool notifying = false;

  @override
  void initState() {
    notifying = widget.characteristic.isNotifying;
    super.initState();
  }

  @override
  Widget build(BuildContext context) {
    return ListTile(
      title: Text(widget.characteristic.uuid.str),
      trailing: notifying
          ? TextButton(
              onPressed: () {
                widget.characteristic.onValueReceived.listen(widget.onNotify);
              },
              child: const Text('Subscribe'),
            )
          : null,
      subtitle: TextButton(
          onPressed: () async {
            if (notifying) {
              //TODO: Show logs
            } else {
              await widget.characteristic.setNotifyValue(true, timeout: 45);
              notifying = true;
              setState(() {});
            }
          },
          child: Text(!widget.characteristic.isNotifying ? 'Subscribe' : 'Logs')),
    );
  }
}
