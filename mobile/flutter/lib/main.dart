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
      if (user != null && !busy && !restoring && !deletingDevice) {
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
    if (reloading || deletingDevice) return;
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
        final result = await api.request('/devices');
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
      try {
        claimData = parseSetup(raw);
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
      await reload();
      message(
        'Perangkat terdeteksi. Hubungkan ke Wi-Fi perangkat lalu isi Wi-Fi rumah.',
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
    if (device['local_online'] != true) {
      final status = await api.request(
        '/devices/${Uri.encodeComponent(device['sn'] as String)}/status',
      );
      device['online'] = status['online'] == true;
      final state = Map<String, dynamic>.from(device['state'] ?? {});
      for (final key in [
        'gpio',
        'channels',
        'rssi',
        'ip_address',
        'uptime',
        'free_heap',
        'firmware_version',
        'temperature_c',
        'humidity_percent',
      ]) {
        if (status.containsKey(key)) state[key] = status[key];
      }
      device['state'] = state;
    }
  }

  Future<void> _provisionDevice(dynamic device) async {
    final ssid = await selectWifiNetwork();
    if (ssid == null || !mounted) return;
    final values = await form(
      'Konfigurasi Wi-Fi perangkat',
      {'Kata sandi Wi-Fi': '', 'Kode setup perangkat': ''},
      secrets: {'Kata sandi Wi-Fi', 'Kode setup perangkat'},
    );
    if (values == null) return;
    await run(() async {
      final address = network.addresses[device['sn']] ?? 'http://192.168.4.1';
      await network.provision(
        ssid,
        values['Kata sandi Wi-Fi']!,
        values['Kode setup perangkat']!,
        address: address,
      );
      message(
        'Konfigurasi Wi-Fi diterima. Sambungkan HP kembali ke jaringan rumah, lalu refresh perangkat.',
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
      _statCard(Icons.schedule, '0', 'Scene', const Color(0xffeef0f6)),
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
    final state = d['state'] ?? {};
    final channels = d['channels'] as List? ?? [];
    final channel = channels.cast<dynamic>().firstWhere(
      (c) => c['type'] == 'switch',
      orElse: () => null,
    );
    final switchChannels = channels
        .where((c) => c['type'] == 'switch')
        .toList();
    final isOn =
        switchChannels.isNotEmpty &&
        switchChannels.every((c) => state['gpio']?['${c['pin']}'] == true);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: () => detail(d),
        child: Card(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
            child: Row(
              children: [
                Container(
                  height: 50,
                  width: 50,
                  decoration: BoxDecoration(
                    color: isOn
                        ? const Color(0xffe5f2e9)
                        : const Color(0xfff0f1ee),
                    borderRadius: BorderRadius.circular(15),
                  ),
                  child: Icon(
                    channel == null
                        ? Icons.devices_other
                        : Icons.lightbulb_outline,
                    color: const Color(0xff2d6655),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        d['name'] ?? sn,
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        d['local_online'] == true
                            ? 'Online · Lokal'
                            : '${d['online'] == true ? 'Online' : 'Offline'} · Cloud',
                        style: TextStyle(
                          fontSize: 12,
                          color: Colors.grey.shade600,
                        ),
                      ),
                    ],
                  ),
                ),
                if (channel != null)
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () {},
                    child: Switch(
                      value: isOn,
                      onChanged: busy
                          ? null
                          : (value) => _toggleAll(d, switchChannels, value),
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
    await run(() async {
      await _sendChannel(d, channel, value);
      await api.cacheHome(user, devices);
      message('Perubahan dikonfirmasi perangkat.');
    });
  }

  Future<void> _toggleAll(dynamic d, List<dynamic> channels, bool value) async {
    await run(() async {
      for (final channel in channels) {
        await _sendChannel(d, channel, value);
      }
      await api.cacheHome(user, devices);
      message('Semua channel berhasil diperbarui.');
    });
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

class _AutomationPageState extends State<_AutomationPage> {
  List<dynamic> scenes = [], schedules = [];
  bool loading = true, busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final result = await Future.wait([
        widget.api.scenes(),
        widget.api.schedules(),
      ]);
      if (mounted) {
        setState(() {
          scenes = result[0];
          schedules = result[1];
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
        .map((action) => action['state'] == true ? 'Relay On' : 'Relay Off')
        .toSet()
        .toList();
    return labels.isEmpty ? 'Aktivitas tidak diketahui' : labels.join(', ');
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
    final firstChannel = (defaultDevice['channels'] as List).firstWhere(
      (c) => c['type'] == 'switch',
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
    final existingAction =
        existingScene is Map &&
            existingScene['actions'] is List &&
            (existingScene['actions'] as List).isNotEmpty
        ? (existingScene['actions'] as List).first
        : null;
    String channelId = '${existingAction?['channel_id'] ?? firstChannel['id']}';
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
          if (!channels.any((c) => '${c['id']}' == channelId)) {
            channelId = '${channels.first['id']}';
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
                  DropdownButtonFormField<String>(
                    initialValue: channelId,
                    decoration: const InputDecoration(labelText: 'Relay'),
                    items: channels
                        .map(
                          (c) => DropdownMenuItem(
                            value: '${c['id']}',
                            child: Text(
                              '${c['alias'] ?? c['name'] ?? 'Relay ${c['id']}'}',
                            ),
                          ),
                        )
                        .toList(),
                    onChanged: (value) => update(() {
                      if (value != null) channelId = value;
                    }),
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
                    title: Text(state ? 'Relay ON' : 'Relay OFF'),
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
                  'channel': int.parse(channelId),
                  'state': state,
                }),
                child: const Text('Simpan'),
              ),
            ],
          );
        },
      ),
    );
    name.dispose();
    if (result == null || result['name'] == '') {
      if (result != null && mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Nama scene wajib diisi.')),
        );
      return;
    }
    setState(() => busy = true);
    try {
      final sceneBody = {
        'name': result['name'],
        'actions': [
          {'channel_id': result['channel'], 'state': result['state']},
        ],
      };
      final scene = existing == null
          ? await widget.api.createScene(
              result['device'] as String,
              result['name'] as String,
              [
                {'channel_id': result['channel'], 'state': result['state']},
              ],
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
      if (mounted)
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('$e')));
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
      if (mounted)
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Scene & Jadwal'),
      actions: [
        IconButton(
          onPressed: loading ? null : _load,
          icon: const Icon(Icons.refresh),
        ),
      ],
    ),
    floatingActionButton: FloatingActionButton.extended(
      onPressed: busy ? null : _addSchedule,
      icon: const Icon(Icons.add_alarm),
      label: const Text('Jadwal'),
    ),
    body: loading
        ? const Center(child: CircularProgressIndicator())
        : schedules.isEmpty
        ? const Center(child: Text('Belum ada jadwal.'))
        : ListView.separated(
            padding: const EdgeInsets.all(20),
            itemCount: schedules.length,
            separatorBuilder: (context, index) => const SizedBox(height: 10),
            itemBuilder: (context, index) {
              final s = schedules[index];
              final relayLabel = _scheduleRelayLabel(s);
              final activityLabel = _scheduleActivityLabel(s);
              return Card(
                child: ListTile(
                  leading: const Icon(Icons.schedule),
                  title: Text('${s['time_local']} • $activityLabel'),
                  subtitle: Text(
                    '${s['device_sn']} • ${s['scene_name']}\nRelay: $relayLabel\nSetiap hari • ${s['timezone']}',
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
  final Future<void> Function(int channelId, String alias) onAlias;
  final Future<bool> Function() onUnclaim;

  @override
  State<_DeviceDetailPage> createState() => _DeviceDetailPageState();
}

class _DeviceDetailPageState extends State<_DeviceDetailPage> {
  bool busy = false;
  bool refreshing = false;
  Timer? sensorTimer;
  List<dynamic> history = const [];
  int historyRangeHours = 24;
  int historyBucketMinutes = 30;
  bool historyLoading = false;
  int? selectedHistoryIndex;

  @override
  void initState() {
    super.initState();
    if (widget.device['device_type'] == 'sensor') {
      unawaited(_loadHistory());
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

  Future<void> _refreshSensor() async {
    if (refreshing || busy) return;
    refreshing = true;
    try {
      await widget.onRefresh();
      if (widget.device['device_type'] == 'sensor') {
        unawaited(_loadHistory(silent: true));
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

  @override
  Widget build(BuildContext context) {
    final device = widget.device;
    final state = device['state'] ?? {};
    final channels = device['channels'] as List? ?? [];
    final channel = channels.cast<dynamic>().firstWhere(
      (item) => item['type'] == 'switch',
      orElse: () => null,
    );
    final isSensor =
        device['device_type'] == 'sensor' ||
        channels.any((item) => item['type'] == 'sensor');
    final isOn = channel != null && state['gpio']?['${channel['pin']}'] == true;
    final online = device['online'] == true || device['local_online'] == true;
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          tooltip: 'Kembali',
          onPressed: () => Navigator.pop(context),
          icon: const Icon(Icons.arrow_back),
        ),
        actions: [
          IconButton(
            tooltip: 'Pengaturan perangkat',
            onPressed: () => _showInfo(context, device, state),
            icon: const Icon(Icons.settings_outlined),
          ),
        ],
      ),
      body: isSensor
          ? _buildSensorDashboard(device, state, online)
          : ListView(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 36),
              children: [
                Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        device['name'] ?? device['sn'],
                        style: const TextStyle(
                          fontSize: 23,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        device['model'] ?? 'RizIO device',
                        style: TextStyle(color: Colors.grey.shade600),
                      ),
                      const SizedBox(height: 24),
                      if (isSensor) ...[
                        Container(
                          width: 340,
                          padding: const EdgeInsets.all(18),
                          decoration: BoxDecoration(
                            gradient: const LinearGradient(
                              colors: [Color(0xff193f3a), Color(0xff2d6655)],
                            ),
                            borderRadius: BorderRadius.circular(22),
                          ),
                          child: Row(
                            children: [
                              Container(
                                padding: const EdgeInsets.all(12),
                                decoration: BoxDecoration(
                                  color: Colors.white.withAlpha(36),
                                  shape: BoxShape.circle,
                                ),
                                child: const Icon(
                                  Icons.sensors_outlined,
                                  color: Colors.white,
                                  size: 30,
                                ),
                              ),
                              const SizedBox(width: 14),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    const Text(
                                      'Pemantauan lingkungan',
                                      style: TextStyle(
                                        color: Colors.white,
                                        fontSize: 16,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      online
                                          ? 'Diperbarui otomatis setiap 2 detik'
                                          : 'Perangkat sedang offline',
                                      style: TextStyle(
                                        color: Colors.white.withAlpha(199),
                                        fontSize: 12,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              Icon(
                                online ? Icons.wifi : Icons.wifi_off,
                                color: Colors.white.withAlpha(230),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 14),
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Expanded(
                              child: _sensorMetric(
                                icon: Icons.thermostat_outlined,
                                label: 'Suhu',
                                value: state['temperature_c'] is num
                                    ? '${(state['temperature_c'] as num).toStringAsFixed(1)}°'
                                    : '—',
                                unit: 'Celsius',
                                color: const Color(0xffb85c00),
                                background: const Color(0xfffff3e0),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: _sensorMetric(
                                icon: Icons.water_drop_outlined,
                                label: 'Kelembapan',
                                value: state['humidity_percent'] is num
                                    ? (state['humidity_percent'] as num)
                                          .toStringAsFixed(1)
                                    : '—',
                                unit: 'Persen',
                                color: const Color(0xff1769aa),
                                background: const Color(0xffe7f3ff),
                              ),
                            ),
                          ],
                        ),
                      ] else ...[
                        Container(
                          height: 220,
                          width: 220,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: isOn
                                ? const Color(0xffe5f2e9)
                                : const Color(0xffeef0eb),
                          ),
                          child: Icon(
                            channel == null
                                ? Icons.devices_other
                                : Icons.lightbulb_outline,
                            size: 104,
                            color: const Color(0xff2d6655),
                          ),
                        ),
                        const SizedBox(height: 18),
                        Text(
                          isOn ? 'Menyala' : 'Mati',
                          style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        Text(
                          online
                              ? 'Ketuk tombol untuk mengubah perangkat'
                              : 'Perangkat sedang offline',
                          style: TextStyle(color: Colors.grey.shade600),
                        ),
                        const SizedBox(height: 14),
                        Switch.adaptive(
                          value: isOn,
                          onChanged: !online || channel == null || busy
                              ? null
                              : (value) async {
                                  setState(() => busy = true);
                                  try {
                                    await widget.onToggle(
                                      device,
                                      channel,
                                      value,
                                    );
                                  } finally {
                                    if (mounted) setState(() => busy = false);
                                  }
                                },
                        ),
                      ],
                    ],
                  ),
                ),
                if (!isSensor &&
                    channels.any((c) => c['type'] == 'switch')) ...[
                  const SizedBox(height: 28),
                  _sectionTitle('Channel relay'),
                  const SizedBox(height: 10),
                  Card(
                    child: Column(
                      children: channels
                          .where((c) => c['type'] == 'switch')
                          .map<Widget>((c) {
                            final on = state['gpio']?['${c['pin']}'] == true;
                            final label =
                                (c['alias'] as String?)?.trim().isNotEmpty ==
                                    true
                                ? c['alias'] as String
                                : '${c['name'] ?? 'Relay'}';
                            return ListTile(
                              leading: Icon(
                                on ? Icons.lightbulb : Icons.lightbulb_outline,
                                color: const Color(0xff2d6655),
                              ),
                              title: Text(
                                label,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              subtitle: Text(
                                'Channel ${c['id']} · GPIO ${c['pin']}',
                              ),
                              trailing: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  IconButton(
                                    icon: const Icon(Icons.edit_outlined),
                                    onPressed: () => _editAlias(c),
                                  ),
                                  Switch.adaptive(
                                    value: on,
                                    onChanged: !online || busy
                                        ? null
                                        : (v) async {
                                            setState(() => busy = true);
                                            try {
                                              await widget.onToggle(
                                                device,
                                                c,
                                                v,
                                              );
                                            } finally {
                                              if (mounted) {
                                                setState(() => busy = false);
                                              }
                                            }
                                          },
                                  ),
                                ],
                              ),
                            );
                          })
                          .toList(),
                    ),
                  ),
                ],
                const SizedBox(height: 20),
                _sectionTitle('Status perangkat'),
                const SizedBox(height: 10),
                Card(
                  child: Column(
                    children: [
                      _infoTile(
                        Icons.wifi,
                        'Koneksi',
                        online ? 'Online' : 'Offline',
                      ),
                      _infoTile(
                        Icons.route,
                        'Jalur kontrol',
                        device['local_online'] == true ? 'Lokal' : 'Cloud',
                      ),
                      _infoTile(
                        Icons.memory,
                        'Firmware',
                        '${device['firmware_version'] ?? 'unknown'}',
                      ),
                      _infoTile(
                        Icons.signal_cellular_alt,
                        'Sinyal',
                        '${state['rssi'] ?? '—'}',
                      ),
                      if (state['temperature_c'] is num)
                        _infoTile(
                          Icons.thermostat_outlined,
                          'Suhu',
                          '${(state['temperature_c'] as num).toStringAsFixed(1)} °C',
                        ),
                      if (state['humidity_percent'] is num)
                        _infoTile(
                          Icons.water_drop_outlined,
                          'Kelembapan',
                          '${(state['humidity_percent'] as num).toStringAsFixed(1)}%',
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 20),
                _sectionTitle('Aksi cepat'),
                const SizedBox(height: 10),
                Card(
                  child: Column(
                    children: [
                      ListTile(
                        leading: const Icon(Icons.wifi),
                        title: const Text('Hubungkan Wi-Fi'),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => Navigator.pop(context),
                      ),
                      const Divider(height: 1, indent: 56),
                      ListTile(
                        leading: const Icon(Icons.restart_alt),
                        title: const Text('Restart perangkat'),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => Navigator.pop(context),
                      ),
                      const Divider(height: 1, indent: 56),
                      ListTile(
                        leading: const Icon(
                          Icons.link_off,
                          color: Color(0xffb33a32),
                        ),
                        title: const Text('Lepaskan perangkat'),
                        subtitle: const Text(
                          'Perangkat akan keluar dari akun ini',
                        ),
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
    );
  }

  Widget _buildSensorBody(
    BuildContext context,
    dynamic device,
    dynamic state,
    bool online,
  ) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 36),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            device['name'] ?? device['sn'],
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 23, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 3),
          Text(
            device['model'] ?? 'Sensor DHT11',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.grey.shade600),
          ),
          const SizedBox(height: 22),
          Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [Color(0xff193f3a), Color(0xff2d6655)],
              ),
              borderRadius: BorderRadius.circular(22),
            ),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.white.withAlpha(36),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.sensors_outlined,
                    color: Colors.white,
                    size: 30,
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Pemantauan lingkungan',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        online
                            ? 'Diperbarui otomatis setiap 2 detik'
                            : 'Perangkat sedang offline',
                        style: TextStyle(
                          color: Colors.white.withAlpha(199),
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
                Icon(
                  online ? Icons.wifi : Icons.wifi_off,
                  color: Colors.white.withAlpha(230),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: _sensorMetric(
                  icon: Icons.thermostat_outlined,
                  label: 'Suhu',
                  value: state['temperature_c'] is num
                      ? '${(state['temperature_c'] as num).toStringAsFixed(1)}°'
                      : '—',
                  unit: 'Celsius',
                  color: const Color(0xffb85c00),
                  background: const Color(0xfffff3e0),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _sensorMetric(
                  icon: Icons.water_drop_outlined,
                  label: 'Kelembapan',
                  value: state['humidity_percent'] is num
                      ? (state['humidity_percent'] as num).toStringAsFixed(1)
                      : '—',
                  unit: 'Persen',
                  color: const Color(0xff1769aa),
                  background: const Color(0xffe7f3ff),
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),
          _sectionTitle('Status perangkat'),
          const SizedBox(height: 10),
          Card(
            child: Column(
              children: [
                _infoTile(Icons.wifi, 'Koneksi', online ? 'Online' : 'Offline'),
                _infoTile(
                  Icons.route,
                  'Jalur kontrol',
                  device['local_online'] == true ? 'Lokal' : 'Cloud',
                ),
                _infoTile(
                  Icons.memory,
                  'Firmware',
                  '${device['firmware_version'] ?? 'unknown'}',
                ),
                _infoTile(
                  Icons.signal_cellular_alt,
                  'Sinyal',
                  '${state['rssi'] ?? '—'}',
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSensorDashboard(dynamic device, dynamic state, bool online) {
    final temperature = state is Map && state['temperature_c'] is num
        ? (state['temperature_c'] as num).toStringAsFixed(1)
        : '--';
    final humidity = state is Map && state['humidity_percent'] is num
        ? (state['humidity_percent'] as num).toStringAsFixed(1)
        : '--';
    final rssi = state is Map ? state['rssi'] : null;
    final name = '${device['name'] ?? device['sn']}';
    final model = '${device['model'] ?? 'Sensor suhu'}';

    return RefreshIndicator(
      onRefresh: _refreshSensor,
      color: const Color(0xffd66a28),
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 36),
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 26,
                        fontWeight: FontWeight.w800,
                        color: Color(0xff102a27),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      model,
                      style: TextStyle(
                        color: Colors.blueGrey.shade600,
                        fontSize: 14,
                      ),
                    ),
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 11,
                  vertical: 7,
                ),
                decoration: BoxDecoration(
                  color: online
                      ? const Color(0xffe7f5ed)
                      : const Color(0xffffece9),
                  borderRadius: BorderRadius.circular(30),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      online ? Icons.circle : Icons.circle_outlined,
                      size: 10,
                      color: online
                          ? const Color(0xff23834d)
                          : const Color(0xffc04d45),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      online ? 'Online' : 'Offline',
                      style: TextStyle(
                        color: online
                            ? const Color(0xff1c7042)
                            : const Color(0xffa83d36),
                        fontWeight: FontWeight.w700,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
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
                        'Suhu ruangan',
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
                const SizedBox(height: 20),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      temperature,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 62,
                        height: .95,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -2,
                      ),
                    ),
                    const Padding(
                      padding: EdgeInsets.only(left: 8, bottom: 7),
                      child: Text(
                        '°C',
                        style: TextStyle(
                          color: Color(0xffdceee6),
                          fontSize: 25,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Text(
                  online
                      ? 'Diperbarui otomatis setiap 2 detik'
                      : 'Menampilkan pembacaan terakhir',
                  style: TextStyle(
                    color: Colors.white.withAlpha(190),
                    fontSize: 13,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
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
                  icon: Icons.signal_cellular_alt,
                  label: 'Sinyal',
                  value: rssi == null ? '--' : '$rssi',
                  unit: 'dBm',
                  color: const Color(0xff7a5ab5),
                  background: const Color(0xfff2edff),
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),
          _temperatureHistoryCard(),
          const SizedBox(height: 24),
          _sectionTitle('Detail perangkat'),
          const SizedBox(height: 10),
          Card(
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
                    online ? 'Terhubung' : 'Tidak terhubung',
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
          const SizedBox(height: 14),
          Text(
            'Tarik ke bawah untuk memperbarui data sensor',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.blueGrey.shade500, fontSize: 12),
          ),
        ],
      ),
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
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 17, 16, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text(
                    'Perubahan suhu',
                    style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
                  ),
                ),
                IconButton(
                  tooltip: 'Muat ulang grafik',
                  onPressed: historyLoading ? null : () => _loadHistory(),
                  icon: const Icon(Icons.refresh_rounded, size: 20),
                ),
              ],
            ),
            Text(
              'Rata-rata pembacaan dalam interval waktu',
              style: TextStyle(color: Colors.blueGrey.shade600, fontSize: 12),
            ),
            const SizedBox(height: 12),
            SegmentedButton<int>(
              segments: const [
                ButtonSegment(value: 24, label: Text('24 jam')),
                ButtonSegment(value: 168, label: Text('7 hari')),
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
                            ? 'Memuat histori...'
                            : 'Belum ada data histori',
                        style: TextStyle(color: Colors.blueGrey.shade500),
                      ),
                    )
                  : GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTapUp: (details) {
                        if (points.length == 1) {
                          setState(() => selectedHistoryIndex = 0);
                          return;
                        }
                        const left = 36.0;
                        final chartWidth =
                            MediaQuery.sizeOf(context).width - 72;
                        final usableWidth = chartWidth > 1 ? chartWidth : 1.0;
                        final width =
                            (details.localPosition.dx - left) / usableWidth;
                        final index = (width * (points.length - 1))
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
                  'Suhu °C',
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

  double? _historyNumber(dynamic value) =>
      value is num ? value.toDouble() : double.tryParse('${value ?? ''}');

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
              TextSpan(text: ' $unit', style: const TextStyle(fontSize: 14)),
            ],
          ),
        ),
      ],
    ),
  );

  Widget _buildSensorBodySimple(dynamic device, dynamic state, bool online) {
    final temperature = state is Map && state['temperature_c'] is num
        ? '${(state['temperature_c'] as num).toStringAsFixed(1)} °C'
        : '-- °C';
    final humidity = state is Map && state['humidity_percent'] is num
        ? '${(state['humidity_percent'] as num).toStringAsFixed(1)} %'
        : '-- %';
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '${device['name'] ?? device['sn']}',
            style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 20),
          Text(
            'SUHU',
            style: const TextStyle(color: Color(0xffb85c00), fontSize: 16),
          ),
          Text(
            temperature,
            style: const TextStyle(
              color: Color(0xffb85c00),
              fontSize: 42,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 18),
          Text(
            'KELEMBAPAN',
            style: const TextStyle(color: Color(0xff1769aa), fontSize: 16),
          ),
          Text(
            humidity,
            style: const TextStyle(
              color: Color(0xff1769aa),
              fontSize: 30,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 16),
          Text(
            online
                ? 'Update otomatis setiap 2 detik'
                : 'Perangkat sedang offline',
          ),
        ],
      ),
    );
    /*
    // Legacy sensor layout retained for reference.
    final temperature = state is Map ? state['temperature_c'] : null;
    final humidity = state is Map ? state['humidity_percent'] : null;
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Text(
          '${device['name'] ?? device['sn']}',
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 6),
        Text(
          online ? 'Sensor DHT11 • Online' : 'Sensor DHT11 • Offline',
          textAlign: TextAlign.center,
          style: const TextStyle(color: Colors.grey),
        ),
        const SizedBox(height: 24),
        Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: const Color(0xfffff3e0),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(
                Icons.thermostat_outlined,
                color: Color(0xffb85c00),
                size: 36,
              ),
              const SizedBox(height: 10),
              const Text('SUHU', style: TextStyle(color: Color(0xffb85c00))),
              Text(
                temperature is num
                    ? '${temperature.toStringAsFixed(1)} °C'
                    : '-- °C',
                style: const TextStyle(
                  fontSize: 38,
                  fontWeight: FontWeight.bold,
                  color: Color(0xffb85c00),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: const Color(0xffe7f3ff),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(
                Icons.water_drop_outlined,
                color: Color(0xff1769aa),
                size: 36,
              ),
              const SizedBox(height: 10),
              const Text(
                'KELEMBAPAN',
                style: TextStyle(color: Color(0xff1769aa)),
              ),
              Text(
                humidity is num ? '${humidity.toStringAsFixed(1)} %' : '-- %',
                style: const TextStyle(
                  fontSize: 30,
                  fontWeight: FontWeight.bold,
                  color: Color(0xff1769aa),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),
        Text(
          'Pembaruan otomatis setiap 2 detik',
          style: TextStyle(color: Colors.grey.shade700),
        ),
      ],
    ); */
  }

  Widget _sensorMetric({
    required IconData icon,
    required String label,
    required String value,
    required String unit,
    required Color color,
    required Color background,
  }) => Container(
    padding: const EdgeInsets.fromLTRB(16, 16, 12, 15),
    decoration: BoxDecoration(
      color: background,
      borderRadius: BorderRadius.circular(20),
      border: Border.all(color: color.withAlpha(41)),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, color: color, size: 25),
        const SizedBox(height: 14),
        Text(
          label,
          style: TextStyle(
            color: color.withAlpha(217),
            fontSize: 13,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 3),
        Text(
          value,
          style: TextStyle(
            color: color,
            fontSize: 29,
            fontWeight: FontWeight.w800,
            letterSpacing: -.5,
          ),
        ),
        Text(unit, style: TextStyle(color: color.withAlpha(179), fontSize: 11)),
      ],
    ),
  );

  Widget _sectionTitle(String value) => Text(
    value,
    style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
  );

  Widget _infoTile(IconData icon, String label, String value) => ListTile(
    leading: Icon(icon, color: const Color(0xff2d6655)),
    title: Text(
      label,
      style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
    ),
    subtitle: Text(value, style: const TextStyle(fontWeight: FontWeight.w600)),
  );

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
    controller.dispose();
    if (alias == null || !mounted) return;
    try {
      await widget.onAlias(channel['id'] as int, alias);
      if (!mounted) return;
      setState(() {});
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
