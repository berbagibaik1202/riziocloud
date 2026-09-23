import 'dart:async';
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
  bool provisioningWifi = false;
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
      if (user != null && !busy && !restoring) {
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
    if (state == AppLifecycleState.resumed && user != null && !restoring) {
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
    await discoverNearby(silent: true);
    await network.readLocalStates(devices);
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
    if (reloading) return;
    final accountId = user?['id'];
    reloading = true;
    try {
      await discoverNearby(silent: true);
      await flushPendingLocalPair();
      await network.readLocalStates(devices);
      if (mounted) setState(() {});
      try {
        // Resume setup after the phone leaves the ESP access point.
        await api.flushPendingClaim();
        final result = await api.request('/devices');
        if (user?['id'] != accountId) return;
        final owned =
            (result is List
                    ? result
                    : result['items'] ?? result['devices'] ?? [])
                as List<dynamic>;
        final enrichedOwned = owned.map((device) {
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
        }).toList();
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
        await network.readLocalStates(merged);
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
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          message('Wi-Fi tersimpan. Perangkat sudah masuk daftar.');
        }
      });
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

  Future<void> _unclaimDevice(dynamic device) async {
    final values = await form(
      'Lepaskan perangkat',
      {'Password akun': ''},
      secrets: {'Password akun'},
    );
    if (values == null) return;
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
        devices.removeWhere((d) => d['sn'] == sn);
        await api.cacheHome(user, devices);
        if (mounted) setState(() {});
        message('Perangkat dihapus dari daftar lokal.');
        return;
      }
      if (network.offlineKeys.containsKey(sn)) {
        // Revoke durable LAN access before releasing ownership.
        await network.deviceLocal(sn, '/api/v1/local-access', method: 'DELETE');
      }
      await api.request(
        '/devices/${Uri.encodeComponent(device['sn'] as String)}',
        method: 'DELETE',
        body: {'password': values['Password akun']},
      );
      await network.clear(device['sn'] as String);
      await api.storage.delete(key: 'pending_claim');
      await api.clearPendingLocalPair();
      await reload();
      if (!mounted) return;
      message('Perangkat dilepas dan dapat diklaim oleh pengguna lain.');
    });
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

class _DeviceDetailPage extends StatefulWidget {
  const _DeviceDetailPage({
    required this.device,
    required this.onToggle,
    required this.onAlias,
    required this.onUnclaim,
  });
  final dynamic device;
  final Future<void> Function(dynamic device, dynamic channel, bool value)
  onToggle;
  final Future<void> Function(int channelId, String alias) onAlias;
  final Future<void> Function() onUnclaim;

  @override
  State<_DeviceDetailPage> createState() => _DeviceDetailPageState();
}

class _DeviceDetailPageState extends State<_DeviceDetailPage> {
  bool busy = false;

  @override
  Widget build(BuildContext context) {
    final device = widget.device;
    final state = device['state'] ?? {};
    final channels = device['channels'] as List? ?? [];
    final channel = channels.cast<dynamic>().firstWhere(
      (item) => item['type'] == 'switch',
      orElse: () => null,
    );
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
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 36),
        children: [
          Center(
            child: Column(
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
                            await widget.onToggle(device, channel, value);
                          } finally {
                            if (mounted) setState(() => busy = false);
                          }
                        },
                ),
              ],
            ),
          ),
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
                        (c['alias'] as String?)?.trim().isNotEmpty == true
                        ? c['alias'] as String
                        : '${c['name'] ?? 'Relay'}';
                    return ListTile(
                      leading: Icon(
                        on ? Icons.lightbulb : Icons.lightbulb_outline,
                        color: const Color(0xff2d6655),
                      ),
                      title: Text(
                        label,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      subtitle: Text('Channel ${c['id']} · GPIO ${c['pin']}'),
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
                                : (v) => widget.onToggle(device, c, v),
                          ),
                        ],
                      ),
                    );
                  })
                  .toList(),
            ),
          ),
          const SizedBox(height: 20),
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
                  leading: const Icon(Icons.link_off, color: Color(0xffb33a32)),
                  title: const Text('Lepaskan perangkat'),
                  subtitle: const Text('Perangkat akan keluar dari akun ini'),
                  textColor: const Color(0xffb33a32),
                  onTap: () async {
                    Navigator.pop(context);
                    await widget.onUnclaim();
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

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
