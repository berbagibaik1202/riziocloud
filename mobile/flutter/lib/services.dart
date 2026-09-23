import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';

class ApiFailure implements Exception {
  ApiFailure(this.statusCode, this.message);
  final int statusCode;
  final String message;
  @override
  String toString() => message;
}

bool isConnectionFailure(Object error) =>
    error is SocketException ||
    error is TimeoutException ||
    error is http.ClientException ||
    (error is ApiFailure && error.statusCode >= 500);

String localProof(
  String key,
  String sn,
  String nonce,
  String method,
  String path,
  String body,
) => Hmac(
  sha256,
  utf8.encode(key),
).convert(utf8.encode('$sn\n$nonce\n$method\n$path\n$body')).toString();

Map<String, dynamic> parseClaim(String raw) {
  String? sn;
  if (raw.trim().startsWith('{')) {
    final value = jsonDecode(raw) as Map<String, dynamic>;
    if (value['type'] != 'esp-cloud' || value.containsKey('device_key')) {
      throw const FormatException('QR tidak valid');
    }
    sn = value['sn'] as String?;
  } else {
    final uri = Uri.parse(raw);
    if (uri.scheme.toLowerCase() != 'espctrl' ||
        (uri.host != 'claim' && uri.host != 'device')) {
      throw const FormatException('QR tidak valid');
    }
    sn = uri.queryParameters['sn'];
  }
  if (sn == null || sn.isEmpty) {
    throw const FormatException('Nomor seri wajib diisi');
  }
  return {'sn': sn};
}

Map<String, dynamic> parseSetup(String raw) {
  final value = jsonDecode(raw.trim());
  if (value is! Map<String, dynamic> || value['type'] != 'rizio-setup') {
    throw const FormatException('QR setup RizIO tidak valid');
  }
  final sn = value['sn'];
  final ssid = value['ssid'];
  if (sn is! String || ssid is! String || sn.isEmpty || ssid.isEmpty) {
    throw const FormatException('QR setup tidak lengkap');
  }
  return {'sn': sn, 'ssid': ssid, 'setup_code': value['setup_code']};
}

class Api {
  Api({http.Client? client}) : client = client ?? http.Client();
  final http.Client client;
  final storage = const FlutterSecureStorage();
  final String base = const String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'https://api.example.com/v1',
  );
  String? access, refresh;
  Future<void>? refreshing;
  Future<void> restore() async {
    refresh = await storage.read(key: 'refresh');
    if (refresh != null) {
      await renew();
    }
  }

  Future<void> save(dynamic value) async {
    access = value['access_token'];
    refresh = value['refresh_token'];
    await storage.write(key: 'refresh', value: refresh);
  }

  Future<void> renew() async {
    await save(
      await request(
        '/auth/refresh',
        method: 'POST',
        body: {'refresh_token': refresh},
        retry: false,
      ),
    );
  }

  Future<dynamic> request(
    String path, {
    String method = 'GET',
    dynamic body,
    bool retry = true,
  }) async {
    final req = http.Request(method, Uri.parse('$base$path'));
    req.headers.addAll({
      'Content-Type': 'application/json',
      if (access != null) 'Authorization': 'Bearer $access',
    });
    if (body != null) {
      req.body = jsonEncode(body);
    }
    final response = await http.Response.fromStream(
      await client.send(req).timeout(const Duration(seconds: 12)),
    );
    if (response.statusCode == 401 && retry && refresh != null) {
      refreshing ??= renew().whenComplete(() => refreshing = null);
      await refreshing;
      return request(path, method: method, body: body, retry: false);
    }
    final result = jsonDecode(response.body);
    if (response.statusCode >= 400 || result['status'] == 'error') {
      throw ApiFailure(
        response.statusCode,
        result['message'] ?? 'Koneksi gagal',
      );
    }
    return result['data'];
  }

  Future<void> logout() async {
    try {
      if (refresh != null) {
        await request(
          '/auth/logout',
          method: 'POST',
          body: {'refresh_token': refresh},
        );
      }
    } finally {
      access = null;
      refresh = null;
      await storage.delete(key: 'refresh');
      await storage.delete(key: 'offline_home');
      await storage.delete(key: 'offline_keys');
      await storage.delete(key: 'pending_claim');
    }
  }

  Future<Map<String, dynamic>?> cachedHome() async {
    if (await storage.read(key: 'refresh') == null) return null;
    final raw = await storage.read(key: 'offline_home');
    return raw == null ? null : jsonDecode(raw) as Map<String, dynamic>;
  }

  Future<void> cacheHome(dynamic user, List<dynamic> devices) => storage.write(
    key: 'offline_home',
    value: jsonEncode({'user': user, 'devices': devices}),
  );

  Future<void> savePendingClaim(Map<String, dynamic> claim) async {
    await storage.write(key: 'pending_claim', value: jsonEncode(claim));
  }

  Future<void> flushPendingClaim() async {
    final raw = await storage.read(key: 'pending_claim');
    if (raw == null) return;
    try {
      final claim = jsonDecode(raw) as Map<String, dynamic>;
      await DeviceNetwork(this).claimDevice(claim['sn'] as String);
      await storage.delete(key: 'pending_claim');
    } catch (_) {}
  }
}

