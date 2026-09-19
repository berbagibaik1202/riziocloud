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
        await api.flushPendingClaim();
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
        final owned = result is List
            ? result
            : result['items'] ?? result['devices'] ?? [];
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
      Map<String, dynamic> claimData;
      try {
        claimData = parseSetup(raw);
      } catch (_) {
        claimData = parseClaim(raw);
      }
      await network.discover();
      await api.savePendingClaim({
        'sn': claimData['sn'],
        'claim_code': claimData['claim_code'],
      });
      try {
        await api.request(
          '/devices/claim',
          method: 'POST',
          body: {'sn': claimData['sn'], 'claim_code': claimData['claim_code']},
        );
        await api.storage.delete(key: 'pending_claim');
      } catch (_) {
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
      {'SSID Wi-Fi': '', 'Kata sandi Wi-Fi': ''},
      secrets: {'Kata sandi Wi-Fi'},
    );
    if (values == null) return;
    await run(() async {
      await network.provision(
        values['SSID Wi-Fi']!,
        values['Kata sandi Wi-Fi']!,
      );
      message(
        'Konfigurasi diterima. Sambungkan ponsel kembali ke Wi-Fi rumah, lalu perbarui perangkat.',
      );
    });
  }

  Future<void> detail(dynamic d) async {
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => _DeviceDetailPage(device: d, onToggle: _toggleDevice),
      ),
    );
  }

  Future<void> _toggleDevice(dynamic device, bool value) async {
    final channels = device['channels'] as List? ?? [];
    final channel = channels.cast<dynamic>().firstWhere(
      (c) => c['type'] == 'switch',
      orElse: () => null,
    );
    if (channel == null) return;
    await run(() async {
      await network.command(
        device['sn'] as String,
        'gpio.set',
        pin: channel['pin'] as int,
        state: value,
      );
      await reload();
      if (mounted) setState(() {});
      message('Perubahan dikonfirmasi perangkat.');
    });
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
            ],
          ),
        ),
      ),
    );
  }

  Widget _dashboardView(BuildContext context) {
    final online = devices.where((d) => d['online'] == true).length;
    return Scaffold(
      body: SafeArea(
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
    final isOn = channel != null && state['gpio']?['${channel['pin']}'] == true;
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
                        '${d['online'] == true ? 'Online' : 'Offline'} · ${network.modes[sn] ?? 'Cloud'}',
                        style: TextStyle(
                          fontSize: 12,
                          color: Colors.grey.shade600,
                        ),
                      ),
                    ],
                  ),
                ),
                if (channel != null)
                  Switch(
                    value: isOn,
                    onChanged: busy
                        ? null
                        : (value) => _toggle(d, channel, value),
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
      await network.command(
        d['sn'] as String,
        'gpio.set',
        pin: channel['pin'] as int,
        state: value,
      );
      await reload();
      message('Perubahan dikonfirmasi perangkat.');
    });
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
      ],
    ),
  );
}

class _DeviceDetailPage extends StatefulWidget {
  const _DeviceDetailPage({required this.device, required this.onToggle});
  final dynamic device;
  final Future<void> Function(dynamic device, bool value) onToggle;

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
    final online = device['online'] == true;
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
                            await widget.onToggle(device, value);
                          } finally {
                            if (mounted) setState(() => busy = false);
                          }
                        },
                ),
              ],
            ),
          ),
          const SizedBox(height: 28),
          _sectionTitle('Status perangkat'),
          const SizedBox(height: 10),
          Card(
            child: Column(
              children: [
                _infoTile(Icons.wifi, 'Koneksi', online ? 'Online' : 'Offline'),
                _infoTile(
                  Icons.route,
                  'Jalur kontrol',
                  '${device['sn'] ?? ''}',
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
