import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:wifi_scan/wifi_scan.dart';
import 'services.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const RizioApp());
}

class RizioApp extends StatelessWidget {
  const RizioApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'RizIO',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xff193f3a),
        brightness: Brightness.light,
      ),
      useMaterial3: true,
      scaffoldBackgroundColor: const Color(0xfff7f8f4),
      fontFamily: 'sans-serif',
      appBarTheme: const AppBarTheme(
        backgroundColor: Color(0xfff7f8f4),
        foregroundColor: Color(0xff102a27),
        elevation: 0,
      ),
      cardTheme: CardThemeData(
        color: Colors.white,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      ),
      inputDecorationTheme: const InputDecorationTheme(
        filled: true,
        fillColor: Colors.white,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.all(Radius.circular(14)),
          borderSide: BorderSide.none,
        ),
      ),
    ),
    home: const Home(),
  );
}

class Home extends StatefulWidget {
  const Home({super.key});
  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> with WidgetsBindingObserver {
  final api = Api();
  late final network = DeviceNetwork(api);
  bool loading = true, register = false, busy = false;
  bool provisioningWifi = false, deletingDevice = false;
  bool reloading = false;
  bool restoring = true;
  int sceneCount = 0;
  final Set<String> controlBusyDevices = <String>{};
  String? error;
  dynamic user;
  List<dynamic> devices = [];
  List<Map<String, dynamic>> get nearbyDevices {
    final ownedSerials = devices.map((device) => device['sn']).toSet();
    return network.discovered.values
        .where((device) => !ownedSerials.contains(device['sn']))
        .toList();
  }

  Timer? timer;
  final email = TextEditingController(),
      password = TextEditingController(),
      name = TextEditingController();
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    restore();
    timer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (user != null &&
          !busy &&
          controlBusyDevices.isEmpty &&
          !restoring &&
          !deletingDevice) {
        reload(silent: true);
      }
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    timer?.cancel();
    email.dispose();
    password.dispose();
    name.dispose();
    api.client.close();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed &&
        user != null &&
        !restoring &&
        !deletingDevice) {
      // The phone often remains on the ESP AP until provisioning restarts it.
      // Retry the saved claim automatically when the phone gets internet again.
      unawaited(reload(silent: true));
    }
  }

  Future<void> restore() async {
    final cached = await api.cachedHome();
    if (cached != null) {
      user = cached['user'];
      devices = cached['devices'] as List<dynamic>;
      for (final d in devices) {
        d['online'] = false;
        d['local_online'] = false;
      }
      await network.restoreLocal();
      if (mounted) setState(() => loading = false);
    }
    unawaited(discoverNearby(silent: true));
    unawaited(network.readLocalStates(devices));
    if (mounted) setState(() {});
    try {
      await api.restore();
      if (api.access != null) {
        await api.flushPendingClaim();
        user = await api.request('/auth/me');
        await api.cacheHome(user, devices);
        await reload();
      }
    } catch (e) {
      if (!isConnectionFailure(e)) {
        await network.clear();
        await api.storage.delete(key: 'offline_home');
        user = null;
        devices = [];
        error = 'Sesi tidak dapat dipulihkan. Silakan masuk kembali.';
      }
    }
    restoring = false;
    if (mounted) setState(() => loading = false);
  }

  Future<void> flushPendingLocalPair() async {
    final pending = await api.pendingLocalPair();
    if (pending == null) return;
    final sn = pending['sn'] as String?;
    final setupCode =
        pending['setup_code'] as String? ?? DeviceNetwork.defaultSetupCode;
    if (sn == null) return;
    try {
      await network.discover();
      if (await network.tryPairOffline(sn, setupCode)) {
        await api.clearPendingLocalPair();
        await network.readLocalStates(
          devices.where((d) => d['sn'] == sn).toList(),
        );
      }
    } catch (_) {
      // The phone may still be switching from the ESP AP to the home LAN.
      // Keep the pending pair and retry on the next refresh.
    }
  }

  Future<void> discoverNearby({bool silent = false}) async {
    if (deletingDevice) return;
    try {
      await network.discover();
      if (mounted) {
        setState(() {});
      }
      if (!silent && mounted) {
        message(
          nearbyDevices.isEmpty
              ? 'Tidak ada perangkat baru ditemukan.'
              : '${nearbyDevices.length} perangkat baru ditemukan.',
        );
      }
    } catch (e) {
      if (!silent && mounted) message('Discovery lokal gagal: $e');
    }
  }

  void message(String text) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
    }
  }

  Future<void> run(Future<void> Function() work) async {
    if (busy) return;
    setState(() => busy = true);
    try {
      await work();
    } catch (e) {
      message(e.toString());
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> reload({bool silent = false}) async {
    if (reloading || deletingDevice || controlBusyDevices.isNotEmpty) return;
    final accountId = user?['id'];
    reloading = true;
    try {
      // Cloud refresh must not wait for UDP/LAN discovery. The phone and ESP
      // may be on different networks, while both remain online in the cloud.
      unawaited(discoverNearby(silent: true));
      unawaited(flushPendingLocalPair());
      unawaited(network.readLocalStates(devices));
      if (mounted) setState(() {});
      try {
        // Resume setup after the phone leaves the ESP access point.
        await api.flushPendingClaim();
        await _flushLocalOnlyClaims();
        await api.flushPendingDelete();
        final pendingDelete = await api.pendingDelete();
        final pendingDeleteSn = pendingDelete?['sn'];
        final results = await Future.wait([
          api.request('/devices'),
          api.request('/schedules'),
        ]);
        final result = results[0];
        final scheduleResult = results[1];
        final loadedSceneCount = scheduleResult is List
            ? scheduleResult
                  .whereType<Map>()
                  .map((schedule) => schedule['scene_id'])
                  .where((id) => id != null)
                  .toSet()
                  .length
            : 0;
        if (user?['id'] != accountId) return;
        final owned =
            (result is List
                    ? result
                    : result['items'] ?? result['devices'] ?? [])
                as List<dynamic>;
        final enrichedOwned = owned
            .where((device) {
              return pendingDeleteSn == null || device['sn'] != pendingDeleteSn;
            })
            .map((device) {
              final local = network.discovered[device['sn']];
              final discoveredChannels = local?['channels'];
              if (local == null ||
                  discoveredChannels is! List ||
                  discoveredChannels.isEmpty) {
                return device;
              }
              final cloudChannels = device['channels'];
              // The ESP identity is authoritative for GPIO topology when the
              // phone is on the same LAN; retain aliases received from cloud.
              if (cloudChannels is List &&
                  cloudChannels.length >= discoveredChannels.length) {
                return device;
              }
              return {
                ...device as Map<String, dynamic>,
                'device_type': local['device_type'] ?? device['device_type'],
                'relay_type': local['relay_type'] ?? device['relay_type'],
                'model': local['model'] ?? device['model'],
                'channels': discoveredChannels,
              };
            })
            .toList();
        final localOnly = devices
            .where((d) => d['local_only'] == true)
            .where((d) => !enrichedOwned.any((cloud) => cloud['sn'] == d['sn']))
            .map((device) {
              final local = network.discovered[device['sn']];
              final channels = local?['channels'];
              if (local == null || channels is! List || channels.isEmpty) {
                return device;
              }
              return {
                ...device as Map<String, dynamic>,
                'model': local['model'] ?? device['model'],
                'device_type': local['device_type'] ?? device['device_type'],
                'relay_type': local['relay_type'] ?? device['relay_type'],
                'channels': channels,
              };
            })
            .toList();
        final merged = [...enrichedOwned, ...localOnly];
        // Local probing may fail when the phone and ESP use different
        // networks. Keep the backend cloud status authoritative.
        final cloudStatus = <String, dynamic>{
          for (final device in enrichedOwned) device['sn']: device['online'],
        };
        for (final device in merged) {
          if (cloudStatus.containsKey(device['sn'])) {
            device['online'] = cloudStatus[device['sn']];
          }
        }
        if (user?['id'] != accountId) return;
        if (mounted) {
          setState(() {
            devices = merged;
            sceneCount = loadedSceneCount;
            error = null;
          });
        }
        unawaited(
          network.readLocalStates(merged).then((_) {
            if (mounted && !deletingDevice) setState(() {});
          }),
        );
      } catch (e) {
        final offline = isConnectionFailure(e);
        if (e is ApiFailure && (e.statusCode == 401 || e.statusCode == 403)) {
          await network.clear();
          await api.storage.delete(key: 'offline_home');
          user = null;
          devices = [];
        }
        if (offline) {
          for (final d in devices) {
            d['online'] = false;
          }
        }
        if (mounted) setState(() => error = offline ? null : e.toString());
        if (!silent && !offline) rethrow;
      }
      if (user != null) await api.cacheHome(user, devices);
    } finally {
      reloading = false;
    }
  }

  Future<void> _flushLocalOnlyClaims() async {
    final localDevices = devices
        .where((device) => device['local_only'] == true)
        .toList();
    for (final device in localDevices) {
      final sn = device['sn'];
      if (sn is! String || sn.isEmpty) continue;
      await api.savePendingClaim({'sn': sn});
      try {
        await network.claimDevice(sn);
        await api.storage.delete(key: 'pending_claim');
        device.remove('local_only');
        await api.clearPendingLocalPair();
      } catch (_) {
        // Keep local device visible and retry automatically on the next
        // refresh/resume when cloud connectivity is available.
      }
    }
    await api.cacheHome(user, devices);
  }

  Future<void> login() async {
    final r = await api.request(
      register ? '/auth/register' : '/auth/login',
      method: 'POST',
      body: {
        'email': email.text.trim(),
        'password': password.text,
        if (register) 'name': name.text.trim(),
      },
    );
    final previous = await api.cachedHome();
    if (previous?['user']?['id'] != r['user']['id']) {
      await api.storage.delete(key: 'pending_claim');
      await network.clear();
      devices = [];
    }
    await api.save(r);
    user = r['user'];
    await api.cacheHome(user, devices);
    password.clear();
    await reload();
  }

  Future<Map<String, String>?> form(
    String title,
    Map<String, String> fields, {
    Set<String> secrets = const {},
  }) async {
    final controllers = fields.map(
      (k, v) => MapEntry(k, TextEditingController(text: v)),
    );
    final key = GlobalKey<FormState>();
    final result = await showDialog<Map<String, String>>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(title),
        content: SingleChildScrollView(
          child: Form(
            key: key,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: controllers.entries
                  .map(
                    (e) => Padding(
                      padding: const EdgeInsets.only(bottom: 14),
                      child: TextFormField(
                        controller: e.value,
                        obscureText: secrets.contains(e.key),
                        decoration: InputDecoration(labelText: e.key),
                        validator: (v) =>
                            v == null || v.isEmpty ? 'Wajib diisi' : null,
                      ),
                    ),
                  )
                  .toList(),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('Batal'),
          ),
          FilledButton(
            onPressed: () {
              if (key.currentState!.validate()) {
                Navigator.pop(
                  c,
                  controllers.map((k, v) => MapEntry(k, v.text)),
                );
              }
            },
            child: const Text('Lanjutkan'),
          ),
        ],
      ),
    );
    // Wait for the dialog route to finish deactivating before disposing its
    // fields or rebuilding the page behind it.
    await Future<void>.delayed(const Duration(milliseconds: 300));
    await WidgetsBinding.instance.endOfFrame;
    for (final c in controllers.values) {
      c.dispose();
    }
    return result;
  }

  Future<void> claim() async {
    final raw = await Navigator.push<String>(
      context,
      MaterialPageRoute(builder: (_) => const ScanPage()),
    );
    if (raw == null) return;
    await run(() async {
      Map<String, dynamic> claimData;
      var setupQr = false;
      try {
        claimData = parseSetup(raw);
        setupQr = true;
      } catch (_) {
        claimData = parseClaim(raw);
      }
      await api.savePendingClaim({'sn': claimData['sn']});
      try {
        await network.claimDevice(claimData['sn'] as String);
        await api.storage.delete(key: 'pending_claim');
      } catch (e) {
        if (!isConnectionFailure(e)) {
          await api.storage.delete(key: 'pending_claim');
          rethrow;
        }
        message(
          'Perangkat terdeteksi lokal. Claim akan dikirim saat internet kembali.',
        );
      }
      if (setupQr) {
        final ssid = await selectWifiNetwork();
        if (ssid != null && mounted) {
          await Future<void>.delayed(const Duration(milliseconds: 150));
          if (!mounted) return;
          final values = await form(
            'Hubungkan Wi-Fi perangkat',
            {
              'SSID Wi-Fi': ssid,
              'Kata sandi Wi-Fi': '',
              'Kode setup perangkat':
                  '${claimData['setup_code'] ?? DeviceNetwork.defaultSetupCode}',
            },
            secrets: {'Kata sandi Wi-Fi', 'Kode setup perangkat'},
          );
          if (values != null) {
            if (mounted) setState(() => provisioningWifi = true);
            try {
              await network.provision(
                values['SSID Wi-Fi']!,
                values['Kata sandi Wi-Fi']!,
                values['Kode setup perangkat']!,
              );
              await Future<void>.delayed(const Duration(seconds: 2));
            } finally {
              if (mounted) setState(() => provisioningWifi = false);
            }
          }
        }
      }
      await reload();
      message(
        setupQr
            ? 'Wi-Fi perangkat sedang diterapkan. Sambungkan HP kembali ke jaringan rumah.'
            : 'Perangkat berhasil diklaim.',
      );
    });
  }

  Future<void> provision() async {
    final values = await form(
      'Hubungkan Wi-Fi',
      {'SSID Wi-Fi': '', 'Kata sandi Wi-Fi': '', 'Kode setup perangkat': ''},
      secrets: {'Kata sandi Wi-Fi', 'Kode setup perangkat'},
    );
    if (values == null) return;
    await run(() async {
      await network.provision(
        values['SSID Wi-Fi']!,
        values['Kata sandi Wi-Fi']!,
        values['Kode setup perangkat']!,
      );
      message(
        'Konfigurasi diterima. Sambungkan ponsel kembali ke Wi-Fi rumah, lalu perbarui perangkat.',
      );
    });
  }

  Future<String?> selectWifiNetwork() async {
    Future<String?> manualSsid() async {
      final values = await form('Masukkan Wi‑Fi rumah', {'SSID Wi-Fi': ''});
      return values?['SSID Wi-Fi']?.trim().isEmpty == true
          ? null
          : values?['SSID Wi-Fi']?.trim();
    }

    final permission = await Permission.locationWhenInUse.request();
    if (!permission.isGranted) {
      message('Scan Wi‑Fi tidak diizinkan. Masukkan SSID secara manual.');
      return manualSsid();
    }
    if (await WiFiScan.instance.canStartScan() != CanStartScan.yes ||
        !await WiFiScan.instance.startScan()) {
      message('Scan Wi‑Fi tidak tersedia. Masukkan SSID secara manual.');
      return manualSsid();
    }
    final ssids =
        (await WiFiScan.instance.getScannedResults())
            .map((point) => point.ssid.trim())
            .where((ssid) => ssid.isNotEmpty)
            .toSet()
            .toList()
          ..sort();
    if (ssids.isEmpty) {
      message('Tidak ada Wi‑Fi yang terdeteksi. Masukkan SSID secara manual.');
      return manualSsid();
    }
    if (!mounted) return null;
    return showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: ListView.builder(
          shrinkWrap: true,
          itemCount: ssids.length,
          itemBuilder: (context, index) => ListTile(
            leading: const Icon(Icons.wifi),
            title: Text(ssids[index]),
            onTap: () => Navigator.pop(context, ssids[index]),
          ),
        ),
      ),
    );
  }

  Future<void> onboardDiscoveredDevice(dynamic device) async {
    if (user == null) {
      message('Masuk terlebih dahulu untuk mengklaim perangkat.');
      return;
    }
    await run(() async {
      final sn = device['sn'] as String;
      final address = device['address'] as String;
      if (!await network.needsWifiSetup(sn, address)) {
        await network.claimDevice(sn);
        await api.storage.delete(key: 'pending_claim');
        await reload();
        message('Perangkat berhasil diklaim.');
        return;
      }
      final ssid = await selectWifiNetwork();
      if (ssid == null || !mounted) return;
      // Let the Wi-Fi selection sheet finish its closing animation before
      // changing the provisioning overlay state.
      await Future<void>.delayed(const Duration(milliseconds: 150));
      if (!mounted) return;
      final values = await form(
        'Hubungkan Wi-Fi',
        {'SSID Wi-Fi': ssid, 'Kata sandi Wi-Fi': ''},
        secrets: {'Kata sandi Wi-Fi'},
      );
      if (values == null) return;
      if (mounted) setState(() => provisioningWifi = true);
      try {
        await network.provision(
          values['SSID Wi-Fi']!,
          values['Kata sandi Wi-Fi']!,
          DeviceNetwork.defaultSetupCode,
          address: address,
        );
        // Give the ESP time to stop its AP and start station mode before
        // returning the user to the device list.
        await Future<void>.delayed(const Duration(seconds: 2));
      } finally {
        if (mounted) setState(() => provisioningWifi = false);
      }
      final localDevice = <String, dynamic>{
        'sn': sn,
        'name': sn,
        'model': device['model'] ?? 'ESP',
        'device_type': 'relay',
        'relay_type': null,
        'channels': device['channels'] ?? <dynamic>[],
        'disabled': false,
        'local_only': true,
        'online': false,
        'local_online': false,
      };
      devices.removeWhere((d) => d['sn'] == sn);
      devices.add(localDevice);
      await api.cacheHome(user, devices);
      if (!mounted) return;
      // Let the provisioning dialog/network handover finish its frame before
      // rebuilding the dashboard. This avoids Flutter tree assertions when
      // the phone leaves the ESP access point immediately after provisioning.
      setState(() {});
      unawaited(_completeProvisioning(sn, localDevice));
    });
  }

  Future<void> _completeProvisioning(
    String sn,
    Map<String, dynamic> localDevice,
  ) async {
    try {
      // Persist the cloud claim immediately. The phone may still be moving
      // from the ESP AP to the home/internet network while local pairing is
      // retried, so claim recovery must not wait for LAN discovery.
      await api.savePendingClaim({'sn': sn});
      await api.savePendingLocalPair({
        'sn': sn,
        'setup_code': DeviceNetwork.defaultSetupCode,
      });
      // Do not run UDP discovery while Android is switching away from the
      // ESP access point. The normal reload/resume path retries local pairing
      // once the phone has a stable network again.
      try {
        await network.claimDevice(sn);
        await api.storage.delete(key: 'pending_claim');
        localDevice.remove('local_only');
        await api.clearPendingLocalPair();
        await api.cacheHome(user, devices);
        if (mounted) await reload(silent: true);
      } catch (_) {
        await api.cacheHome(user, devices);
      }
    } catch (_) {}
  }

  Future<void> detail(dynamic d) async {
    await network.readLocalStates([d]);
    // The home list can contain a cached state without the latest Wi-Fi SSID.
    // Refresh the cloud state before opening detail so the SSID is available
    // even when the phone is not on the device's local network.
    try {
      await _refreshDeviceStatus(d);
    } catch (_) {
      // Keep opening the detail page with the last cached state when offline.
    }
    if (!mounted) return;
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => _DeviceDetailPage(
          device: d,
          onToggle: _toggleDevice,
          onRefresh: () => _refreshDeviceStatus(d),
          onProvision: () => _provisionDevice(d),
          onHistory: (rangeHours, bucketMinutes) => api.temperatureHistory(
            d['sn'] as String,
            rangeHours: rangeHours,
            bucketMinutes: bucketMinutes,
          ),
          onPowerHistory: (rangeHours, bucketMinutes) => api.powerHistory(
            d['sn'] as String,
            rangeHours: rangeHours,
            bucketMinutes: bucketMinutes,
          ),
          onAlias: (channelId, alias) async {
            final updated = await api.request(
              '/devices/${Uri.encodeComponent(d['sn'] as String)}/channels/$channelId',
              method: 'PATCH',
              body: {'alias': alias},
            );
            d['channels'] = updated['channels'];
            await api.cacheHome(user, devices);
          },
          onUnclaim: () => _unclaimDevice(d),
        ),
      ),
    );
  }

  Future<void> _refreshDeviceStatus(dynamic device) async {
    await network.readLocalStates([device]);
    final localState = device['state'];
    final hasWifiSsid =
        localState is Map &&
        localState['wifi_ssid']?.toString().trim().isNotEmpty == true;
    // A local status from older sensor firmware may not contain wifi_ssid.
    // Fall back to the cloud state so the detail page can still show it.
    if (device['local_online'] != true || !hasWifiSsid) {
      final status = await api.request(
        '/devices/${Uri.encodeComponent(device['sn'] as String)}/status',
      );
      device['online'] = status['online'] == true;
      final state = Map<String, dynamic>.from(device['state'] ?? {});
      for (final key in [
        'gpio',
        'channels',
        'rssi',
        'wifi_ssid',
        'ip_address',
        'uptime',
        'free_heap',
        'firmware_version',
        'temperature_c',
        'humidity_percent',
        'voltage_v',
        'current_a',
        'power_w',
        'energy_kwh',
        'frequency_hz',
        'power_factor',
      ]) {
        if (status.containsKey(key)) state[key] = status[key];
      }
      device['state'] = state;
      if (status['wifi_ssid'] != null) {
        device['wifi_ssid'] = status['wifi_ssid'];
      }
    }
  }

  Future<void> _provisionDevice(dynamic device) async {
    final ssid = await selectWifiNetwork();
    if (ssid == null || !mounted) return;
    // The Wi-Fi picker is a bottom sheet. Let its closing animation finish
    // before opening the password form, otherwise Flutter can deactivate the
    // inherited sheet tree while it still has dependents.
    await Future<void>.delayed(const Duration(milliseconds: 150));
    if (!mounted) return;
    final sn = device['sn'] as String;
    final address = network.addresses[sn];
    final values = await form(
      'Konfigurasi Wi-Fi perangkat',
      {'Kata sandi Wi-Fi': ''},
      secrets: {'Kata sandi Wi-Fi'},
    );
    if (values == null) return;
    await run(() async {
      final password = values['Kata sandi Wi-Fi']!;
      if (address == null) {
        await network.provisionCloud(sn, ssid, password);
      } else {
        final token = await network.token(sn);
        await network.provision(
          ssid,
          password,
          '',
          address: address,
          token: token['token'] as String,
        );
      }
      message(
        address == null
            ? 'Konfigurasi Wi-Fi dikirim melalui cloud. Perangkat akan restart dan tersambung ke jaringan baru.'
            : 'Konfigurasi Wi-Fi diterima. Sambungkan HP kembali ke jaringan rumah, lalu refresh perangkat.',
      );
    });
  }

  Future<bool> _unclaimDevice(dynamic device) async {
    final values = await form(
      'Lepaskan perangkat',
      {'Password akun': ''},
      secrets: {'Password akun'},
    );
    if (values == null) return false;
    var deleted = false;
    if (mounted) setState(() => deletingDevice = true);
    try {
      await run(() async {
        final sn = device['sn'] as String;
        if (device['local_only'] == true) {
          // A local-only device has no cloud ownership to release yet. Remove
          // it locally and cancel retries so it cannot reappear after refresh.
          try {
            if (network.offlineKeys.containsKey(sn)) {
              await network.deviceLocal(
                sn,
                '/api/v1/local-access',
                method: 'DELETE',
              );
            }
          } catch (_) {
            // The device may already be unreachable; local removal still wins.
          }
          await network.clear(sn);
          await api.storage.delete(key: 'pending_claim');
          await api.clearPendingLocalPair();
          await api.clearPendingDelete();
          devices.removeWhere((d) => d['sn'] == sn);
          await api.cacheHome(user, devices);
          deleted = true;
          if (mounted) setState(() {});
          return;
        }
        await api.savePendingDelete({
          'sn': sn,
          'password': values['Password akun'],
        });
        if (network.offlineKeys.containsKey(sn)) {
          // Revoke durable LAN access when reachable, but local deletion must
          // not wait for the device or cloud to respond.
          try {
            await network.deviceLocal(
              sn,
              '/api/v1/local-access',
              method: 'DELETE',
            );
          } catch (_) {}
        }
        await network.clear(sn);
        await api.storage.delete(key: 'pending_claim');
        await api.clearPendingLocalPair();
        devices.removeWhere((d) => d['sn'] == sn);
        await api.cacheHome(user, devices);
        deleted = true;
        if (mounted) setState(() {});
        await api.flushPendingDelete();
      });
    } finally {
      if (mounted) setState(() => deletingDevice = false);
    }
    return deleted;
  }

  Future<void> _toggleDevice(
    dynamic device,
    dynamic channel,
    bool value,
  ) async {
    await _toggle(device, channel, value);
  }

  @override
  Widget build(BuildContext context) {
    if (loading) {
      return const Scaffold(
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.hub, size: 60),
              Text('RizIO', style: TextStyle(fontSize: 32)),
              SizedBox(height: 24),
              CircularProgressIndicator(),
            ],
          ),
        ),
      );
    }
    if (user == null) return _authView(context);
    return _dashboardView(context);
  }

  Widget _authView(BuildContext context) {
    final ink = const Color(0xff193f3a);
    return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(28, 44, 28, 28),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 30),
              Container(
                height: 240,
                decoration: BoxDecoration(
                  color: const Color(0xffe8eee8),
                  borderRadius: BorderRadius.circular(34),
                ),
                child: Center(
                  child: Icon(Icons.home_work_outlined, size: 96, color: ink),
                ),
              ),
              const SizedBox(height: 34),
              Text(
                'RizIO',
                style: TextStyle(
                  fontSize: 42,
                  fontWeight: FontWeight.w700,
                  color: ink,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                register
                    ? 'Buat akun untuk perangkat Anda'
                    : 'Perangkat pintar, rumah yang lebih nyaman.',
                style: const TextStyle(fontSize: 17, color: Color(0xff69736f)),
              ),
              const SizedBox(height: 30),
              if (error != null) ...[
                Text(error!, style: const TextStyle(color: Color(0xffb54d43))),
                const SizedBox(height: 12),
              ],
              if (register) ...[
                TextField(
                  controller: name,
                  decoration: const InputDecoration(labelText: 'Nama'),
                ),
                const SizedBox(height: 12),
              ],
              TextField(
                controller: email,
                keyboardType: TextInputType.emailAddress,
                decoration: const InputDecoration(labelText: 'Email'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: password,
                obscureText: true,
                decoration: const InputDecoration(labelText: 'Kata sandi'),
              ),
              const SizedBox(height: 18),
              FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: ink,
                  minimumSize: const Size.fromHeight(54),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
                onPressed: busy ? null : () => run(login),
                child: Text(
                  busy
                      ? 'Memproses...'
                      : register
                      ? 'Daftar'
                      : 'Masuk',
                ),
              ),
              TextButton(
                onPressed: () => setState(() => register = !register),
                child: Text(
                  register ? 'Sudah punya akun? Masuk' : 'Buat akun baru',
                ),
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: busy ? null : () => discoverNearby(),
                icon: const Icon(Icons.wifi_find),
                label: const Text('Cari perangkat di jaringan lokal'),
              ),
              if (nearbyDevices.isNotEmpty) ...[
                const SizedBox(height: 18),
                const Text(
                  'Perangkat ditemukan',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 8),
                ...nearbyDevices.map(
                  (d) => Card(
                    child: ListTile(
                      onTap: () => onboardDiscoveredDevice(d),
                      leading: const Icon(Icons.memory),
                      title: Text('${d['sn']}'),
                      subtitle: Text('${d['address']}'),
                      trailing: const Icon(Icons.arrow_forward_ios),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _dashboardView(BuildContext context) {
    final online = devices.where((d) => d['online'] == true).length;
    return Scaffold(
      body: Stack(
        children: [
          SafeArea(
            child: RefreshIndicator(
              onRefresh: reload,
              child: CustomScrollView(
                slivers: [
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
                    sliver: SliverToBoxAdapter(
                      child: Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Selamat datang,',
                                  style: TextStyle(color: Colors.grey.shade600),
                                ),
                                Text(
                                  user['name'] ?? 'Rizio User',
                                  style: const TextStyle(
                                    fontSize: 25,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          IconButton.filled(
                            style: IconButton.styleFrom(
                              backgroundColor: const Color(0xff193f3a),
                              foregroundColor: Colors.white,
                            ),
                            onPressed: busy ? null : claim,
                            icon: const Icon(Icons.add),
                          ),
                          IconButton(
                            tooltip: 'Akun',
                            onPressed: () => _accountDialog(context),
                            icon: const Icon(Icons.settings_outlined),
                          ),
                        ],
                      ),
                    ),
                  ),
                  SliverToBoxAdapter(child: _categoryRow()),
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(20, 18, 20, 100),
                    sliver: SliverList(
                      delegate: SliverChildListDelegate([
                        if (busy) const LinearProgressIndicator(),
                        if (error != null) _errorBanner(),
                        if (nearbyDevices.isNotEmpty) _nearbyDevicesCard(),
                        _statsRow(online),
                        const SizedBox(height: 24),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            const Text(
                              'Perangkat',
                              style: TextStyle(
                                fontSize: 20,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            Text(
                              '${devices.length} terdaftar',
                              style: TextStyle(color: Colors.grey.shade600),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        if (devices.isEmpty)
                          _emptyState()
                        else
                          ...devices.map(_deviceTile),
                      ]),
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (provisioningWifi)
            Positioned.fill(
              child: ColoredBox(
                color: Color(0x99000000),
                child: Center(
                  child: Card(
                    margin: EdgeInsets.all(28),
                    child: Padding(
                      padding: EdgeInsets.all(24),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          CircularProgressIndicator(),
                          SizedBox(height: 18),
                          Text(
                            'Menghubungkan perangkat...',
                            style: TextStyle(fontWeight: FontWeight.w700),
                          ),
                          SizedBox(height: 8),
                          Text(
                            'Perangkat sedang berpindah ke mode Wi-Fi station.',
                            textAlign: TextAlign.center,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: 0,
        height: 72,
        backgroundColor: Colors.white,
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.home_outlined),
            selectedIcon: Icon(Icons.home),
            label: 'Beranda',
          ),
          NavigationDestination(
            icon: Icon(Icons.auto_awesome_outlined),
            label: 'Scene',
          ),
          NavigationDestination(
            icon: Icon(Icons.bolt_outlined),
            label: 'Energi',
          ),
          NavigationDestination(
            icon: Icon(Icons.settings_outlined),
            label: 'Pengaturan',
          ),
        ],
        onDestinationSelected: (index) {
          if (index == 1) {
            Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => _AutomationPage(api: api, devices: devices),
              ),
            );
          }
          if (index == 3) _accountDialog(context);
        },
      ),
    );
  }

  Widget _categoryRow() => SizedBox(
    height: 58,
    child: ListView(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 0),
      scrollDirection: Axis.horizontal,
      children: const [
        _CategoryChip(label: 'Semua perangkat', selected: true),
        _CategoryChip(label: 'Ruang tamu'),
        _CategoryChip(label: 'Kamar'),
        _CategoryChip(label: 'Dapur'),
      ],
    ),
  );

  Widget _statsRow(int online) => Row(
    children: [
      _statCard(
        Icons.power_settings_new,
        '${devices.length}',
        'Perangkat',
        const Color(0xffe5f2e9),
      ),
      const SizedBox(width: 8),
      _statCard(Icons.wifi, '$online', 'Online', const Color(0xffe5eef0)),
      const SizedBox(width: 8),
      _statCard(
        Icons.schedule,
        '$sceneCount',
        'Scene',
        const Color(0xffeef0f6),
      ),
    ],
  );

  Widget _nearbyDevicesCard() => Card(
    margin: const EdgeInsets.only(bottom: 18),
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Perangkat baru ditemukan',
            style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          ...nearbyDevices.map(
            (d) => ListTile(
              onTap: () => onboardDiscoveredDevice(d),
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.memory, color: Color(0xff2d6655)),
              title: Text('${d['sn']}'),
              subtitle: Text(
                '${d['address']}\nPilih untuk mengatur Wi-Fi perangkat',
              ),
              isThreeLine: true,
              trailing: const Icon(Icons.arrow_forward_ios),
            ),
          ),
        ],
      ),
    ),
  );

  Widget _statCard(IconData icon, String value, String label, Color color) =>
      Expanded(
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, size: 19, color: const Color(0xff193f3a)),
              const SizedBox(height: 8),
              Text(
                value,
                style: const TextStyle(
                  fontSize: 19,
                  fontWeight: FontWeight.w700,
                ),
              ),
              Text(
                label,
                style: TextStyle(fontSize: 11, color: Colors.grey.shade700),
              ),
            ],
          ),
        ),
      );

  Widget _deviceTile(dynamic d) {
    final sn = d['sn'] as String;
    final controlBusy = controlBusyDevices.contains(sn);
    final state = d['state'] ?? {};
    final channels = d['channels'] as List? ?? [];
    final switchChannels = channels
        .where((c) => c['type'] == 'switch')
        .toList();
    final hasRelay = switchChannels.isNotEmpty;
    final isOn = switchChannels.any(
      (c) => state['gpio']?['${c['pin']}'] == true,
    );
    final deviceType = d['device_type']?.toString();
    final hasPower = deviceType == 'power_meter' ||
        deviceType == 'switch_power' ||
        deviceType == 'switch_temp_power' ||
        state['voltage_v'] != null;
    final hasTemp = deviceType == 'sensor' ||
        deviceType == 'switch_temp' ||
        deviceType == 'switch_temp_power' ||
        channels.any((c) => c['type'] == 'sensor') ||
        state['temperature_c'] != null;

    IconData icon;
    Color iconColor;
    Color iconBg;

    if (hasPower && !hasRelay) {
      icon = Icons.bolt_rounded;
      iconColor = const Color(0xff0d9488);
      iconBg = const Color(0xffe6fffa);
    } else if (hasTemp && !hasRelay) {
      icon = Icons.thermostat_outlined;
      iconColor = const Color(0xffd97706);
      iconBg = const Color(0xfffffbeb);
    } else if (hasRelay && hasPower) {
      icon = Icons.power_rounded;
      iconColor = isOn ? const Color(0xff16a34a) : const Color(0xff0d9488);
      iconBg = isOn ? const Color(0xffdcfce7) : const Color(0xfff0fdf4);
    } else if (hasRelay) {
      icon = Icons.lightbulb_outline;
      iconColor = isOn ? const Color(0xff16a34a) : const Color(0xff2d6655);
      iconBg = isOn ? const Color(0xffe5f2e9) : const Color(0xfff0f1ee);
    } else {
      icon = Icons.devices_other;
      iconColor = const Color(0xff2d6655);
      iconBg = const Color(0xfff0f1ee);
    }

    String telemetryText = '';
    if (hasPower && state['power_w'] is num) {
      final w = (state['power_w'] as num).toStringAsFixed(1);
      final v = state['voltage_v'] is num
          ? (state['voltage_v'] as num).toStringAsFixed(0)
          : '220';
      telemetryText = '$w W · ${v}V';
    } else if (hasTemp && state['temperature_c'] is num) {
      final t = (state['temperature_c'] as num).toStringAsFixed(1);
      final h = state['humidity_percent'] is num
          ? (state['humidity_percent'] as num).toStringAsFixed(0)
          : '--';
      telemetryText = '$t°C · $h%';
    }

    final connectionStatus = d['local_online'] == true
        ? 'Online · Lokal'
        : '${d['online'] == true ? 'Online' : 'Offline'} · Cloud';

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: () => detail(d),
        child: Card(
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
            side: const BorderSide(color: Color(0xffe2e8e4)),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
            child: Row(
              children: [
                Container(
                  height: 50,
                  width: 50,
                  decoration: BoxDecoration(
                    color: iconBg,
                    borderRadius: BorderRadius.circular(15),
                  ),
                  child: Icon(icon, color: iconColor, size: 26),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        d['name'] ?? sn,
                        style: const TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 15,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Row(
                        children: [
                          Text(
                            connectionStatus,
                            style: TextStyle(
                              fontSize: 12,
                              color: Colors.grey.shade600,
                            ),
                          ),
                          if (telemetryText.isNotEmpty) ...[
                            Text(
                              '  •  ',
                              style: TextStyle(
                                fontSize: 10,
                                color: Colors.grey.shade400,
                              ),
                            ),
                            Text(
                              telemetryText,
                              style: const TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                                color: Color(0xff0d9488),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ],
                  ),
                ),
                if (hasRelay)
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () {},
                    child: Switch(
                      value: isOn,
                      onChanged: controlBusy
                          ? null
                          : (value) => _toggleAll(d, switchChannels, value),
                    ),
                  )
                else if (hasPower && state['power_w'] is num)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 5,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xffe6fffa),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      '${(state['power_w'] as num).toStringAsFixed(1)} W',
                      style: const TextStyle(
                        color: Color(0xff0d9488),
                        fontWeight: FontWeight.w800,
                        fontSize: 12,
                      ),
                    ),
                  )
                else if (hasTemp && state['temperature_c'] is num)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 5,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xfffff3e0),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      '${(state['temperature_c'] as num).toStringAsFixed(1)}°C',
                      style: const TextStyle(
                        color: Color(0xffb85c00),
                        fontWeight: FontWeight.w800,
                        fontSize: 12,
                      ),
                    ),
                  ),
                IconButton(
                  onPressed: () => detail(d),
                  icon: const Icon(Icons.chevron_right),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _toggle(dynamic d, dynamic channel, bool value) async {
    await _runDeviceControl(d, () async {
      await _sendChannel(d, channel, value);
      await api.cacheHome(user, devices);
      message('Perubahan dikonfirmasi perangkat.');
    });
  }

  Future<void> _toggleAll(dynamic d, List<dynamic> channels, bool value) async {
    await _runDeviceControl(d, () async {
      for (var index = 0; index < channels.length; index++) {
        final channel = channels[index];
        await _sendChannel(d, channel, value);
        if (mounted) setState(() {});
        if (index < channels.length - 1) {
          await Future<void>.delayed(const Duration(milliseconds: 150));
        }
      }
      await api.cacheHome(user, devices);
      message('Semua channel berhasil diperbarui.');
    });
  }

  Future<void> _runDeviceControl(
    dynamic device,
    Future<void> Function() action,
  ) async {
    final sn = device['sn'] as String;
    if (controlBusyDevices.contains(sn)) return;
    if (mounted) setState(() => controlBusyDevices.add(sn));
    try {
      await action();
    } catch (e) {
      message(e.toString());
    } finally {
      if (mounted) setState(() => controlBusyDevices.remove(sn));
    }
  }

  Future<void> _sendChannel(dynamic d, dynamic channel, bool value) async {
    final ack = await network.command(
      d['sn'] as String,
      'gpio.set',
      pin: channel['pin'] as int,
      channelId: channel['id'] as int,
      state: value,
    );
    if (ack['state'] != null) d['state'] = ack['state'];
    // Cloud ACK confirms this operation but does not contain a state payload.
    if (ack['state'] == null) {
      d['state'] ??= <String, dynamic>{};
      d['state']['gpio'] ??= <String, dynamic>{};
      d['state']['gpio']['${channel['pin']}'] = value;
    }
    d['local_online'] = network.modes[d['sn']] == 'Lokal';
    for (final owned in devices) {
      if (owned['sn'] == d['sn']) {
        owned['state'] = d['state'];
        owned['local_online'] = d['local_online'];
      }
    }
  }

  Widget _emptyState() => Card(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        children: [
          const Icon(
            Icons.add_home_work_outlined,
            size: 44,
            color: Color(0xff2d6655),
          ),
          const SizedBox(height: 12),
          const Text(
            'Belum ada perangkat',
            style: TextStyle(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 5),
          Text(
            'Tambahkan perangkat dengan memindai QR code.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.grey),
          ),
        ],
      ),
    ),
  );

  Widget _errorBanner() => Container(
    margin: const EdgeInsets.only(bottom: 12),
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: const Color(0xffffebe7),
      borderRadius: BorderRadius.circular(14),
    ),
    child: Text(error!, style: const TextStyle(color: Color(0xffa2463f))),
  );

  void _accountDialog(BuildContext context) => showDialog<void>(
    context: context,
    builder: (c) => AlertDialog(
      title: const Text('Akun'),
      content: Text('${user['name'] ?? ''}\n${user['email'] ?? ''}'),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(c),
          child: const Text('Tutup'),
        ),
        FilledButton(
          onPressed: () {
            Navigator.pop(c);
            run(() async {
              try {
                await api.logout();
              } finally {
                await network.clear();
                setState(() {
                  user = null;
                  devices = [];
                });
              }
            });
          },
          child: const Text('Keluar'),
        ),
      ],
    ),
  );
}

