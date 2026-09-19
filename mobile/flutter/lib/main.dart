import 'dart:async';
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
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
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xff176f65)),
      useMaterial3: true,
      scaffoldBackgroundColor: const Color(0xfff3f6f4),
      inputDecorationTheme: const InputDecorationTheme(
        border: OutlineInputBorder(),
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

class _HomeState extends State<Home> {
  final api = Api();
  late final network = DeviceNetwork(api);
  bool loading = true, register = false, busy = false;
  String? error;
  dynamic user;
  List<dynamic> devices = [];
  Timer? timer;
  final email = TextEditingController(),
      password = TextEditingController(),
      name = TextEditingController();
  @override
  void initState() {
    super.initState();
    restore();
    timer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (user != null && !busy) {
        reload(silent: true);
      }
    });
  }

  @override
  void dispose() {
    timer?.cancel();
    email.dispose();
    password.dispose();
    name.dispose();
    api.client.close();
    super.dispose();
  }

  Future<void> restore() async {
    try {
      await api.restore();
      if (api.access != null) {
        user = await api.request('/auth/me');
        await reload();
      }
    } catch (e) {
      error = 'Sesi tidak dapat dipulihkan. Silakan masuk kembali.';
    }
    if (mounted) setState(() => loading = false);
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
    try {
      final result = await api.request('/devices');
      try {
        await network.discover();
        final owned = result is List ? result : result['items'] ?? result['devices'] ?? [];
        await network.prefetch((owned as List).map((d) => d['sn'] as String));
      } catch (_) {}
      if (mounted) {
        setState(() {
          devices = result is List
              ? result
              : result['items'] ?? result['devices'] ?? [];
          error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
      if (!silent) rethrow;
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
    await api.save(r);
    user = r['user'];
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
      await api.request(
        '/devices/claim',
        method: 'POST',
        body: parseClaim(raw),
      );
      await reload();
      message('Perangkat ditambahkan. Hubungkan Wi-Fi melalui menu perangkat.');
    });
  }

  Future<void> provision() async {
    final values = await form(
      'Hubungkan Wi-Fi',
      {'SSID Wi-Fi': '', 'Kata sandi Wi-Fi': '', 'Kode setup': ''},
      secrets: {'Kata sandi Wi-Fi', 'Kode setup'},
    );
    if (values == null) return;
    await run(() async {
      await network.provision(
        values['SSID Wi-Fi']!,
        values['Kata sandi Wi-Fi']!,
        values['Kode setup']!,
      );
      message(
        'Konfigurasi diterima. Sambungkan ponsel kembali ke Wi-Fi rumah, lalu perbarui perangkat.',
      );
    });
  }

  Future<void> detail(dynamic d) async {
    final sn = d['sn'] as String;
    final state = d['state'] ?? {};
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (c) => SafeArea(
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  d['name'] ?? sn,
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: 16),
                ...{
                  'Nomor seri': sn,
                  'Model': d['model'],
                  'Hardware': d['hardware_version'],
                  'Firmware': d['firmware_version'],
                  'Koneksi':
                      '${d['online'] == true ? 'Online' : 'Offline'} · ${network.modes[sn] ?? 'Cloud'}',
                  'RSSI': state['rssi'],
                  'Alamat IP': state['ip_address'],
                  'Uptime': state['uptime'],
                  'Memori bebas': state['free_heap'],
                  'Terakhir terlihat': d['last_seen'],
                }.entries.map(
                  (e) => ListTile(
                    dense: true,
                    title: Text(e.key),
                    trailing: Text('${e.value ?? '—'}'),
                  ),
                ),
                const Divider(),
                ListTile(
                  leading: const Icon(Icons.wifi),
                  title: const Text('Hubungkan Wi-Fi'),
                  subtitle: const Text(
                    'Sambungkan ponsel ke ESPCTRL-… terlebih dahulu.',
                  ),
                  onTap: () {
                    Navigator.pop(c);
                    provision();
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.edit),
                  title: const Text('Ganti nama'),
                  onTap: () async {
                    Navigator.pop(c);
                    final v = await form('Ganti nama', {
                      'Nama': d['name'] ?? sn,
                    });
                    if (v != null) {
                      run(() async {
                        await api.request(
                          '/devices/${Uri.encodeComponent(sn)}',
                          method: 'PATCH',
                          body: {'name': v['Nama']},
                        );
                        await reload();
                      });
                    }
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.restart_alt),
                  title: const Text('Restart perangkat'),
                  onTap: () {
                    Navigator.pop(c);
                    run(() async {
                      await network.command(sn, 'system.reboot');
                      message('Restart dikonfirmasi perangkat.');
                      await reload();
                    });
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.link_off),
                  title: const Text('Lepaskan perangkat'),
                  onTap: () async {
                    Navigator.pop(c);
                    final v = await form(
                      'Konfirmasi lepas kepemilikan',
                      {'Kata sandi akun': ''},
                      secrets: {'Kata sandi akun'},
                    );
                    if (v != null) {
                      run(() async {
                        final r = await api.request(
                          '/devices/${Uri.encodeComponent(sn)}',
                          method: 'DELETE',
                          body: {'password': v['Kata sandi akun']},
                        );
                        network.clear(sn);
                        await reload();
                        if (!mounted) return;
                        await showDialog<void>(
                          context: context,
                          builder: (c) => AlertDialog(
                            title: const Text('Simpan kode klaim baru'),
                            content: SelectableText(
                              '${r['claim_code']}\n\nKode ini hanya ditampilkan sekali. Token lokal sebelumnya dapat berlaku hingga 60 detik.',
                            ),
                            actions: [
                              TextButton(
                                onPressed: () => Navigator.pop(c),
                                child: const Text('Sudah disimpan'),
                              ),
                            ],
                          ),
                        );
                      });
                    }
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
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
    if (user == null) {
      return Scaffold(
        body: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(28),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'RizIO.',
                    style: Theme.of(context).textTheme.displaySmall,
                  ),
                  Text(
                    register
                        ? 'Buat akun untuk perangkat Anda'
                        : 'Selamat datang kembali',
                  ),
                  const SizedBox(height: 28),
                  if (error != null)
                    Text(error!, style: const TextStyle(color: Colors.red)),
                  if (register) ...[
                    TextField(
                      controller: name,
                      decoration: const InputDecoration(labelText: 'Nama'),
                    ),
                    const SizedBox(height: 14),
                  ],
                  TextField(
                    controller: email,
                    keyboardType: TextInputType.emailAddress,
                    decoration: const InputDecoration(labelText: 'Email'),
                  ),
                  const SizedBox(height: 14),
                  TextField(
                    controller: password,
                    obscureText: true,
                    decoration: const InputDecoration(labelText: 'Kata sandi'),
                  ),
                  const SizedBox(height: 22),
                  FilledButton(
                    onPressed: busy ? null : () => run(login),
                    child: Text(
                      busy
                          ? 'Memproses…'
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
                ],
              ),
            ),
          ),
        ),
      );
    }
    return Scaffold(
      appBar: AppBar(
        title: const Text('Perangkat saya'),
        actions: [
          IconButton(
            tooltip: 'Akun',
            icon: const Icon(Icons.account_circle_outlined),
            onPressed: () => showDialog<void>(
              context: context,
              builder: (c) => AlertDialog(
                title: const Text('Akun'),
                content: Text('${user['name'] ?? ''}\n${user['email'] ?? ''}'),
                actions: [
                  TextButton(
                    onPressed: () {
                      Navigator.pop(c);
                      run(() async {
                        await api.logout();
                        network.clear();
                        setState(() {
                          user = null;
                          devices = [];
                        });
                      });
                    },
                    child: const Text('Keluar'),
                  ),
                  TextButton(
                    onPressed: () => Navigator.pop(c),
                    child: const Text('Tutup'),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: busy ? null : claim,
        icon: const Icon(Icons.qr_code_scanner),
        label: const Text('Tambah perangkat'),
      ),
      body: RefreshIndicator(
        onRefresh: () => reload(),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 100),
          children: [
            if (busy) const LinearProgressIndicator(),
            if (error != null)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(error!),
                ),
              ),
            if (devices.isEmpty)
              const Padding(
                padding: EdgeInsets.all(32),
                child: Text(
                  'Belum ada perangkat. Scan QR untuk mulai menghubungkan rumah Anda.',
                ),
              ),
            ...devices.map((d) {
              final sn = d['sn'] as String;
              final state = d['state'] ?? {};
              final channels = d['channels'] as List? ?? [];
              return Card(
                margin: const EdgeInsets.only(bottom: 16),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    children: [
                      ListTile(
                        title: Text(
                          d['name'] ?? sn,
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                        subtitle: Text(
                          '${d['online'] == true ? '● Online' : '○ Offline'} · ${network.modes[sn] ?? 'Cloud'}\n${d['model'] ?? ''}',
                        ),
                        trailing: IconButton(
                          icon: const Icon(Icons.settings_outlined),
                          onPressed: busy ? null : () => detail(d),
                        ),
                      ),
                      ...channels.map(
                        (ch) => SwitchListTile(
                          title: Text(ch['name'] ?? 'GPIO ${ch['pin']}'),
                          subtitle: Text(ch['type'] ?? 'switch'),
                          value: state['gpio']?['${ch['pin']}'] == true,
                          onChanged: busy || ch['type'] != 'switch'
                              ? null
                              : (value) => run(() async {
                                  final ack = await network.command(
                                    sn,
                                    'gpio.set',
                                    pin: ch['pin'] as int,
                                    state: value,
                                  );
                                  if (ack['state'] is Map &&
                                      ack['state']['gpio'] is Map) {
                                    setState(
                                      () => d['state'] = <String, dynamic>{
                                        ...state,
                                        ...ack['state'],
                                      },
                                    );
                                  } else {
                                    await reload();
                                  }
                                  message('Perubahan dikonfirmasi perangkat.');
                                }),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            }),
          ],
        ),
      ),
    );
  }
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
      parseClaim(raw);
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
