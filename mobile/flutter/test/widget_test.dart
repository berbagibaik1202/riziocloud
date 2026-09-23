import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:rizio/services.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));
  test('QR URI and JSON extract a serial number', () {
    expect(parseClaim('ESPCTRL://claim?sn=ESP-1&code=abc')['sn'], 'ESP-1');
    expect(parseClaim('{"type":"esp-cloud","sn":"ESP-1"}')['sn'], 'ESP-1');
  });
  test('Invalid QR and missing serial rejected', () {
    expect(() => parseClaim('https://evil.test'), throwsFormatException);
    expect(() => parseClaim('ESPCTRL://claim'), throwsFormatException);
    expect(
      () =>
          parseClaim('{"type":"esp-cloud","sn":"ESP-1","device_key":"secret"}'),
      throwsFormatException,
    );
  });
  test('Local failure reuses request ID and waits for cloud ACK', () async {
    String? localId, cloudId;
    var polls = 0;
    final api = Api(
      client: MockClient((r) async {
        dynamic data;
        if (r.url.path.endsWith('local-token')) {
          data = {
            'token': 'short',
            'expires_at': DateTime.now()
                .add(const Duration(seconds: 60))
                .toIso8601String(),
          };
        } else if (r.url.path == '/api/v1/local-access') {
          return http.Response('{"status":"error","code":"NOT_FOUND"}', 404);
        } else if (r.url.path == '/api/v1/gpio') {
          localId = jsonDecode(r.body)['request_id'];
          return http.Response(
            '{"status":"error","message":"lost response"}',
            503,
          );
        } else if (r.method == 'POST') {
          cloudId = jsonDecode(r.body)['request_id'];
          data = {'request_id': cloudId, 'command_status': 'pending'};
        } else {
          polls++;
          data = {
            'request_id': cloudId,
            'command_status': polls == 1 ? 'sent' : 'success',
          };
        }
        return http.Response(
          jsonEncode({'status': 'success', 'data': data}),
          200,
        );
      }),
    );
    final network = DeviceNetwork(api);
    network.addresses['ESP-1'] = 'http://192.168.1.20';
    final ack = await network.command('ESP-1', 'gpio.set', pin: 5, state: true);
    expect(localId, isNotNull);
    expect(cloudId, localId);
    expect(polls, 2);
    expect(ack['command_status'], 'success');
    expect(network.modes['ESP-1'], 'Cloud');
  });
  test('Failed ACK never reports success', () async {
    final api = Api(
      client: MockClient(
        (r) async => http.Response(
          jsonEncode({
            'status': 'success',
            'data': {
              'command_status': r.method == 'POST' ? 'pending' : 'failed',
              'error': 'pin rejected',
            },
          }),
          200,
        ),
      ),
    );
    final network = DeviceNetwork(api);
    await expectLater(
      network.command('ESP-1', 'gpio.set', pin: 5, state: true),
      throwsException,
    );
    expect(network.modes, isEmpty);
  });
  test('Provisioning sends the device-specific setup code', () async {
    final api = Api(
      client: MockClient((r) async {
        expect(r.url, Uri.parse('http://192.168.4.1/api/v1/provision'));
        expect(jsonDecode(r.body), {
          'ssid': 'Home Wi-Fi',
          'password': 'secret123',
          'setup_code': 'unique-setup-code',
        });
        return http.Response(
          '{"status":"success","data":{"restarting":true}}',
          200,
        );
      }),
    );
    await DeviceNetwork(
      api,
    ).provision('Home Wi-Fi', 'secret123', 'unique-setup-code');
  });
  test('Provisioning can target the discovered device address', () async {
    final api = Api(
      client: MockClient((r) async {
        expect(r.url, Uri.parse('http://192.168.4.20:80/api/v1/provision'));
        return http.Response(
          '{"status":"success","data":{"restarting":true}}',
          200,
        );
      }),
    );
    await DeviceNetwork(api).provision(
      'Home Wi-Fi',
      'secret123',
      DeviceNetwork.defaultSetupCode,
      address: 'http://192.168.4.20:80',
    );
  });
  test('Provisioning sends a local token for Wi-Fi reconfiguration', () async {
    final api = Api(
      client: MockClient((r) async {
        expect(r.headers['authorization'], 'Bearer local-token');
        return http.Response(
          '{"status":"success","data":{"restarting":true}}',
          200,
        );
      }),
    );
    await DeviceNetwork(api).provision(
      'New Wi-Fi',
      'secret123',
      DeviceNetwork.defaultSetupCode,
      token: 'local-token',
    );
  });
}