class DeviceNetwork {
  static const defaultSetupCode = 'rizio123456';

  DeviceNetwork(this.api);
  final Api api;
  final Map<String, String> addresses = {};
  final Map<String, Map<String, dynamic>> discovered = {};
  final Map<String, String> modes = {};
  final Map<String, dynamic> tokens = {};
  final Map<String, String> offlineKeys = {};
  Future<bool> needsWifiSetup(String sn, String address) async {
    final info = await local(address, '/api/v1/info', '');
    if (info['sn'] != sn) {
      throw const FormatException('Nomor seri perangkat tidak cocok');
    }
    if (info['provisioning'] is bool) return info['provisioning'] as bool;
    // Compatibility with firmware that does not yet report its setup mode.
    return Uri.parse(address).host == '192.168.4.1';
  }

  Future<void> claimDevice(String sn) async {
    try {
      await api.request('/devices/claim', method: 'POST', body: {'sn': sn});
    } on ApiFailure catch (e) {
      if (e.statusCode != 409 || e.message != 'DEVICE_ALREADY_CLAIMED') rethrow;
      // A previous claim may have succeeded before its response was lost.
      // This endpoint verifies ownership; another owner's device still fails.
      await api.request('/devices/${Uri.encodeComponent(sn)}');
    }
  }

  final Map<String, Future<void>> _localQueues = {};
  int _generation = 0;
  Future<void> restoreLocal() async {
    final raw = await api.storage.read(key: 'offline_keys');
    offlineKeys.clear();
    if (raw != null) {
      offlineKeys.addAll(Map<String, String>.from(jsonDecode(raw)));
    }
  }

  Future<void> clear([String? sn]) async {
    _generation++;
    if (sn == null) {
      offlineKeys.clear();
      tokens.clear();
      addresses.clear();
      modes.clear();
    } else {
      offlineKeys.remove(sn);
      tokens.remove(sn);
      addresses.remove(sn);
      modes.remove(sn);
    }
    await api.storage.write(
      key: 'offline_keys',
      value: jsonEncode(offlineKeys),
    );
  }