class _AutomationPage extends StatefulWidget {
  const _AutomationPage({required this.api, required this.devices});
  final Api api;
  final List<dynamic> devices;

  @override
  State<_AutomationPage> createState() => _AutomationPageState();
}

class _AutomationPageState extends State<_AutomationPage>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  List<dynamic> scenes = [], schedules = [], automations = [];
  bool loading = true, busy = false;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _tabController.addListener(() {
      if (mounted) setState(() {});
    });
    _load();
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final result = await Future.wait([
        widget.api.scenes(),
        widget.api.schedules(),
        widget.api.automations().catchError((_) => <dynamic>[]),
      ]);
      if (mounted) {
        setState(() {
          scenes = result[0];
          schedules = result[1];
          automations = result[2];
          loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => loading = false);
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  List<dynamic> get relayDevices => widget.devices.where((d) {
    final channels = d['channels'];
    return channels is List &&
        channels.any((c) => c is Map && c['type'] == 'switch');
  }).toList();

  String _scheduleRelayLabel(dynamic schedule) {
    final scene = scenes.cast<dynamic>().firstWhere(
      (item) => item is Map && item['id'] == schedule['scene_id'],
      orElse: () => null,
    );
    final actions = scene is Map && scene['actions'] is List
        ? scene['actions'] as List
        : const [];
    final device = widget.devices.cast<dynamic>().firstWhere(
      (item) => item is Map && item['sn'] == schedule['device_sn'],
      orElse: () => null,
    );
    final channels = device is Map && device['channels'] is List
        ? device['channels'] as List
        : const [];
    final labels = actions
        .map((action) {
          if (action is! Map) return null;
          final channel = channels.cast<dynamic>().firstWhere(
            (item) =>
                item is Map && '${item['id']}' == '${action['channel_id']}',
            orElse: () => null,
          );
          if (channel is Map) {
            final alias = channel['alias'] ?? channel['name'];
            if (alias != null && '$alias'.trim().isNotEmpty) return '$alias';
          }
          return 'Relay ${action['channel_id']}';
        })
        .whereType<String>()
        .toList();
    return labels.isEmpty ? 'Relay tidak diketahui' : labels.join(', ');
  }

  String _scheduleActivityLabel(dynamic schedule) {
    final scene = scenes.cast<dynamic>().firstWhere(
      (item) => item is Map && item['id'] == schedule['scene_id'],
      orElse: () => null,
    );
    final actions = scene is Map && scene['actions'] is List
        ? scene['actions'] as List
        : const [];
    final labels = actions
        .whereType<Map>()
        .map((action) => action['state'] == true ? 'Hidupkan' : 'Matikan')
        .toSet()
        .toList();
    return labels.isEmpty ? 'Aktivitas tidak diketahui' : labels.join(', ');
  }

  Color _scheduleActivityColor(dynamic schedule) {
    final scene = scenes.cast<dynamic>().firstWhere(
      (item) => item is Map && item['id'] == schedule['scene_id'],
      orElse: () => null,
    );
    final actions = scene is Map && scene['actions'] is List
        ? scene['actions'] as List
        : const [];
    final states = actions
        .whereType<Map>()
        .map((action) => action['state'] == true)
        .toSet();
    if (states.length == 1 && states.first) return const Color(0xff2e7d32);
    if (states.length == 1 && !states.first) return const Color(0xffc62828);
    return const Color(0xff8a6d1d);
  }

  Future<void> _addSchedule({dynamic existing}) async {
    if (relayDevices.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Belum ada perangkat relay yang dapat dijadwalkan.'),
        ),
      );
      return;
    }
    dynamic existingScene;
    if (existing != null) {
      for (final scene in scenes) {
        if (scene['id'] == existing['scene_id']) {
          existingScene = scene;
          break;
        }
      }
    }
    final defaultDevice = existing == null
        ? relayDevices.first
        : relayDevices.firstWhere(
            (d) => d['sn'] == existing['device_sn'],
            orElse: () => relayDevices.first,
          );
    final name = TextEditingController(
      text: existing?['name'] as String? ?? 'Matikan relay',
    );
    final existingTime = existing?['time_local'] as String? ?? '10:00';
    TimeOfDay selectedTime = TimeOfDay(
      hour: int.parse(existingTime.substring(0, 2)),
      minute: int.parse(existingTime.substring(3, 5)),
    );
    String deviceSn = defaultDevice['sn'] as String;
    final existingActions =
        existingScene is Map && existingScene['actions'] is List
        ? existingScene['actions'] as List
        : const [];
    final selectedChannelIds = <String>{
      for (final action in existingActions)
        if (action is Map) '${action['channel_id']}',
    };
    final firstChannel = (defaultDevice['channels'] as List).firstWhere(
      (c) => c['type'] == 'switch',
    );
    if (selectedChannelIds.isEmpty) {
      selectedChannelIds.add('${firstChannel['id']}');
    }
    final existingAction = existingActions.isNotEmpty
        ? existingActions.first
        : null;
    bool state = existingAction?['state'] == true;
    String formatTime(TimeOfDay value) =>
        '${value.hour.toString().padLeft(2, '0')}:${value.minute.toString().padLeft(2, '0')}';
    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, update) {
          final device = relayDevices.firstWhere((d) => d['sn'] == deviceSn);
          final channels = (device['channels'] as List)
              .where((c) => c['type'] == 'switch')
              .toList();
          selectedChannelIds.removeWhere(
            (id) => !channels.any((c) => '${c['id']}' == id),
          );
          if (selectedChannelIds.isEmpty && channels.isNotEmpty) {
            selectedChannelIds.add('${channels.first['id']}');
          }
          return AlertDialog(
            title: Text(
              existing == null ? 'Jadwal baru' : 'Edit scene & jadwal',
            ),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: name,
                    decoration: const InputDecoration(labelText: 'Nama scene'),
                  ),
                  const SizedBox(height: 10),
                  DropdownButtonFormField<String>(
                    initialValue: deviceSn,
                    decoration: const InputDecoration(labelText: 'Perangkat'),
                    items: relayDevices
                        .map(
                          (d) => DropdownMenuItem(
                            value: d['sn'] as String,
                            child: Text('${d['name'] ?? d['sn']}'),
                          ),
                        )
                        .toList(),
                    onChanged: existing == null
                        ? (value) => update(() {
                            if (value != null) {
                              deviceSn = value;
                            }
                          })
                        : null,
                  ),
                  const SizedBox(height: 10),
                  const Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      'Relay yang dikendalikan',
                      style: TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                  ...channels.map(
                    (channel) => CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      title: Text(
                        '${channel['alias'] ?? channel['name'] ?? 'Relay ${channel['id']}'}',
                      ),
                      value: selectedChannelIds.contains('${channel['id']}'),
                      onChanged: (checked) => update(() {
                        final id = '${channel['id']}';
                        if (checked == true) {
                          selectedChannelIds.add(id);
                        } else if (selectedChannelIds.length > 1) {
                          selectedChannelIds.remove(id);
                        }
                      }),
                    ),
                  ),
                  const SizedBox(height: 4),
                  const Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      'Semua relay yang dipilih memakai aksi yang sama.',
                      style: TextStyle(fontSize: 12),
                    ),
                  ),
                  const SizedBox(height: 10),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Waktu'),
                    subtitle: Text(formatTime(selectedTime)),
                    trailing: const Icon(Icons.access_time),
                    onTap: () async {
                      final picked = await showTimePicker(
                        context: context,
                        initialTime: selectedTime,
                      );
                      if (picked != null) update(() => selectedTime = picked);
                    },
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(state ? 'Hidupkan' : 'Matikan'),
                    value: state,
                    onChanged: (value) => update(() => state = value),
                  ),
                  const Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      'Berulang setiap hari • Asia/Jakarta',
                      style: TextStyle(fontSize: 12),
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('Batal'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(dialogContext, {
                  'name': name.text.trim(),
                  'time': formatTime(selectedTime),
                  'device': deviceSn,
                  'channels': selectedChannelIds.map(int.parse).toList(),
                  'state': state,
                }),
                child: const Text('Simpan'),
              ),
            ],
          );
        },
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 300));
    await WidgetsBinding.instance.endOfFrame;
    name.dispose();
    if (result == null || result['name'] == '') {
      if (result != null && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Nama scene wajib diisi.')),
        );
      }
      return;
    }
    final selectedChannels =
        (result['channels'] as List?)?.cast<int>() ?? const <int>[];
    if (selectedChannels.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Pilih minimal satu relay.')),
        );
      }
      return;
    }
    setState(() => busy = true);
    try {
      final sceneBody = {
        'name': result['name'],
        'actions': [
          for (final channel in selectedChannels)
            {'channel_id': channel, 'state': result['state']},
        ],
      };
      final scene = existing == null
          ? await widget.api.createScene(
              result['device'] as String,
              result['name'] as String,
              sceneBody['actions'] as List<Map<String, dynamic>>,
            )
          : await widget.api.updateScene(
              existing['scene_id'] as String,
              sceneBody,
            );
      final scheduleBody = {
        'name': result['name'],
        'scene_id': scene['id'],
        'time_local': result['time'],
        'timezone': 'Asia/Jakarta',
        'weekdays': [0, 1, 2, 3, 4, 5, 6],
        'enabled': true,
      };
      if (existing == null) {
        await widget.api.createSchedule(
          result['device'] as String,
          scheduleBody,
        );
      } else {
        await widget.api.updateSchedule(existing['id'] as String, scheduleBody);
      }
      await _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('$e')));
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _deleteSchedule(dynamic schedule) async {
    final yes =
        await showDialog<bool>(
          context: context,
          builder: (c) => AlertDialog(
            title: const Text('Hapus jadwal?'),
            content: Text('${schedule['name']} akan dihapus.'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(c, false),
                child: const Text('Batal'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(c, true),
                child: const Text('Hapus'),
              ),
            ],
          ),
        ) ??
        false;
    if (!yes) return;
    try {
      await widget.api.deleteSchedule(schedule['id'] as String);
      await _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  Future<void> _addAutomation() async {
    if (widget.devices.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Belum ada perangkat yang terdaftar.')),
      );
      return;
    }

    final nameCtrl = TextEditingController(text: 'Kipas Otomatis Suhu');
    final thresholdCtrl = TextEditingController(text: '28');
    final cooldownCtrl = TextEditingController(text: '60');

    String triggerDeviceId = widget.devices.first['id'] as String;
    String triggerMetric = 'temperature_c';
    String operator = '>=';
    String actionDeviceId = (relayDevices.isNotEmpty ? relayDevices.first : widget.devices.first)['id'] as String;
    int actionChannelIndex = 1;
    bool actionState = true;

    final metrics = [
      {'val': 'temperature_c', 'label': 'Suhu (°C)'},
      {'val': 'humidity_percent', 'label': 'Kelembaban (%)'},
      {'val': 'power_w', 'label': 'Daya Listrik (W)'},
      {'val': 'voltage_v', 'label': 'Tegangan (V)'},
      {'val': 'current_a', 'label': 'Arus Listrik (A)'},
      {'val': 'energy_kwh', 'label': 'Energi (kWh)'},
    ];

    final operators = [
      {'val': '>=', 'label': '>= (Lebih dari / sama dengan)'},
      {'val': '>', 'label': '> (Lebih dari)'},
      {'val': '<=', 'label': '<= (Kurang dari / sama dengan)'},
      {'val': '<', 'label': '< (Kurang dari)'},
      {'val': '==', 'label': '== (Sama dengan)'},
    ];

    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, update) {
          final targetDev = widget.devices.firstWhere(
            (d) => d['id'] == actionDeviceId,
            orElse: () => widget.devices.first,
          );
          final channels = targetDev['channels'] is List
              ? (targetDev['channels'] as List).where((c) => c is Map && c['type'] == 'switch').toList()
              : const [];

          return AlertDialog(
            title: const Text('Aturan Otomatisasi Baru'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextField(
                    controller: nameCtrl,
                    decoration: const InputDecoration(labelText: 'Nama Aturan'),
                  ),
                  const SizedBox(height: 12),
                  const Text('Kondisi Pemicu (IF)', style: TextStyle(fontWeight: FontWeight.bold, color: Color(0xff2e7d32))),
                  const SizedBox(height: 6),
                  DropdownButtonFormField<String>(
                    initialValue: triggerDeviceId,
                    decoration: const InputDecoration(labelText: 'Perangkat Sensor'),
                    items: widget.devices.map((d) => DropdownMenuItem(
                      value: d['id'] as String,
                      child: Text('${d['name'] ?? d['sn']}'),
                    )).toList(),
                    onChanged: (val) => update(() { if (val != null) triggerDeviceId = val; }),
                  ),
                  const SizedBox(height: 8),
                  DropdownButtonFormField<String>(
                    initialValue: triggerMetric,
                    decoration: const InputDecoration(labelText: 'Parameter Sensor'),
                    items: metrics.map((m) => DropdownMenuItem(
                      value: m['val']!,
                      child: Text(m['label']!),
                    )).toList(),
                    onChanged: (val) => update(() { if (val != null) triggerMetric = val; }),
                  ),
                  const SizedBox(height: 8),
                  DropdownButtonFormField<String>(
                    initialValue: operator,
                    decoration: const InputDecoration(labelText: 'Operator'),
                    items: operators.map((o) => DropdownMenuItem(
                      value: o['val']!,
                      child: Text(o['label']!),
                    )).toList(),
                    onChanged: (val) => update(() { if (val != null) operator = val; }),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: thresholdCtrl,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(labelText: 'Nilai Ambang (Threshold)'),
                  ),
                  const SizedBox(height: 16),
                  const Text('Tindakan Target (THEN)', style: TextStyle(fontWeight: FontWeight.bold, color: Color(0xff1565c0))),
                  const SizedBox(height: 6),
                  DropdownButtonFormField<String>(
                    initialValue: actionDeviceId,
                    decoration: const InputDecoration(labelText: 'Perangkat Saklar'),
                    items: widget.devices.map((d) => DropdownMenuItem(
                      value: d['id'] as String,
                      child: Text('${d['name'] ?? d['sn']}'),
                    )).toList(),
                    onChanged: (val) => update(() {
                      if (val != null) {
                        actionDeviceId = val;
                        actionChannelIndex = 1;
                      }
                    }),
                  ),
                  const SizedBox(height: 8),
                  DropdownButtonFormField<int>(
                    initialValue: actionChannelIndex,
                    decoration: const InputDecoration(labelText: 'Saluran Relay'),
                    items: channels.isNotEmpty
                        ? channels.map<DropdownMenuItem<int>>((c) {
                            final idx = c['index'] ?? c['id'] ?? 1;
                            return DropdownMenuItem<int>(
                              value: idx as int,
                              child: Text('Saluran $idx (${c['alias'] ?? c['name'] ?? 'Relay $idx'})'),
                            );
                          }).toList()
                        : const [
                            DropdownMenuItem<int>(value: 1, child: Text('Saluran 1')),
                            DropdownMenuItem<int>(value: 2, child: Text('Saluran 2')),
                          ],
                    onChanged: (val) => update(() { if (val != null) actionChannelIndex = val; }),
                  ),
                  const SizedBox(height: 8),
                  DropdownButtonFormField<bool>(
                    initialValue: actionState,
                    decoration: const InputDecoration(labelText: 'Perintah Saklar'),
                    items: const [
                      DropdownMenuItem<bool>(value: true, child: Text('🟢 Hidupkan (ON)')),
                      DropdownMenuItem<bool>(value: false, child: Text('🔴 Matikan (OFF)')),
                    ],
                    onChanged: (val) => update(() { if (val != null) actionState = val; }),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: cooldownCtrl,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: 'Jeda / Cooldown (detik)'),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('Batal')),
              FilledButton(
                onPressed: () {
                  final th = double.tryParse(thresholdCtrl.text.trim()) ?? 0;
                  final cd = int.tryParse(cooldownCtrl.text.trim()) ?? 60;
                  Navigator.pop(dialogContext, {
                    'name': nameCtrl.text.trim(),
                    'trigger_device_id': triggerDeviceId,
                    'trigger_metric': triggerMetric,
                    'operator': operator,
                    'threshold_value': th,
                    'action_device_id': actionDeviceId,
                    'action_type': 'switch_channel',
                    'action_channel_index': actionChannelIndex,
                    'action_state': actionState,
                    'cooldown_seconds': cd,
                    'enabled': true,
                  });
                },
                child: const Text('Simpan'),
              ),
            ],
          );
        },
      ),
    );

    if (result == null) return;
    setState(() => busy = true);
    try {
      await widget.api.createAutomation(result);
      await _load();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Aturan otomatisasi berhasil dibuat.')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _toggleAutomation(dynamic auto) async {
    try {
      final newEnabled = auto['enabled'] != true;
      await widget.api.updateAutomation(auto['id'] as String, {'enabled': newEnabled});
      await _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  Future<void> _deleteAutomation(dynamic auto) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Hapus otomatisasi?'),
        content: Text('${auto['name']} akan dihapus.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Batal')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Hapus')),
        ],
      ),
    ) ?? false;
    if (!yes) return;
    try {
      await widget.api.deleteAutomation(auto['id'] as String);
      await _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  Widget _buildScheduleTab() {
    if (schedules.isEmpty) {
      return const Center(child: Text('Belum ada jadwal.'));
    }
    return ListView.separated(
      padding: const EdgeInsets.all(20),
      itemCount: schedules.length,
      separatorBuilder: (context, index) => const SizedBox(height: 10),
      itemBuilder: (context, index) {
        final s = schedules[index];
        final relayLabel = _scheduleRelayLabel(s);
        final activityLabel = _scheduleActivityLabel(s);
        final activityColor = _scheduleActivityColor(s);
        return Card(
          color: activityColor.withValues(alpha: 0.10),
          child: ListTile(
            leading: CircleAvatar(
              backgroundColor: activityColor.withValues(alpha: 0.18),
              foregroundColor: activityColor,
              child: Icon(
                activityLabel == 'Hidupkan'
                    ? Icons.power
                    : Icons.power_off,
              ),
            ),
            title: Text(
              '${s['time_local']} • $activityLabel : $relayLabel',
            ),
            subtitle: Text(
              '${s['device_sn']} • ${s['scene_name']}\nSetiap hari • ${s['timezone']}',
            ),
            isThreeLine: true,
            trailing: Wrap(
              children: [
                IconButton(
                  onPressed: () => _addSchedule(existing: s),
                  icon: const Icon(Icons.edit_outlined),
                ),
                IconButton(
                  onPressed: () => _deleteSchedule(s),
                  icon: const Icon(Icons.delete_outline),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildAutomationTab() {
    if (automations.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.bolt, size: 48, color: Colors.grey),
              const SizedBox(height: 12),
              const Text(
                'Belum ada aturan otomatisasi.',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
              ),
              const SizedBox(height: 6),
              const Text(
                'Hubungkan nilai sensor (suhu, daya) dari satu perangkat untuk otomatis menyalakan/mematikan saklar di perangkat lain.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.grey),
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: busy ? null : _addAutomation,
                icon: const Icon(Icons.add),
                label: const Text('Buat Otomatisasi'),
              ),
            ],
          ),
        ),
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.all(20),
      itemCount: automations.length,
      separatorBuilder: (context, index) => const SizedBox(height: 10),
      itemBuilder: (context, index) {
        final a = automations[index];
        final enabled = a['enabled'] == true;
        final metricName = a['trigger_metric'] == 'temperature_c'
            ? 'Suhu'
            : a['trigger_metric'] == 'humidity_percent'
                ? 'Kelembaban'
                : a['trigger_metric'] == 'power_w'
                    ? 'Daya Listrik'
                    : a['trigger_metric'];
        return Card(
          elevation: enabled ? 2 : 0,
          color: enabled ? null : Colors.grey.withValues(alpha: 0.08),
          child: ListTile(
            leading: CircleAvatar(
              backgroundColor: enabled ? const Color(0xff2e7d32).withValues(alpha: 0.15) : Colors.grey.withValues(alpha: 0.2),
              foregroundColor: enabled ? const Color(0xff2e7d32) : Colors.grey,
              child: const Icon(Icons.bolt),
            ),
            title: Text(
              '${a['name']}',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                color: enabled ? null : Colors.grey,
              ),
            ),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 4),
                Text(
                  'IF: ${a['trigger_device_name'] ?? a['trigger_device_sn']} ($metricName ${a['operator']} ${a['threshold_value']})',
                  style: const TextStyle(fontSize: 12),
                ),
                Text(
                  'THEN: ${a['action_device_name'] ?? a['action_device_sn']} (Relay ${a['action_channel_index']} ➔ ${a['action_state'] == true ? 'ON' : 'OFF'})',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: a['action_state'] == true ? const Color(0xff2e7d32) : const Color(0xffc62828),
                  ),
                ),
                Text(
                  'Cooldown: ${a['cooldown_seconds'] ?? 60} dtk',
                  style: const TextStyle(fontSize: 11, color: Colors.grey),
                ),
              ],
            ),
            isThreeLine: true,
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Switch(
                  value: enabled,
                  onChanged: (_) => _toggleAutomation(a),
                ),
                IconButton(
                  onPressed: () => _deleteAutomation(a),
                  icon: const Icon(Icons.delete_outline),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Scene & Otomatisasi'),
      bottom: TabBar(
        controller: _tabController,
        tabs: const [
          Tab(icon: Icon(Icons.schedule), text: 'Jadwal'),
          Tab(icon: Icon(Icons.bolt), text: 'Otomatisasi'),
        ],
      ),
      actions: [
        IconButton(
          onPressed: loading ? null : _load,
          icon: const Icon(Icons.refresh),
        ),
      ],
    ),
    floatingActionButton: FloatingActionButton.extended(
      onPressed: busy ? null : (_tabController.index == 0 ? _addSchedule : _addAutomation),
      icon: Icon(_tabController.index == 0 ? Icons.add_alarm : Icons.add),
      label: Text(_tabController.index == 0 ? 'Jadwal' : 'Otomatisasi'),
    ),
    body: loading
        ? const Center(child: CircularProgressIndicator())
        : TabBarView(
            controller: _tabController,
            children: [
              _buildScheduleTab(),
              _buildAutomationTab(),
            ],
          ),
  );
}

class _DeviceDetailPage extends StatefulWidget {
  const _DeviceDetailPage({
    required this.device,
    required this.onToggle,
    required this.onRefresh,
    required this.onProvision,
    required this.onHistory,
    this.onPowerHistory,
    required this.onAlias,
    required this.onUnclaim,
  });
  final dynamic device;
  final Future<void> Function(dynamic device, dynamic channel, bool value)
  onToggle;
  final Future<void> Function() onRefresh;
  final Future<void> Function() onProvision;
  final Future<List<dynamic>> Function(int rangeHours, int bucketMinutes)
  onHistory;
  final Future<List<dynamic>> Function(int rangeHours, int bucketMinutes)?
  onPowerHistory;
  final Future<void> Function(int channelId, String alias) onAlias;
  final Future<bool> Function() onUnclaim;

  @override
  State<_DeviceDetailPage> createState() => _DeviceDetailPageState();
}

class _DeviceDetailPageState extends State<_DeviceDetailPage> {
  bool busy = false;
  bool bulkBusy = false;
  final Set<int> busyChannels = <int>{};
  String? currentWifiSsid;
  bool refreshing = false;
  Timer? sensorTimer;

  // Temperature history
  List<dynamic> history = const [];
  int historyRangeHours = 24;
  int historyBucketMinutes = 30;
  bool historyLoading = false;
  int? selectedHistoryIndex;

  // Power history
  List<dynamic> powerHistory = const [];
  int powerHistoryRangeHours = 24;
  int powerHistoryBucketMinutes = 30;
  bool powerHistoryLoading = false;
  int? selectedPowerHistoryIndex;

  bool get hasRelay {
    final channels = widget.device['channels'] as List? ?? [];
    return channels.any((c) => c['type'] == 'switch');
  }

  bool get hasTemp {
    final type = widget.device['device_type']?.toString();
    final channels = widget.device['channels'] as List? ?? [];
    final state = widget.device['state'] ?? {};
    return type == 'sensor' ||
        type == 'switch_temp' ||
        type == 'switch_temp_power' ||
        channels.any((c) => c['type'] == 'sensor') ||
        state['temperature_c'] != null;
  }

  bool get hasPower {
    final type = widget.device['device_type']?.toString();
    final state = widget.device['state'] ?? {};
    return type == 'power_meter' ||
        type == 'switch_power' ||
        type == 'switch_temp_power' ||
        state['voltage_v'] != null;
  }

  @override
  void initState() {
    super.initState();
    if (hasTemp) {
      unawaited(_loadHistory());
    }
    if (hasPower) {
      unawaited(_loadPowerHistory());
    }
    if (hasTemp || hasPower) {
      sensorTimer = Timer.periodic(const Duration(seconds: 2), (_) {
        unawaited(_refreshSensor());
      });
    }
  }

  @override
  void dispose() {
    sensorTimer?.cancel();
    super.dispose();
  }

  Future<void> _toggleChannel(
    dynamic device,
    dynamic channel,
    bool value,
  ) async {
    final channelId = channel['id'] as int;
    if (busyChannels.contains(channelId)) return;
    setState(() => busyChannels.add(channelId));
    try {
      await widget.onToggle(device, channel, value);
    } finally {
      if (mounted) setState(() => busyChannels.remove(channelId));
    }
  }

  Future<void> _toggleAllChannels(
    dynamic device,
    List<dynamic> channels,
    bool value,
  ) async {
    if (bulkBusy || channels.isEmpty) return;
    setState(() => bulkBusy = true);
    try {
      for (var index = 0; index < channels.length; index++) {
        await widget.onToggle(device, channels[index], value);
        if (index < channels.length - 1) {
          await Future<void>.delayed(const Duration(milliseconds: 150));
        }
      }
    } finally {
      if (mounted) setState(() => bulkBusy = false);
    }
  }

  Future<void> _refreshSensor() async {
    if (refreshing || busy) return;
    refreshing = true;
    try {
      await widget.onRefresh();
      if (hasTemp) {
        unawaited(_loadHistory(silent: true));
      }
      if (hasPower) {
        unawaited(_loadPowerHistory(silent: true));
      }
      if (mounted) setState(() {});
    } catch (_) {
      // Keep the last valid reading visible during a temporary disconnect.
    } finally {
      refreshing = false;
    }
  }

  Future<void> _loadHistory({bool silent = false}) async {
    if (historyLoading) return;
    historyLoading = true;
    try {
      final values = await widget.onHistory(
        historyRangeHours,
        historyBucketMinutes,
      );
      if (mounted) setState(() => history = values);
    } catch (_) {
      if (!silent && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Riwayat suhu belum tersedia.')),
        );
      }
    } finally {
      historyLoading = false;
    }
  }

  Future<void> _changeHistory(int rangeHours, int bucketMinutes) async {
    if (historyRangeHours == rangeHours &&
        historyBucketMinutes == bucketMinutes) {
      return;
    }
    setState(() {
      historyRangeHours = rangeHours;
      historyBucketMinutes = bucketMinutes;
      selectedHistoryIndex = null;
    });
    await _loadHistory();
  }

  Future<void> _loadPowerHistory({bool silent = false}) async {
    if (powerHistoryLoading || widget.onPowerHistory == null) return;
    powerHistoryLoading = true;
    try {
      final values = await widget.onPowerHistory!(
        powerHistoryRangeHours,
        powerHistoryBucketMinutes,
      );
      if (mounted) setState(() => powerHistory = values);
    } catch (_) {
      if (!silent && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Riwayat daya belum tersedia.')),
        );
      }
    } finally {
      powerHistoryLoading = false;
    }
  }

  Future<void> _changePowerHistory(int rangeHours, int bucketMinutes) async {
    if (powerHistoryRangeHours == rangeHours &&
        powerHistoryBucketMinutes == bucketMinutes) {
      return;
    }
    setState(() {
      powerHistoryRangeHours = rangeHours;
      powerHistoryBucketMinutes = bucketMinutes;
      selectedPowerHistoryIndex = null;
    });
    await _loadPowerHistory();
  }

  String _formatRupiah(num amount) {
    final integerPart = amount.round().toString();
    final buffer = StringBuffer();
    var count = 0;
    for (var i = integerPart.length - 1; i >= 0; i--) {
      buffer.write(integerPart[i]);
      count++;
      if (count % 3 == 0 && i > 0) {
        buffer.write('.');
      }
    }
    return 'Rp ${buffer.toString().split('').reversed.join('')}';
  }

  double? _historyNumber(dynamic value) =>
      value is num ? value.toDouble() : double.tryParse('${value ?? ''}');

  @override
  Widget build(BuildContext context) {
    final device = widget.device;
    final state = device['state'] ?? {};
    currentWifiSsid = (state['wifi_ssid'] ?? device['wifi_ssid'])?.toString();
    final online = device['online'] == true || device['local_online'] == true;
    final isLocal = device['local_online'] == true;
    final name = '${device['name'] ?? device['sn']}';
    final model = '${device['model'] ?? 'Perangkat RizIO'}';

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          tooltip: 'Kembali',
          onPressed: () => Navigator.pop(context),
          icon: const Icon(Icons.arrow_back),
        ),
        title: Text(
          name,
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
        actions: [
          IconButton(
            tooltip: 'Pengaturan perangkat',
            onPressed: () => _showInfo(context, device, state),
            icon: const Icon(Icons.settings_outlined),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _refreshSensor,
        color: const Color(0xff0d9488),
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 40),
          children: [
            // Top Status & Badges
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        model,
                        style: TextStyle(
                          color: Colors.blueGrey.shade700,
                          fontWeight: FontWeight.w600,
                          fontSize: 14,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'SN: ${device['sn']}',
                        style: TextStyle(
                          color: Colors.grey.shade500,
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: online
                        ? const Color(0xffe7f5ed)
                        : const Color(0xffffece9),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        online ? Icons.circle : Icons.circle_outlined,
                        size: 9,
                        color: online
                            ? const Color(0xff23834d)
                            : const Color(0xffc04d45),
                      ),
                      const SizedBox(width: 5),
                      Text(
                        online
                            ? (isLocal ? 'Online · LAN' : 'Online · Cloud')
                            : 'Offline',
                        style: TextStyle(
                          color: online
                              ? const Color(0xff1c7042)
                              : const Color(0xffa83d36),
                          fontWeight: FontWeight.w700,
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 18),

            // If device is pure switch (no power, no temp), show pure switch hero
            if (hasRelay && !hasPower && !hasTemp) ...[
              _pureSwitchHero(device, state, online),
              const SizedBox(height: 24),
            ],

            // 1. AC Power Meter Section (if hasPower)
            if (hasPower) ...[
              _powerMonitorHeroCard(state, online),
              const SizedBox(height: 14),
              _powerMetricsGrid(state),
              const SizedBox(height: 20),
              _powerHistoryCard(),
              const SizedBox(height: 24),
            ],

            // 2. Environment Sensor Section (if hasTemp)
            if (hasTemp) ...[
              _environmentSensorCard(state, online),
              const SizedBox(height: 20),
              _temperatureHistoryCard(),
              const SizedBox(height: 24),
            ],

            // 3. Relay Controls Section (if hasRelay)
            if (hasRelay) ...[
              _relayControlsSection(device, state, online),
              const SizedBox(height: 24),
            ],

            // 4. Device Details Card
            _sectionTitle('Detail Perangkat'),
            const SizedBox(height: 10),
            Card(
              elevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20),
                side: const BorderSide(color: Color(0xffe2e8e4)),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Column(
                  children: [
                    _infoTile(Icons.memory_outlined, 'Model', model),
                    _infoTile(
                      Icons.tag_outlined,
                      'Nomor seri',
                      '${device['sn'] ?? '—'}',
                    ),
                    _infoTile(
                      Icons.router_outlined,
                      'Koneksi',
                      online
                          ? (isLocal ? 'Lokal (LAN)' : 'Cloud (MQTT)')
                          : 'Tidak terhubung',
                    ),
                    _infoTile(
                      Icons.wifi,
                      'Sinyal',
                      '${state['rssi'] ?? '—'}',
                    ),
                    _infoTile(
                      Icons.system_update_alt_outlined,
                      'Firmware',
                      '${device['firmware_version'] ?? '—'}',
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 20),

            // 5. Quick Actions Card
            _sectionTitle('Aksi Cepat'),
            const SizedBox(height: 10),
            Card(
              elevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20),
                side: const BorderSide(color: Color(0xffe2e8e4)),
              ),
              child: Column(
                children: [
                  ListTile(
                    leading: const Icon(Icons.wifi, color: Color(0xff2d6655)),
                    title: const Text('Hubungkan Wi-Fi'),
                    subtitle: const Text('Ubah koneksi Wi-Fi perangkat'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () async {
                      Navigator.pop(context);
                      await widget.onProvision();
                    },
                  ),
                  const Divider(height: 1, indent: 56),
                  ListTile(
                    leading: const Icon(
                      Icons.link_off,
                      color: Color(0xffb33a32),
                    ),
                    title: const Text('Lepaskan perangkat'),
                    subtitle: const Text('Perangkat akan keluar dari akun ini'),
                    textColor: const Color(0xffb33a32),
                    onTap: () async {
                      final deleted = await widget.onUnclaim();
                      if (!context.mounted || !deleted) return;
                      WidgetsBinding.instance.addPostFrameCallback((_) {
                        if (context.mounted) Navigator.of(context).pop();
                      });
                    },
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // --- AC Power Meter Widgets ---

  Widget _powerMonitorHeroCard(dynamic state, bool online) {
    final powerW = state['power_w'] is num
        ? (state['power_w'] as num).toDouble()
        : null;
    final energyKwh = state['energy_kwh'] is num
        ? (state['energy_kwh'] as num).toDouble()
        : null;
    final estimatedCost = (energyKwh ?? 0.0) * 1444.70;

    return Container(
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xff0d2b26), Color(0xff164e43), Color(0xff1e6053)],
        ),
        borderRadius: BorderRadius.circular(28),
        boxShadow: const [
          BoxShadow(
            color: Color(0x330d2b26),
            blurRadius: 20,
            offset: Offset(0, 10),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(22),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.white.withAlpha(30),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: const Icon(
                    Icons.bolt_rounded,
                    color: Color(0xff34d399),
                    size: 26,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Pemantau Daya Listrik AC',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'PLN 220V · PZEM-004T v3.0',
                        style: TextStyle(
                          color: Colors.white.withAlpha(190),
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 5,
                  ),
                  decoration: BoxDecoration(
                    color: online
                        ? const Color(0x3334d399)
                        : const Color(0x33ef4444),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: online
                          ? const Color(0x6634d399)
                          : const Color(0x66ef4444),
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 7,
                        height: 7,
                        decoration: BoxDecoration(
                          color: online
                              ? const Color(0xff34d399)
                              : const Color(0xffef4444),
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        online ? 'Live 2.5s' : 'Offline',
                        style: TextStyle(
                          color: online
                              ? const Color(0xff34d399)
                              : const Color(0xffef4444),
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 22),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  powerW != null ? powerW.toStringAsFixed(1) : '—',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 56,
                    height: 0.95,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -1.5,
                  ),
                ),
                const Padding(
                  padding: EdgeInsets.only(left: 8, bottom: 6),
                  child: Text(
                    'Watt',
                    style: TextStyle(
                      color: Color(0xff6ee7b7),
                      fontSize: 22,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              'Konsumsi daya aktif saat ini',
              style: TextStyle(
                color: Colors.white.withAlpha(180),
                fontSize: 13,
              ),
            ),
            const SizedBox(height: 18),
            Container(
              padding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 12,
              ),
              decoration: BoxDecoration(
                color: Colors.white.withAlpha(22),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: Colors.white.withAlpha(35)),
              ),
              child: Row(
                children: [
                  const Icon(
                    Icons.account_balance_wallet_outlined,
                    color: Color(0xff6ee7b7),
                    size: 22,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Estimasi Biaya: ${_formatRupiah(estimatedCost)}',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 14,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'Berdasarkan akumulasi ${energyKwh != null ? energyKwh.toStringAsFixed(3) : '0'} kWh (Tarif Rp 1.444,7/kWh)',
                          style: TextStyle(
                            color: Colors.white.withAlpha(170),
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _powerMetricsGrid(dynamic state) {
    final voltageV = state['voltage_v'] is num
        ? (state['voltage_v'] as num).toDouble()
        : null;
    final currentA = state['current_a'] is num
        ? (state['current_a'] as num).toDouble()
        : null;
    final energyKwh = state['energy_kwh'] is num
        ? (state['energy_kwh'] as num).toDouble()
        : null;
    final frequencyHz = state['frequency_hz'] is num
        ? (state['frequency_hz'] as num).toDouble()
        : null;
    final powerFactor = state['power_factor'] is num
        ? (state['power_factor'] as num).toDouble()
        : null;

    return Column(
      children: [
        Row(
          children: [
            Expanded(
              child: _modernMetricCard(
                icon: Icons.electric_meter_outlined,
                title: 'Tegangan AC',
                value: voltageV != null
                    ? '${voltageV.toStringAsFixed(1)} V'
                    : '— V',
                badge: voltageV != null && voltageV >= 200 && voltageV <= 240
                    ? 'Normal PLN'
                    : 'PLN 220V',
                color: const Color(0xff0d9488),
                backgroundColor: const Color(0xfff0fdfa),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _modernMetricCard(
                icon: Icons.speed_rounded,
                title: 'Arus Listrik',
                value: currentA != null
                    ? '${currentA.toStringAsFixed(3)} A'
                    : '— A',
                badge: 'Beban Arus',
                color: const Color(0xff0284c7),
                backgroundColor: const Color(0xfff0f9ff),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: _modernMetricCard(
                icon: Icons.battery_charging_full_rounded,
                title: 'Total Energi',
                value: energyKwh != null
                    ? energyKwh.toStringAsFixed(3)
                    : '—',
                badge: 'kWh',
                color: const Color(0xff16a34a),
                backgroundColor: const Color(0xfff0fdf4),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _modernMetricCard(
                icon: Icons.waves_rounded,
                title: 'PF & Frekuensi',
                value: powerFactor != null ? '$powerFactor' : '—',
                badge: frequencyHz != null
                    ? '${frequencyHz.toStringAsFixed(1)} Hz'
                    : 'Hz',
                color: const Color(0xff7c3aed),
                backgroundColor: const Color(0xfffaf5ff),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _modernMetricCard({
    required IconData icon,
    required String title,
    required String value,
    required String badge,
    required Color color,
    required Color backgroundColor,
  }) => Container(
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: backgroundColor,
      borderRadius: BorderRadius.circular(20),
      border: Border.all(color: color.withAlpha(35)),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Icon(icon, color: color, size: 22),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: color.withAlpha(25),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                badge,
                style: TextStyle(
                  color: color,
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Text(
          title,
          style: TextStyle(
            color: color.withAlpha(200),
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          value,
          style: TextStyle(
            color: color,
            fontSize: 22,
            fontWeight: FontWeight.w800,
            letterSpacing: -0.5,
          ),
        ),
      ],
    ),
  );

  Widget _powerHistoryCard() {
    final points = powerHistory
        .whereType<Map>()
        .map(
          (item) => PowerHistoryPoint(
            time: DateTime.tryParse('${item['time']}') ?? DateTime.now(),
            powerW: _historyNumber(item['power_w']),
            voltageV: _historyNumber(item['voltage_v']),
            currentA: _historyNumber(item['current_a']),
            energyKwh: _historyNumber(item['energy_kwh']),
            samples: int.tryParse('${item['samples'] ?? 0}') ?? 0,
          ),
        )
        .toList();

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(22),
        side: const BorderSide(color: Color(0xffe2e8e4)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 17, 16, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(7),
                  decoration: BoxDecoration(
                    color: const Color(0xffe6fffa),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(
                    Icons.show_chart_rounded,
                    size: 20,
                    color: Color(0xff0d9488),
                  ),
                ),
                const SizedBox(width: 10),
                const Expanded(
                  child: Text(
                    'Riwayat Pemakaian Daya',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Muat ulang grafik',
                  onPressed: powerHistoryLoading
                      ? null
                      : () => _loadPowerHistory(),
                  icon: const Icon(Icons.refresh_rounded, size: 20),
                ),
              ],
            ),
            const SizedBox(height: 2),
            Text(
              'Rata-rata konsumsi daya listrik (Watt) per interval waktu',
              style: TextStyle(
                color: Colors.blueGrey.shade600,
                fontSize: 12,
              ),
            ),
            const SizedBox(height: 12),
            SegmentedButton<int>(
              segments: const [
                ButtonSegment(value: 24, label: Text('24 Jam')),
                ButtonSegment(value: 168, label: Text('7 Hari')),
              ],
              selected: {powerHistoryRangeHours},
              onSelectionChanged: (value) => _changePowerHistory(
                value.first,
                value.first == 24 ? 30 : 60,
              ),
              showSelectedIcon: false,
              style: const ButtonStyle(
                visualDensity: VisualDensity.compact,
                textStyle: WidgetStatePropertyAll(
                  TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
                ),
              ),
            ),
            const SizedBox(height: 16),
            SizedBox(
              height: 190,
              width: double.infinity,
              child: points.isEmpty
                  ? Center(
                      child: Text(
                        powerHistoryLoading
                            ? 'Memuat riwayat daya...'
                            : 'Belum ada data daya.',
                        style: TextStyle(color: Colors.blueGrey.shade500),
                      ),
                    )
                  : LayoutBuilder(
                      builder: (context, constraints) {
                        const left = 44.0;
                        const right = 10.0;
                        const pointSpacing = 44.0;
                        final chartWidth = math
                            .max(
                              constraints.maxWidth,
                              left + right + (points.length - 1) * pointSpacing,
                            )
                            .toDouble();
                        return SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: SizedBox(
                            width: chartWidth,
                            height: 190,
                            child: GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onTapUp: (details) {
                                if (points.length == 1) {
                                  setState(() => selectedPowerHistoryIndex = 0);
                                  return;
                                }
                                final usableWidth = (chartWidth - left - right)
                                    .clamp(1.0, double.infinity);
                                final tapX = details.localPosition.dx.clamp(
                                  left,
                                  chartWidth - right,
                                );
                                final position = (tapX - left) / usableWidth;
                                final index = (position * (points.length - 1))
                                    .round()
                                    .clamp(0, points.length - 1);
                                setState(
                                  () => selectedPowerHistoryIndex = index,
                                );
                              },
                              child: CustomPaint(
                                painter: PowerChartPainter(
                                  points,
                                  selectedIndex: selectedPowerHistoryIndex,
                                ),
                              ),
                            ),
                          ),
                        );
                      },
                    ),
            ),
            if (selectedPowerHistoryIndex != null &&
                selectedPowerHistoryIndex! < points.length) ...[
              const SizedBox(height: 10),
              _powerHistoryTooltip(points[selectedPowerHistoryIndex!]),
            ],
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  width: 9,
                  height: 9,
                  decoration: const BoxDecoration(
                    color: Color(0xff0d9488),
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  'Daya Aktif (Watt)',
                  style: TextStyle(
                    color: Colors.blueGrey.shade600,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _powerHistoryTooltip(PowerHistoryPoint point) => Container(
    width: double.infinity,
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
    decoration: BoxDecoration(
      color: const Color(0xfff0fdfa),
      borderRadius: BorderRadius.circular(14),
      border: Border.all(color: const Color(0xff99f6e4)),
    ),
    child: Row(
      children: [
        const Icon(
          Icons.touch_app_outlined,
          color: Color(0xff0d9488),
          size: 20,
        ),
        const SizedBox(width: 9),
        Expanded(
          child: Text(
            '${point.time.toLocal().day.toString().padLeft(2, '0')}/${point.time.toLocal().month.toString().padLeft(2, '0')} '
            '${point.time.toLocal().hour.toString().padLeft(2, '0')}:${point.time.toLocal().minute.toString().padLeft(2, '0')}',
            style: const TextStyle(fontSize: 12, color: Color(0xff115e59)),
          ),
        ),
        Text(
          '${point.powerW?.toStringAsFixed(1) ?? '--'} W',
          style: const TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w800,
            color: Color(0xff0f766e),
          ),
        ),
        if (point.voltageV != null) ...[
          const SizedBox(width: 8),
          Text(
            '${point.voltageV!.toStringAsFixed(0)}V',
            style: const TextStyle(fontSize: 12, color: Color(0xff0284c7)),
          ),
        ],
        if (point.currentA != null) ...[
          const SizedBox(width: 6),
          Text(
            '${point.currentA!.toStringAsFixed(2)}A',
            style: const TextStyle(fontSize: 12, color: Color(0xff4b5563)),
          ),
        ],
      ],
    ),
  );

  // --- Environment Sensor Widgets ---

  Widget _environmentSensorCard(dynamic state, bool online) {
    final temperature = state is Map && state['temperature_c'] is num
        ? (state['temperature_c'] as num).toStringAsFixed(1)
        : '--';
    final humidity = state is Map && state['humidity_percent'] is num
        ? (state['humidity_percent'] as num).toStringAsFixed(1)
        : '--';

    return Column(
      children: [
        Container(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 18),
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0xff183f3a), Color(0xff2e7660)],
            ),
            borderRadius: BorderRadius.circular(28),
            boxShadow: const [
              BoxShadow(
                color: Color(0x24183f3a),
                blurRadius: 18,
                offset: Offset(0, 9),
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: Colors.white.withAlpha(28),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: const Icon(
                      Icons.thermostat,
                      color: Colors.white,
                      size: 24,
                    ),
                  ),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Text(
                      'Suhu & Kelembapan Lingkungan',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  Icon(
                    online ? Icons.sync : Icons.sync_disabled,
                    color: Colors.white.withAlpha(210),
                    size: 20,
                  ),
                ],
              ),
              const SizedBox(height: 18),
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    temperature,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 54,
                      height: .95,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -2,
                    ),
                  ),
                  const Padding(
                    padding: EdgeInsets.only(left: 8, bottom: 6),
                    child: Text(
                      '°C',
                      style: TextStyle(
                        color: Color(0xffdceee6),
                        fontSize: 24,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                online
                    ? 'Diperbarui otomatis setiap 2 detik'
                    : 'Menampilkan pembacaan terakhir',
                style: TextStyle(
                  color: Colors.white.withAlpha(190),
                  fontSize: 12,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: _sensorSummaryCard(
                icon: Icons.water_drop_outlined,
                label: 'Kelembapan',
                value: humidity,
                unit: '%',
                color: const Color(0xff1976b8),
                background: const Color(0xffeaf5ff),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _sensorSummaryCard(
                icon: Icons.air_outlined,
                label: 'Kondisi Udara',
                value: state['temperature_c'] is num &&
                        (state['temperature_c'] as num) > 30
                    ? 'Hangat'
                    : 'Normal',
                unit: '',
                color: const Color(0xff0d9488),
                background: const Color(0xfff0fdfa),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _temperatureHistoryCard() {
    final points = history
        .whereType<Map>()
        .map(
          (item) => SensorHistoryPoint(
            time: DateTime.tryParse('${item['time']}') ?? DateTime.now(),
            temperature: _historyNumber(item['temperature_c']),
            humidity: _historyNumber(item['humidity_percent']),
            samples: int.tryParse('${item['samples'] ?? 0}') ?? 0,
          ),
        )
        .where((point) => point.temperature != null)
        .toList();

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(22),
        side: const BorderSide(color: Color(0xffe2e8e4)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 17, 16, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(7),
                  decoration: BoxDecoration(
                    color: const Color(0xfffff3e0),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(
                    Icons.thermostat_outlined,
                    size: 20,
                    color: Color(0xffd66a28),
                  ),
                ),
                const SizedBox(width: 10),
                const Expanded(
                  child: Text(
                    'Riwayat Perubahan Suhu',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Muat ulang grafik',
                  onPressed: historyLoading ? null : () => _loadHistory(),
                  icon: const Icon(Icons.refresh_rounded, size: 20),
                ),
              ],
            ),
            const SizedBox(height: 2),
            Text(
              'Rata-rata pembacaan sensor suhu dalam interval waktu',
              style: TextStyle(
                color: Colors.blueGrey.shade600,
                fontSize: 12,
              ),
            ),
            const SizedBox(height: 12),
            SegmentedButton<int>(
              segments: const [
                ButtonSegment(value: 24, label: Text('24 Jam')),
                ButtonSegment(value: 168, label: Text('7 Hari')),
              ],
              selected: {historyRangeHours},
              onSelectionChanged: (value) =>
                  _changeHistory(value.first, value.first == 24 ? 30 : 60),
              showSelectedIcon: false,
              style: const ButtonStyle(
                visualDensity: VisualDensity.compact,
                textStyle: WidgetStatePropertyAll(
                  TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
                ),
              ),
            ),
            const SizedBox(height: 16),
            SizedBox(
              height: 190,
              width: double.infinity,
              child: points.isEmpty
                  ? Center(
                      child: Text(
                        historyLoading
                            ? 'Memuat histori suhu...'
                            : 'Belum ada data histori suhu.',
                        style: TextStyle(color: Colors.blueGrey.shade500),
                      ),
                    )
                  : LayoutBuilder(
                      builder: (context, constraints) {
                        const left = 36.0;
                        const right = 8.0;
                        const pointSpacing = 48.0;
                        final chartWidth = math
                            .max(
                              constraints.maxWidth,
                              left + right + (points.length - 1) * pointSpacing,
                            )
                            .toDouble();
                        return SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: SizedBox(
                            width: chartWidth,
                            height: 190,
                            child: GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onTapUp: (details) {
                                if (points.length == 1) {
                                  setState(() => selectedHistoryIndex = 0);
                                  return;
                                }
                                final usableWidth = (chartWidth - left - right)
                                    .clamp(1.0, double.infinity);
                                final tapX = details.localPosition.dx.clamp(
                                  left,
                                  chartWidth - right,
                                );
                                final position = (tapX - left) / usableWidth;
                                final index = (position * (points.length - 1))
                                    .round()
                                    .clamp(0, points.length - 1);
                                setState(() => selectedHistoryIndex = index);
                              },
                              child: CustomPaint(
                                painter: TemperatureChartPainter(
                                  points,
                                  selectedIndex: selectedHistoryIndex,
                                ),
                              ),
                            ),
                          ),
                        );
                      },
                    ),
            ),
            if (selectedHistoryIndex != null &&
                selectedHistoryIndex! < points.length) ...[
              const SizedBox(height: 10),
              _historyTooltip(points[selectedHistoryIndex!]),
            ],
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  width: 9,
                  height: 9,
                  decoration: const BoxDecoration(
                    color: Color(0xffd66a28),
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  'Suhu (°C)',
                  style: TextStyle(
                    color: Colors.blueGrey.shade600,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _historyTooltip(SensorHistoryPoint point) => Container(
    width: double.infinity,
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
    decoration: BoxDecoration(
      color: const Color(0xfffff4e9),
      borderRadius: BorderRadius.circular(14),
      border: Border.all(color: const Color(0xffffd5b2)),
    ),
    child: Row(
      children: [
        const Icon(
          Icons.touch_app_outlined,
          color: Color(0xffc55c20),
          size: 20,
        ),
        const SizedBox(width: 9),
        Expanded(
          child: Text(
            '${point.time.toLocal().day.toString().padLeft(2, '0')}/${point.time.toLocal().month.toString().padLeft(2, '0')} '
            '${point.time.toLocal().hour.toString().padLeft(2, '0')}:${point.time.toLocal().minute.toString().padLeft(2, '0')}',
            style: const TextStyle(fontSize: 12, color: Color(0xff80502e)),
          ),
        ),
        Text(
          '${point.temperature?.toStringAsFixed(1) ?? '--'} °C',
          style: const TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w800,
            color: Color(0xffb95318),
          ),
        ),
        if (point.humidity != null) ...[
          const SizedBox(width: 10),
          Text(
            '${point.humidity!.toStringAsFixed(1)}%',
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: Color(0xff2877aa),
            ),
          ),
        ],
      ],
    ),
  );

  Widget _sensorSummaryCard({
    required IconData icon,
    required String label,
    required String value,
    required String unit,
    required Color color,
    required Color background,
  }) => Container(
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: background,
      borderRadius: BorderRadius.circular(20),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, color: color, size: 23),
        const SizedBox(height: 13),
        Text(
          label,
          style: TextStyle(
            color: color.withAlpha(210),
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 4),
        RichText(
          text: TextSpan(
            style: TextStyle(color: color, fontWeight: FontWeight.w800),
            children: [
              TextSpan(text: value, style: const TextStyle(fontSize: 25)),
              if (unit.isNotEmpty)
                TextSpan(text: ' $unit', style: const TextStyle(fontSize: 14)),
            ],
          ),
        ),
      ],
    ),
  );

  // --- Relay Controls Widgets ---

  Widget _pureSwitchHero(dynamic device, dynamic state, bool online) {
    final channels = device['channels'] as List? ?? [];
    final switchChannels =
        channels.where((c) => c['type'] == 'switch').toList();
    final firstChannel =
        switchChannels.isNotEmpty ? switchChannels.first : null;
    final isOn =
        switchChannels.any((c) => state['gpio']?['${c['pin']}'] == true);

    return Column(
      children: [
        Container(
          height: 190,
          width: 190,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: isOn ? const Color(0xffe5f2e9) : const Color(0xffeef0eb),
            boxShadow: isOn
                ? [
                    BoxShadow(
                      color: const Color(0xff2d6655).withAlpha(40),
                      blurRadius: 28,
                      offset: const Offset(0, 10),
                    ),
                  ]
                : null,
          ),
          child: Icon(
            firstChannel == null
                ? Icons.devices_other
                : Icons.lightbulb_rounded,
            size: 92,
            color: isOn ? const Color(0xff2d6655) : Colors.grey.shade400,
          ),
        ),
        const SizedBox(height: 16),
        Text(
          isOn ? 'Relay Menyala' : 'Relay Mati',
          style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 4),
        Text(
          online
              ? 'Ketuk switch untuk mengontrol relay'
              : 'Perangkat sedang offline',
          style: TextStyle(color: Colors.grey.shade600, fontSize: 13),
        ),
        const SizedBox(height: 12),
        Switch.adaptive(
          value: isOn,
          onChanged: !online ||
                  switchChannels.isEmpty ||
                  bulkBusy ||
                  busyChannels.isNotEmpty
              ? null
              : (value) => _toggleAllChannels(device, switchChannels, value),
        ),
      ],
    );
  }

  Widget _relayControlsSection(
    dynamic device,
    dynamic state,
    bool online,
  ) {
    final channels = device['channels'] as List? ?? [];
    final switchChannels =
        channels.where((item) => item['type'] == 'switch').toList();
    if (switchChannels.isEmpty) return const SizedBox.shrink();

    final bulkOn = switchChannels.any(
      (item) => state['gpio']?['${item['pin']}'] == true,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            _sectionTitle(
              'Kontrol Relay (${switchChannels.length} Channel)',
            ),
            Row(
              children: [
                Text(
                  bulkOn ? 'Semua Nyala' : 'Semua Mati',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: bulkOn
                        ? const Color(0xff16a34a)
                        : Colors.grey.shade600,
                  ),
                ),
                const SizedBox(width: 6),
                Switch.adaptive(
                  value: bulkOn,
                  onChanged: !online ||
                          switchChannels.isEmpty ||
                          bulkBusy ||
                          busyChannels.isNotEmpty
                      ? null
                      : (value) => _toggleAllChannels(
                            device,
                            switchChannels,
                            value,
                          ),
                ),
              ],
            ),
          ],
        ),
        const SizedBox(height: 10),
        Card(
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
            side: const BorderSide(color: Color(0xffe2e8e4)),
          ),
          child: Column(
            children: switchChannels.map<Widget>((c) {
              final on = state['gpio']?['${c['pin']}'] == true;
              final label = (c['alias'] as String?)?.trim().isNotEmpty == true
                  ? c['alias'] as String
                  : '${c['name'] ?? 'Relay'}';
              return ListTile(
                leading: Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: on
                        ? const Color(0xffdcfce7)
                        : const Color(0xfff3f4f6),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(
                    on ? Icons.power_rounded : Icons.power_off_rounded,
                    color: on
                        ? const Color(0xff16a34a)
                        : const Color(0xff6b7280),
                    size: 24,
                  ),
                ),
                title: Text(
                  label,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                subtitle: Text(
                  'Channel ${c['id']} · GPIO ${c['pin']} · ${on ? 'Menyala' : 'Mati'}',
                  style: TextStyle(
                    color: on ? const Color(0xff15803d) : Colors.grey.shade600,
                    fontSize: 12,
                  ),
                ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      icon: const Icon(Icons.edit_outlined, size: 20),
                      onPressed: () => _editAlias(c),
                      tooltip: 'Ubah Nama',
                    ),
                    Switch.adaptive(
                      value: on,
                      onChanged: !online || busyChannels.contains(c['id'])
                          ? null
                          : (v) => _toggleChannel(device, c, v),
                    ),
                  ],
                ),
              );
            }).toList(),
          ),
        ),
      ],
    );
  }

  Widget _sectionTitle(String value) => Text(
    value,
    style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
  );

  Widget _infoTile(IconData icon, String label, String value, {String? note}) {
    final isSignal = label == 'Sinyal';
    final displayLabel = isSignal ? 'Wi-Fi' : label;
    final displayValue = isSignal &&
            currentWifiSsid != null &&
            currentWifiSsid!.trim().isNotEmpty
        ? currentWifiSsid!
        : value;
    final displayNote =
        isSignal && value != '—' ? 'Sinyal: $value dBm' : note;
    return ListTile(
      leading: Icon(icon, color: const Color(0xff2d6655)),
      title: Text(
        displayLabel,
        style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
      ),
      subtitle: displayNote == null
          ? Text(
              displayValue,
              style: const TextStyle(fontWeight: FontWeight.w600),
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  displayValue,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                Text(
                  displayNote,
                  style: TextStyle(fontSize: 9, color: Colors.grey.shade600),
                ),
              ],
            ),
    );
  }

  Future<void> _editAlias(dynamic channel) async {
    final controller = TextEditingController(
      text: (channel['alias'] ?? channel['name'] ?? '').toString(),
    );
    final alias = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Nama channel'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 100,
          decoration: const InputDecoration(labelText: 'Alias'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('Batal'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, controller.text.trim()),
            child: const Text('Simpan'),
          ),
        ],
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 300));
    await WidgetsBinding.instance.endOfFrame;
    controller.dispose();
    if (alias == null || !mounted) return;
    try {
      await widget.onAlias(channel['id'] as int, alias);
      if (!mounted) return;
      setState(() => channel['alias'] = alias);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Alias gagal disimpan: $e')));
      }
    }
  }

  void _showInfo(BuildContext context, dynamic device, dynamic state) =>
      showModalBottomSheet<void>(
        context: context,
        showDragHandle: true,
        builder: (sheetContext) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Pengaturan perangkat',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 14),
                Text('Nomor seri: ${device['sn']}'),
                Text('Hardware: ${device['hardware_version'] ?? '—'}'),
                Text('Alamat IP: ${state['ip_address'] ?? '—'}'),
                const SizedBox(height: 12),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.wifi_tethering_outlined),
                  title: const Text('Provisioning Wi-Fi'),
                  subtitle: const Text('Ganti jaringan Wi-Fi perangkat'),
                  onTap: () async {
                    Navigator.pop(sheetContext);
                    await widget.onProvision();
                  },
                ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(
                    Icons.delete_outline,
                    color: Color(0xffb33a32),
                  ),
                  title: const Text('Hapus perangkat'),
                  subtitle: const Text('Lepaskan perangkat dari akun ini'),
                  textColor: const Color(0xffb33a32),
                  onTap: () async {
                    Navigator.pop(sheetContext);
                    final deleted = await widget.onUnclaim();
                    if (!context.mounted || !deleted) return;
                    Navigator.of(context).pop();
                  },
                ),
                const SizedBox(height: 4),
                FilledButton.tonal(
                  onPressed: () => Navigator.pop(sheetContext),
                  child: const Text('Tutup'),
                ),
              ],
            ),
          ),
        ),
      );
}

class _CategoryChip extends StatelessWidget {
  const _CategoryChip({required this.label, this.selected = false});
  final String label;
  final bool selected;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(right: 8),
    child: ChoiceChip(
      label: Text(label),
      selected: selected,
      onSelected: (_) {},
      selectedColor: const Color(0xff193f3a),
      labelStyle: TextStyle(
        color: selected ? Colors.white : const Color(0xff3f4945),
      ),
      side: BorderSide(
        color: selected ? Colors.transparent : const Color(0xffdfe4df),
      ),
      backgroundColor: Colors.white,
    ),
  );
}

class SensorHistoryPoint {
  const SensorHistoryPoint({
    required this.time,
    required this.temperature,
    required this.humidity,
    required this.samples,
  });
  final DateTime time;
  final double? temperature;
  final double? humidity;
  final int samples;
}

class TemperatureChartPainter extends CustomPainter {
  TemperatureChartPainter(this.points, {this.selectedIndex});
  final List<SensorHistoryPoint> points;
  final int? selectedIndex;

  @override
  void paint(Canvas canvas, Size size) {
    const left = 36.0;
    const top = 12.0;
    const right = 8.0;
    const bottom = 28.0;
    final chart = Rect.fromLTRB(
      left,
      top,
      size.width - right,
      size.height - bottom,
    );
    final values = points.map((p) => p.temperature!).toList();
    var minValue = values.reduce(math.min);
    var maxValue = values.reduce(math.max);
    if ((maxValue - minValue).abs() < 1) {
      minValue -= 1;
      maxValue += 1;
    } else {
      final padding = (maxValue - minValue) * .15;
      minValue -= padding;
      maxValue += padding;
    }
    final grid = Paint()
      ..color = const Color(0xffe5ebe8)
      ..strokeWidth = 1;
    final line = Paint()
      ..color = const Color(0xffd66a28)
      ..strokeWidth = 3
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final fill = Paint()
      ..color = const Color(0x22d66a28)
      ..style = PaintingStyle.fill;
    final label = TextPainter(textDirection: TextDirection.ltr);
    for (var i = 0; i < 4; i++) {
      final y = chart.top + chart.height * i / 3;
      canvas.drawLine(Offset(chart.left, y), Offset(chart.right, y), grid);
      final value = maxValue - (maxValue - minValue) * i / 3;
      label.text = TextSpan(
        text: value.toStringAsFixed(1),
        style: const TextStyle(color: Color(0xff71807b), fontSize: 10),
      );
      label.layout();
      label.paint(canvas, Offset(0, y - label.height / 2));
    }
    final path = Path();
    for (var i = 0; i < points.length; i++) {
      final x = points.length == 1
          ? chart.center.dx
          : chart.left + chart.width * i / (points.length - 1);
      final y =
          chart.bottom -
          ((points[i].temperature! - minValue) / (maxValue - minValue)) *
              chart.height;
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    final area = Path.from(path)
      ..lineTo(chart.right, chart.bottom)
      ..lineTo(chart.left, chart.bottom)
      ..close();
    canvas.drawPath(area, fill);
    canvas.drawPath(path, line);
    for (var i = 0; i < points.length; i++) {
      final x = points.length == 1
          ? chart.center.dx
          : chart.left + chart.width * i / (points.length - 1);
      final y =
          chart.bottom -
          ((points[i].temperature! - minValue) / (maxValue - minValue)) *
              chart.height;
      canvas.drawCircle(
        Offset(x, y),
        4,
        Paint()..color = const Color(0xfffff7f0),
      );
      canvas.drawCircle(
        Offset(x, y),
        2.5,
        Paint()..color = const Color(0xffd66a28),
      );
      if (i == selectedIndex) {
        canvas.drawLine(
          Offset(x, chart.top),
          Offset(x, chart.bottom),
          Paint()
            ..color = const Color(0x66d66a28)
            ..strokeWidth = 1.5,
        );
        canvas.drawCircle(
          Offset(x, y),
          7,
          Paint()
            ..color = const Color(0xffd66a28)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2,
        );
      }
    }
    final indices = <int>{0, points.length ~/ 2, points.length - 1};
    for (final index in indices) {
      if (index < 0 || index >= points.length) continue;
      final x = points.length == 1
          ? chart.center.dx
          : chart.left + chart.width * index / (points.length - 1);
      final date = points[index].time.toLocal();
      final text = points.length > 48
          ? '${date.day}/${date.month}'
          : '${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
      label.text = TextSpan(
        text: text,
        style: const TextStyle(color: Color(0xff71807b), fontSize: 10),
      );
      label.layout();
      label.paint(canvas, Offset(x - label.width / 2, chart.bottom + 8));
    }
  }

  @override
  bool shouldRepaint(covariant TemperatureChartPainter oldDelegate) =>
      oldDelegate.points != points ||
      oldDelegate.selectedIndex != selectedIndex;
}

class PowerHistoryPoint {
  const PowerHistoryPoint({
    required this.time,
    required this.powerW,
    required this.voltageV,
    required this.currentA,
    required this.energyKwh,
    required this.samples,
  });
  final DateTime time;
  final double? powerW;
  final double? voltageV;
  final double? currentA;
  final double? energyKwh;
  final int samples;
}

class PowerChartPainter extends CustomPainter {
  PowerChartPainter(this.points, {this.selectedIndex});
  final List<PowerHistoryPoint> points;
  final int? selectedIndex;

  @override
  void paint(Canvas canvas, Size size) {
    const left = 44.0;
    const top = 12.0;
    const right = 10.0;
    const bottom = 28.0;
    final chart = Rect.fromLTRB(
      left,
      top,
      size.width - right,
      size.height - bottom,
    );
    final values = points.map((p) => p.powerW ?? 0.0).toList();
    if (values.isEmpty) return;
    var minValue = 0.0;
    var maxValue = values.reduce(math.max);
    if (maxValue < 10) {
      maxValue = 10;
    } else {
      maxValue = maxValue * 1.15;
    }
    final grid = Paint()
      ..color = const Color(0xffe5ebe8)
      ..strokeWidth = 1;
    final line = Paint()
      ..color = const Color(0xff0d9488)
      ..strokeWidth = 3
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final fill = Paint()
      ..color = const Color(0x240d9488)
      ..style = PaintingStyle.fill;
    final label = TextPainter(textDirection: TextDirection.ltr);

    for (var i = 0; i < 4; i++) {
      final y = chart.top + chart.height * i / 3;
      canvas.drawLine(Offset(chart.left, y), Offset(chart.right, y), grid);
      final value = maxValue - (maxValue - minValue) * i / 3;
      label.text = TextSpan(
        text: '${value.toStringAsFixed(0)} W',
        style: const TextStyle(color: Color(0xff71807b), fontSize: 10),
      );
      label.layout();
      label.paint(canvas, Offset(0, y - label.height / 2));
    }

    final path = Path();
    for (var i = 0; i < points.length; i++) {
      final x = points.length == 1
          ? chart.center.dx
          : chart.left + chart.width * i / (points.length - 1);
      final val = points[i].powerW ?? 0.0;
      final y =
          chart.bottom -
          ((val - minValue) / (maxValue - minValue)) * chart.height;
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    final area = Path.from(path)
      ..lineTo(chart.right, chart.bottom)
      ..lineTo(chart.left, chart.bottom)
      ..close();
    canvas.drawPath(area, fill);
    canvas.drawPath(path, line);

    for (var i = 0; i < points.length; i++) {
      final x = points.length == 1
          ? chart.center.dx
          : chart.left + chart.width * i / (points.length - 1);
      final val = points[i].powerW ?? 0.0;
      final y =
          chart.bottom -
          ((val - minValue) / (maxValue - minValue)) * chart.height;

      canvas.drawCircle(
        Offset(x, y),
        3.5,
        Paint()..color = const Color(0xffe6fffa),
      );
      canvas.drawCircle(
        Offset(x, y),
        2.2,
        Paint()..color = const Color(0xff0d9488),
      );

      if (i == selectedIndex) {
        canvas.drawLine(
          Offset(x, chart.top),
          Offset(x, chart.bottom),
          Paint()
            ..color = const Color(0x660d9488)
            ..strokeWidth = 1.5,
        );
        canvas.drawCircle(
          Offset(x, y),
          6.5,
          Paint()
            ..color = const Color(0xff0d9488)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2,
        );
      }
    }

    final indices = <int>{0, points.length ~/ 2, points.length - 1};
    for (final index in indices) {
      if (index < 0 || index >= points.length) continue;
      final x = points.length == 1
          ? chart.center.dx
          : chart.left + chart.width * index / (points.length - 1);
      final date = points[index].time.toLocal();
      final text = points.length > 48
          ? '${date.day}/${date.month}'
          : '${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
      label.text = TextSpan(
        text: text,
        style: const TextStyle(color: Color(0xff71807b), fontSize: 10),
      );
      label.layout();
      label.paint(canvas, Offset(x - label.width / 2, chart.bottom + 8));
    }
  }

  @override
  bool shouldRepaint(covariant PowerChartPainter oldDelegate) =>
      oldDelegate.points != points ||
      oldDelegate.selectedIndex != selectedIndex;
}

class ScanPage extends StatefulWidget {
  const ScanPage({super.key});
  @override
  State<ScanPage> createState() => _ScanPageState();
}

class _ScanPageState extends State<ScanPage> {
  bool done = false;
  final input = TextEditingController();
  @override
  void dispose() {
    input.dispose();
    super.dispose();
  }

  void accept(String raw) {
    if (done) return;
    try {
      try {
        parseSetup(raw);
      } catch (_) {
        parseClaim(raw);
      }
      done = true;
      Navigator.pop(context, raw);
    } catch (e) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(e.toString())));
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Scan QR perangkat')),
    body: Column(
      children: [
        Expanded(
          child: MobileScanner(
            onDetect: (capture) {
              for (final b in capture.barcodes) {
                if (b.rawValue != null) {
                  accept(b.rawValue!);
                  break;
                }
              }
            },
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            children: [
              TextField(
                controller: input,
                decoration: const InputDecoration(
                  labelText: 'Atau tempel URI / JSON QR',
                ),
              ),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: () => accept(input.text),
                child: const Text('Gunakan kode'),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}
