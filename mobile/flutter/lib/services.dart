import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';

Map<String, dynamic> parseClaim(String raw) {
  String? sn, code;
  if (raw.trim().startsWith('{')) {
    final value = jsonDecode(raw) as Map<String, dynamic>;
    if (value['type'] != 'esp-cloud' || value.containsKey('device_key')) {
      throw const FormatException('QR tidak valid');
    }
    sn = value['sn'] as String?;
    code = value['claim_code'] as String?;
  } else {
    final uri = Uri.parse(raw);
    if (uri.scheme.toLowerCase() != 'espctrl' || uri.host != 'claim') {
      throw const FormatException('QR tidak valid');
    }
    sn = uri.queryParameters['sn'];
    code = uri.queryParameters['code'];
  }
  if (sn == null || code == null || sn.isEmpty || code.isEmpty) {
    throw const FormatException('Nomor seri dan kode klaim wajib diisi');
  }
  return {'sn': sn, 'claim_code': code};
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
      throw Exception(result['message'] ?? 'Koneksi gagal');
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
    }
  }
}

class DeviceNetwork {
  DeviceNetwork(this.api);
  final Api api;
  final Map<String, String> addresses = {};
  final Map<String, String> modes = {};
  final Map<String, dynamic> tokens = {};
  void clear([String? sn]) { if(sn==null){tokens.clear();addresses.clear();modes.clear();}else{tokens.remove(sn);addresses.remove(sn);modes.remove(sn);} }
  Future<dynamic> token(String sn) async {
    final cached=tokens[sn];
    if(cached!=null && DateTime.parse(cached['expires_at']).isAfter(DateTime.now().add(const Duration(seconds:5)))) return cached;
    final value=await api.request('/devices/${Uri.encodeComponent(sn)}/local-token');
    tokens[sn]=value;return value;
  }
  Future<void> prefetch(Iterable<String> owned) async {await Future.wait(owned.where(addresses.containsKey).map((sn)async{try{await token(sn);}catch(_){}}));}
  Future<void> discover() async {
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
      socket.send(
        utf8.encode('ESPCTRL_DISCOVER'),
        InternetAddress('255.255.255.255'),
        4210,
      );
      await Future<void>.delayed(const Duration(milliseconds: 650));
      addresses
        ..clear()
        ..addAll(found);
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
  }) async {
    final uri = Uri.parse('$address$path');
    final headers = {
      'Content-Type': 'application/json',
      'Authorization': 'Bearer $token',
    };
    final r =
        await (body == null
                ? api.client.get(uri, headers: headers)
                : api.client.post(
                    uri,
                    headers: headers,
                    body: jsonEncode(body),
                  ))
            .timeout(const Duration(seconds: 2));
    final value = jsonDecode(r.body);
    if (r.statusCode >= 400 || value['status'] == 'error') {
      throw Exception(value['message'] ?? 'Perangkat tidak merespons');
    }
    return value['data'];
  }

  Future<dynamic> command(
    String sn,
    String command, {
    int? pin,
    bool? state,
  }) async {
    final id = const Uuid().v4();
    if (command == 'gpio.set' && addresses.containsKey(sn)) {
      try {
        final credential = await token(sn);
        final ack = await local(
          addresses[sn]!,
          '/api/v1/gpio',
          credential['token'],
          body: {'pin': pin, 'state': state, 'request_id': id},
        );
        if (ack['request_id'] != id || ack['success'] != true) {
          throw Exception('ACK lokal tidak valid');
        }
        modes[sn] = 'Lokal';
        return ack;
      } catch (_) {
        /* Idempotent GPIO retries reuse their request ID. */
      }
    }
    final path = '/devices/${Uri.encodeComponent(sn)}/commands';
    await api.request(
      path,
      method: 'POST',
      body: {
        'command': command,
        'request_id': id,
        'pin': ?pin,
        'state': ?state,
      },
    );
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

  Future<void> provision(String ssid, String password, String setupCode) async {
    final r = await api.client
        .post(
          Uri.parse('http://192.168.4.1/api/v1/provision'),
          headers: {'Content-Type': 'application/json'},
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