  Future<String?> _offlineKey(String sn) async {
    if (offlineKeys.containsKey(sn)) return offlineKeys[sn];
    final generation = _generation;
    final credential = await token(sn);
    final random = Random.secure();
    final proposed = List.generate(
      32,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    try {
      final result = await local(
        addresses[sn]!,
        '/api/v1/local-access',
        credential['token'],
        body: {'key': proposed},
      );
      final key = result['key'];
      if (key is! String || !RegExp(r'^[a-fA-F0-9]{64}$').hasMatch(key)) {
        throw const FormatException('Kredensial lokal tidak valid');
      }
      if (generation != _generation) {
        throw StateError('Sesi lokal telah berubah');
      }
      offlineKeys[sn] = key;
      await api.storage.write(
        key: 'offline_keys',
        value: jsonEncode(offlineKeys),
      );
      return key;
    } on ApiFailure catch (e) {
      if (e.statusCode == 404) {
        return null; // Older firmware still uses short tokens.
      }
      rethrow;
    }
  }

  Future<dynamic> deviceLocal(
    String sn,
    String path, {
    dynamic body,
    String? method,
  }) async {
    // Serialize challenge/proof exchanges for each device within this app.
    final generation = _generation;
    final previous = _localQueues[sn] ?? Future<void>.value();
    final done = Completer<void>();
    _localQueues[sn] = done.future;
    await previous;
    try {
      if (generation != _generation) {
        throw StateError('Sesi lokal telah berubah');
      }
      final address = addresses[sn];
      if (address == null) {
        throw StateError('Perangkat belum ditemukan di Wi-Fi lokal');
      }
      final key = await _offlineKey(sn);
      if (key == null) {
        return await local(
          address,
          path,
          (await token(sn))['token'],
          body: body,
          method: method,
        );
      }
      final verb = method ?? (body == null ? 'GET' : 'POST');
      final encoded = body == null ? '' : jsonEncode(body);
      // Retry once if another phone replaced the device's outstanding challenge.
      for (var attempt = 0; attempt < 2; attempt++) {
        final challenge = await local(address, '/api/v1/local-challenge', '');
        final nonce = challenge['nonce'];
        if (challenge['sn'] != sn ||
            nonce is! String ||
            !RegExp(r'^[a-f0-9]{64}$').hasMatch(nonce)) {
          throw const FormatException('Identitas lokal tidak cocok');
        }
        final proof = localProof(key, sn, nonce, verb, path, encoded);
        if (generation != _generation) {
          throw StateError('Sesi lokal telah berubah');
        }
        try {
          return await local(
            address,
            path,
            '',
            body: body,
            method: verb,
            authorization: 'Local $nonce:$proof',
          );
        } on ApiFailure catch (e) {
          if (e.statusCode != 401 || attempt == 1) rethrow;
        }
      }
    } on ApiFailure catch (e) {
      if (e.statusCode == 401 || e.statusCode == 409) {
        offlineKeys.remove(sn);
        await api.storage.write(
          key: 'offline_keys',
          value: jsonEncode(offlineKeys),
        );
      }
      rethrow;
    } finally {
      done.complete();
      if (identical(_localQueues[sn], done.future)) _localQueues.remove(sn);
    }
  }

  Future<void> readLocalStates(List<dynamic> devices) async {
    for (final device in devices) {
      final sn = device['sn'] as String;
      device['local_online'] = false;
      if (device['disabled'] == true) continue;
      if (!addresses.containsKey(sn)) continue;
      try {
        device['state'] = await deviceLocal(sn, '/api/v1/status');
        device['local_online'] = true;
        modes[sn] = 'Lokal';
      } catch (_) {
        modes.remove(sn);
      }
    }
  }

  Future<dynamic> token(String sn) async {
    final generation = _generation;
    final cached = tokens[sn];
    if (cached != null &&
        DateTime.parse(
          cached['expires_at'],
        ).isAfter(DateTime.now().add(const Duration(seconds: 5)))) {
      return cached;
    }
    final value = await api.request(
      '/devices/${Uri.encodeComponent(sn)}/local-token',
    );
    if (generation != _generation) throw StateError('Sesi lokal telah berubah');
    tokens[sn] = value;
    return value;
  }

  Future<void> prefetch(Iterable<String> owned) async {
    await Future.wait(
      owned.where(addresses.containsKey).map((sn) async {
        try {
          await token(sn);
        } catch (_) {}
      }),
    );
  }

  Future<Map<String, String>> discover() async {
    RawDatagramSocket? socket;
    StreamSubscription<RawSocketEvent>? sub;
    final found = <String, String>{};
    try {
      socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      socket.broadcastEnabled = true;
      sub = socket.listen((event) {
        if (event == RawSocketEvent.read) {
          final packet = socket?.receive();
          if (packet == null) return;
          try {
            final value = jsonDecode(utf8.decode(packet.data));
            if (value['type'] == 'esp-cloud-device' && value['sn'] is String) {
              final port = value['port'];
              if (port is int && port > 0 && port < 65536) {
                found[value['sn']] = 'http://${packet.address.address}:$port';
              }
            }
          } catch (_) {}
        }
      });
      for (var attempt = 0; attempt < 3; attempt++) {
        socket.send(
          utf8.encode('ESPCTRL_DISCOVER'),
          InternetAddress('255.255.255.255'),
          4210,
        );
        await Future<void>.delayed(const Duration(milliseconds: 650));
      }
      // A missed UDP reply does not erase a paired device's last address.
      // A signed HTTP status exchange still decides whether it is online.
      addresses
        ..removeWhere((sn, _) => !offlineKeys.containsKey(sn))
        ..addAll(found);
      discovered
        ..clear()
        ..addAll(
          found.map(
            (sn, address) => MapEntry(sn, {'sn': sn, 'address': address}),
          ),
        );
      return Map<String, String>.from(found);
    } finally {
      await sub?.cancel();
      socket?.close();
    }
  }

  Future<dynamic> local(
    String address,
    String path,
    String token, {
    dynamic body,
    String? method,
    String? authorization,
  }) async {
    final uri = Uri.parse('$address$path');
    final headers = {
      'Content-Type': 'application/json',
      if (authorization != null || token.isNotEmpty)
        'Authorization': authorization ?? 'Bearer $token',
    };
    final r =
        await (method == 'DELETE'
                ? api.client.delete(uri, headers: headers)
                : body == null
                ? api.client.get(uri, headers: headers)
                : api.client.post(
                    uri,
                    headers: headers,
                    body: jsonEncode(body),
                  ))
            .timeout(const Duration(seconds: 15));
    final value = jsonDecode(r.body);
    if (r.statusCode >= 400 || value['status'] == 'error') {
      throw ApiFailure(
        r.statusCode,
        value['message'] ?? value['code'] ?? 'Perangkat tidak merespons',
      );
    }
    return value['data'];
  }

  Future<dynamic> command(
    String sn,
    String command, {
    int? pin,
    bool? state,
    int? channelId,
  }) async {
    final id = const Uuid().v4();
    Object? localError;
    if (command == 'gpio.set' && addresses.containsKey(sn)) {
      try {
        final ack = await deviceLocal(
          sn,
          '/api/v1/gpio',
          body: {'pin': pin, 'channel_id': channelId, 'state': state, 'request_id': id},
        );
        if (ack['request_id'] != id || ack['success'] != true) {
          throw Exception('ACK lokal tidak valid');
        }
        modes[sn] = 'Lokal';
        return ack;
      } catch (e) {
        localError = e;
        /* Idempotent GPIO retries reuse their request ID. */
      }
    }
    final path = '/devices/${Uri.encodeComponent(sn)}/commands';
    try {
      await api.request(
        path,
        method: 'POST',
        body: {
          'command': command,
          'request_id': id,
          'pin': ?pin,
          'channel_id': ?channelId,
          'state': ?state,
        },
      );
    } catch (e) {
      if (localError != null) {
        throw Exception('Kontrol lokal gagal: $localError. Cloud: $e');
      }
      rethrow;
    }
    for (var i = 0; i < 30; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
      final ack = await api.request('$path/$id');
      final status = ack['command_status'] ?? ack['status'];
      if (status == 'success') {
        modes[sn] = 'Cloud';
        return ack;
      }
      if (status == 'failed' || status == 'timeout') {
        throw Exception(ack['error'] ?? 'Perintah gagal: $status');
      }
    }
    throw TimeoutException(
      'Belum ada konfirmasi perangkat. Periksa status sebelum mencoba lagi.',
    );
  }

  Future<dynamic> updateChannelAlias(String sn, int channelId, String alias) =>
      api.request('/devices/${Uri.encodeComponent(sn)}/channels/$channelId', method: 'PATCH', body: {'alias': alias});

  Future<void> provision(
    String ssid,
    String password,
    String setupCode, {
    String address = 'http://192.168.4.1',
    String? token,
  }) async {
    final r = await api.client
        .post(
          Uri.parse('$address/api/v1/provision'),
          headers: {
            'Content-Type': 'application/json',
            if (token != null) 'Authorization': 'Bearer $token',
          },
          body: jsonEncode({
            'ssid': ssid,
            'password': password,
            'setup_code': setupCode,
          }),
        )
        .timeout(const Duration(seconds: 12));
    final value = jsonDecode(r.body);
    if (r.statusCode >= 400 || value['status'] == 'error') {
      throw Exception(value['message'] ?? 'Provisioning gagal');
    }
  }
}
