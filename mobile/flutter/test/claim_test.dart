import 'dart:convert';
import 'dart:io';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:rizio/services.dart';

http.Response result(dynamic data) =>
    http.Response(jsonEncode({'status': 'success', 'data': data}), 200);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  test(
    'Pending setup claims when internet returns without discovery tap',
    () async {
      var online = false;
      var claims = 0;
      final api = Api(
        client: MockClient((request) async {
          if (!online) throw const SocketException('Offline');
          expect(request.url.path, '/v1/devices/claim');
          expect(jsonDecode(request.body), {'sn': 'ESP-1'});
          claims++;
          return result({'sn': 'ESP-1'});
        }),
      );
      await api.savePendingClaim({'sn': 'ESP-1'});
      await api.flushPendingClaim();
      expect(await api.storage.read(key: 'pending_claim'), isNotNull);
      online = true;
      await api.flushPendingClaim();
      expect(await api.storage.read(key: 'pending_claim'), isNull);
      await api.flushPendingClaim();
      expect(claims, 1);
    },
  );

  test('Pending claim clears after lost response only for its owner', () async {
    final api = Api(
      client: MockClient((request) async {
        if (request.url.path.endsWith('/claim')) {
          return http.Response(
            '{"status":"error","message":"DEVICE_ALREADY_CLAIMED"}',
            409,
          );
        }
        expect(request.url.path, '/v1/devices/ESP-1');
        return result({'sn': 'ESP-1'});
      }),
    );
    await api.savePendingClaim({'sn': 'ESP-1'});
    await api.flushPendingClaim();
    expect(await api.storage.read(key: 'pending_claim'), isNull);
  });

  for (final mode in [true, false, null]) {
    test('Setup detection respects firmware mode $mode', () async {
      final network = DeviceNetwork(
        Api(
          client: MockClient((request) async {
            expect(request.url.path, '/api/v1/info');
            return result({'sn': 'ESP-1', 'provisioning': ?mode});
          }),
        ),
      );
      expect(
        await network.needsWifiSetup('ESP-1', 'http://192.168.1.26'),
        mode ?? false,
      );
      expect(
        await network.needsWifiSetup('ESP-1', 'http://192.168.4.1'),
        mode ?? true,
      );
    });
  }

  test('Wrong device at discovered IP is rejected', () async {
    final network = DeviceNetwork(
      Api(
        client: MockClient(
          (_) async => result({'sn': 'ESP-OTHER', 'provisioning': false}),
        ),
      ),
    );
    await expectLater(
      network.needsWifiSetup('ESP-1', 'http://192.168.1.26'),
      throwsFormatException,
    );
  });

  test(
    'Connected device claims without provisioning or local owner token',
    () async {
      final paths = <String>[];
      final network = DeviceNetwork(
        Api(
          client: MockClient((request) async {
            paths.add(request.url.path);
            if (request.url.path == '/api/v1/info') {
              return result({'sn': 'ESP-1', 'provisioning': false});
            }
            expect(request.method, 'POST');
            expect(jsonDecode(request.body), {'sn': 'ESP-1'});
            return result({'sn': 'ESP-1'});
          }),
        ),
      );
      if (!await network.needsWifiSetup('ESP-1', 'http://192.168.1.26')) {
        await network.claimDevice('ESP-1');
      }
      expect(paths, ['/api/v1/info', '/v1/devices/claim']);
    },
  );

  for (final owned in [true, false]) {
    test('Already claimed requires ownership: $owned', () async {
      final network = DeviceNetwork(
        Api(
          client: MockClient((request) async {
            if (request.url.path.endsWith('/claim')) {
              return http.Response(
                '{"status":"error","message":"DEVICE_ALREADY_CLAIMED"}',
                409,
              );
            }
            expect(request.url.path, '/v1/devices/ESP-1');
            return owned
                ? result({'sn': 'ESP-1'})
                : http.Response(
                    '{"status":"error","message":"DEVICE_NOT_OWNED"}',
                    403,
                  );
          }),
        ),
      );
      if (owned) {
        await network.claimDevice('ESP-1');
      } else {
        await expectLater(
          network.claimDevice('ESP-1'),
          throwsA(isA<ApiFailure>()),
        );
      }
    });
  }

  test(
    'Invalid account authentication is not treated as successful claim',
    () async {
      final network = DeviceNetwork(
        Api(
          client: MockClient(
            (_) async => http.Response(
              '{"status":"error","message":"AUTH_INVALID"}',
              401,
            ),
          ),
        ),
      );
      await expectLater(
        network.claimDevice('ESP-1'),
        throwsA(isA<ApiFailure>().having((e) => e.statusCode, 'status', 401)),
      );
    },
  );
}
