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
    defaultValue: 'https://rizio.rizbill.my.id/v1',
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
      await storage.delete(key: 'pending_local_pair');
    }
  }

  Future<List<dynamic>> temperatureHistory(
    String sn, {
    int rangeHours = 24,
    int bucketMinutes = 30,
  }) async {
    final result = await request(
      '/devices/${Uri.encodeComponent(sn)}/temperature-history'
      '?range_hours=$rangeHours&bucket_minutes=$bucketMinutes',
    );
    return (result as List<dynamic>);
  }

  Future<List<dynamic>> scenes() async => (await request('/scenes')) as List<dynamic>;

  Future<Map<String, dynamic>> createScene(
    String sn,
    String name,
    List<Map<String, dynamic>> actions,
  ) async => Map<String, dynamic>.from(await request(
        '/devices/${Uri.encodeComponent(sn)}/scenes',
        method: 'POST',
        body: {'name': name, 'actions': actions},
      ));

  Future<void> deleteScene(String id) async {
    await request('/scenes/${Uri.encodeComponent(id)}', method: 'DELETE');
  }

  Future<Map<String, dynamic>> updateScene(String id, Map<String, dynamic> body) async =>
      Map<String, dynamic>.from(await request('/scenes/${Uri.encodeComponent(id)}', method: 'PATCH', body: body));

  Future<List<dynamic>> schedules() async => (await request('/schedules')) as List<dynamic>;

  Future<Map<String, dynamic>> createSchedule(
    String sn,
    Map<String, dynamic> body,
  ) async => Map<String, dynamic>.from(await request(
        '/devices/${Uri.encodeComponent(sn)}/schedules',
        method: 'POST',
        body: body,
      ));

  Future<void> deleteSchedule(String id) async {
    await request('/schedules/${Uri.encodeComponent(id)}', method: 'DELETE');
  }

  Future<Map<String, dynamic>> updateSchedule(String id, Map<String, dynamic> body) async =>
      Map<String, dynamic>.from(await request('/schedules/${Uri.encodeComponent(id)}', method: 'PATCH', body: body));

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

  Future<void> savePendingLocalPair(Map<String, dynamic> pair) async {
    await storage.write(key: 'pending_local_pair', value: jsonEncode(pair));
  }

  Future<Map<String, dynamic>?> pendingLocalPair() async {
    final raw = await storage.read(key: 'pending_local_pair');
    return raw == null ? null : jsonDecode(raw) as Map<String, dynamic>;
  }

  Future<void> clearPendingLocalPair() =>
      storage.delete(key: 'pending_local_pair');

  Future<void> savePendingDelete(Map<String, dynamic> deletion) async {
    await storage.write(key: 'pending_delete', value: jsonEncode(deletion));
  }

  Future<Map<String, dynamic>?> pendingDelete() async {
    final raw = await storage.read(key: 'pending_delete');
    return raw == null ? null : jsonDecode(raw) as Map<String, dynamic>;
  }

  Future<void> clearPendingDelete() => storage.delete(key: 'pending_delete');

  Future<void> flushPendingDelete() async {
    final deletion = await pendingDelete();
    if (deletion == null) return;
    try {
      await request(
        '/devices/${Uri.encodeComponent(deletion['sn'] as String)}',
        method: 'DELETE',
        body: {'password': deletion['password']},
      );
      await clearPendingDelete();
    } on ApiFailure catch (e) {
      // Keep the queue for network/server failures. Invalid credentials or a
      // device already removed from cloud must not retry forever.
      if (e.statusCode == 400 ||
          e.statusCode == 401 ||
          e.statusCode == 403 ||
          e.statusCode == 404) {
        await clearPendingDelete();
      }
    } catch (_) {
      // Offline: retry on the next app refresh/resume.
    }
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

  Future<void> pairOffline(String sn, String address, String setupCode) async {
    final random = Random.secure();
    final key = List.generate(
      32,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    final result = await local(
      address,
      '/api/v1/local-pair',
      '',
      body: {'setup_code': setupCode, 'key': key},
    );
    final pairedKey = result['key'];
    if (pairedKey is! String || pairedKey.length != 64) {
      throw const FormatException('Kredensial lokal tidak valid');
    }
    offlineKeys[sn] = pairedKey;
    addresses[sn] = address;
    await api.storage.write(
      key: 'offline_keys',
      value: jsonEncode(offlineKeys),
    );
  }

  Future<bool> tryPairOffline(String sn, String setupCode) async {
    final address = addresses[sn];
    if (address == null) return false;
    try {
      await pairOffline(sn, address, setupCode);
      return true;
    } catch (_) {
      return false;
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
      sub = socket.listen(
        (event) {
          if (event == RawSocketEvent.read) {
            final packet = socket?.receive();
            if (packet == null) return;
            try {
              final value = jsonDecode(utf8.decode(packet.data));
              if (value['type'] == 'esp-cloud-device' &&
                  value['sn'] is String) {
                final port = value['port'];
                if (port is int && port > 0 && port < 65536) {
                  found[value['sn']] = 'http://${packet.address.address}:$port';
                  discovered[value['sn']] = {
                    'sn': value['sn'],
                    'address': 'http://${packet.address.address}:$port',
                    'model': value['model'],
                    'device_type': value['device_type'] ?? 'relay',
                    'relay_type': value['relay_type'],
                    'channels': value['channels'] ?? <dynamic>[],
                  };
                }
              }
            } catch (_) {}
          }
        },
        onError: (_) {
          // A network handover or offline Wi-Fi can invalidate the UDP socket.
          // Discovery is best-effort and must never crash the Flutter tree.
        },
      );
      for (var attempt = 0; attempt < 3; attempt++) {
        try {
          socket.send(
            utf8.encode('ESPCTRL_DISCOVER'),
            InternetAddress('255.255.255.255'),
            4210,
          );
        } on SocketException {
          break;
        } on OSError {
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 650));
      }
      // A missed UDP reply does not erase a paired device's last address.
      // A signed HTTP status exchange still decides whether it is online.
      addresses
        ..removeWhere((sn, _) => !offlineKeys.containsKey(sn))
        ..addAll(found);
      discovered.removeWhere((sn, _) => !found.containsKey(sn));
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
          body: {
            'channel_id': channelId,
            // channel_id is authoritative. Do not let stale discovery
            // metadata redirect a channel to another GPIO.
            if (channelId == null) 'pin': pin,
            'state': state,
            'request_id': id,
          },
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
          'channel_id': ?channelId,
          if (channelId == null) 'pin': ?pin,
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
      api.request(
        '/devices/${Uri.encodeComponent(sn)}/channels/$channelId',
        method: 'PATCH',
        body: {'alias': alias},
      );

  Future<void> provision(
    String ssid,
    String password,
    String setupCode, {
    String address = 'http://192.168.4.1',
    String? token,
  }) async {
    late http.Response r;
    try {
      r = await api.client
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
    } on SocketException {
      throw ApiFailure(
        503,
        'Tidak dapat terhubung ke ESP. Sambungkan HP ke Wi‑Fi AP ESP terlebih dahulu.',
      );
    } on TimeoutException {
      throw ApiFailure(
        504,
        'ESP tidak merespons. Pastikan HP terhubung ke AP ESP dan alamat 192.168.4.1 dapat dibuka.',
      );
    }
    dynamic value;
    try {
      value = jsonDecode(r.body);
    } catch (_) {
      throw ApiFailure(
        r.statusCode,
        'Respons ESP tidak valid. Pastikan HP masih terhubung ke AP ESP.',
      );
    }
    if (r.statusCode >= 400 || value['status'] == 'error') {
      throw ApiFailure(r.statusCode, value['message'] ?? 'Provisioning gagal');
    }
  }
}
