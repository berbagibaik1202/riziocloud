import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:rizio/services.dart';

http.Response ok(dynamic data) =>
    http.Response(jsonEncode({'status': 'success', 'data': data}), 200);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));
  final key = 'a' * 64;
  final nonce = 'b' * 64;

  test(
    'Paired phone controls GPIO after app restart without any cloud request',
    () async {
      FlutterSecureStorage.setMockInitialValues({
        'offline_keys': jsonEncode({'ESP-1': key}),
      });
      final requests = <String>[];
      final api = Api(
        client: MockClient((request) async {
          requests.add(request.url.path);
          if (request.url.host != '192.168.1.26') {
            throw const SocketException('No internet');
          }
          if (request.url.path == '/api/v1/local-challenge') {
            return ok({'sn': 'ESP-1', 'nonce': nonce});
          }
          expect(request.url.path, '/api/v1/gpio');
          expect(
            request.headers['authorization'],
            'Local $nonce:${localProof(key, 'ESP-1', nonce, 'POST', request.url.path, request.body)}',
          );
          expect(request.headers['authorization'], isNot(contains(key)));
          final body = jsonDecode(request.body);
          return ok({
            'request_id': body['request_id'],
            'success': true,
            'state': {
              'gpio': {'5': body['state']},
            },
          });
        }),
      );
      final network = DeviceNetwork(api);
      await network.restoreLocal();
      network.addresses['ESP-1'] = 'http://192.168.1.26';
      final ack = await network.command(
        'ESP-1',
        'gpio.set',
        pin: 5,
        state: true,
      );
      expect(ack['state']['gpio']['5'], true);
      expect(network.modes['ESP-1'], 'Lokal');
      expect(requests, ['/api/v1/local-challenge', '/api/v1/gpio']);
    },
  );

  test(
    'Enrollment uses owner token once and persists a separate random key',
    () async {
      String? enrolled;
      var tokenRequests = 0;
      final api = Api(
        client: MockClient((request) async {
          if (request.url.path.endsWith('/local-token')) {
            tokenRequests++;
            return ok({
              'token': 'owner-token',
              'expires_at': DateTime.now()
                  .add(const Duration(seconds: 60))
                  .toIso8601String(),
            });
          }
          if (request.url.path == '/api/v1/local-access') {
            expect(request.headers['authorization'], 'Bearer owner-token');
            enrolled = jsonDecode(request.body)['key'];
            expect(enrolled, matches(RegExp(r'^[a-f0-9]{64}$')));
            return ok({'key': enrolled});
          }
          if (request.url.path == '/api/v1/local-challenge') {
            return ok({'sn': 'ESP-1', 'nonce': nonce});
          }
          return ok({
            'gpio': {'5': false},
          });
        }),
      );
      final network = DeviceNetwork(api)
        ..addresses['ESP-1'] = 'http://192.168.1.26';
      await network.deviceLocal('ESP-1', '/api/v1/status');
      final restarted = DeviceNetwork(api);
      await restarted.restoreLocal();
      restarted.addresses['ESP-1'] = 'http://192.168.1.26';
      await restarted.deviceLocal('ESP-1', '/api/v1/status');
      expect(restarted.offlineKeys['ESP-1'], enrolled);
      expect(tokenRequests, 1);
    },
  );

  test(
    'Authenticated LAN status overrides stale cloud state without marking cloud online',
    () async {
      final api = Api(
        client: MockClient(
          (request) async => request.url.path.endsWith('local-challenge')
              ? ok({'sn': 'ESP-1', 'nonce': nonce})
              : ok({
                  'gpio': {'5': true},
                }),
        ),
      );
      final network = DeviceNetwork(api)
        ..offlineKeys['ESP-1'] = key
        ..addresses['ESP-1'] = 'http://192.168.1.26';
      final devices = [
        {
          'sn': 'ESP-1',
          'online': false,
          'state': {
            'gpio': {'5': false},
          },
        },
      ];
      await network.readLocalStates(devices);
      expect(devices.single['online'], false);
      expect(devices.single['local_online'], true);
      expect((devices.single['state'] as Map)['gpio']['5'], true);
    },
  );

  test('Challenge for another serial cannot authorize a request', () async {
    var requests = 0;
    final network =
        DeviceNetwork(
            Api(
              client: MockClient((request) async {
                requests++;
                return ok({'sn': 'ESP-OTHER', 'nonce': nonce});
              }),
            ),
          )
          ..offlineKeys['ESP-1'] = key
          ..addresses['ESP-1'] = 'http://192.168.1.26';
    await expectLater(
      network.deviceLocal('ESP-1', '/api/v1/status'),
      throwsFormatException,
    );
    expect(requests, 1);
  });

  test(
    'Rejected challenge is refreshed once without contacting cloud',
    () async {
      var attempts = 0;
      final network =
          DeviceNetwork(
              Api(
                client: MockClient((request) async {
                  if (request.url.path.endsWith('local-challenge')) {
                    return ok({'sn': 'ESP-1', 'nonce': nonce});
                  }
                  if (++attempts == 1) {
                    return http.Response(
                      '{"status":"error","code":"AUTH_INVALID"}',
                      401,
                    );
                  }
                  return ok({
                    'gpio': {'5': false},
                  });
                }),
              ),
            )
            ..offlineKeys['ESP-1'] = key
            ..addresses['ESP-1'] = 'http://192.168.1.26';
      expect(
        (await network.deviceLocal('ESP-1', '/api/v1/status'))['gpio']['5'],
        false,
      );
      expect(attempts, 2);
    },
  );

  test(
    'Logout removes offline account and local credentials even without internet',
    () async {
      FlutterSecureStorage.setMockInitialValues({
        'refresh': 'refresh-token',
        'offline_keys': jsonEncode({'ESP-1': key}),
        'offline_home': jsonEncode({
          'user': {'id': 'owner'},
          'devices': [
            {'sn': 'ESP-1'},
          ],
        }),
      });
      final api = Api(
        client: MockClient(
          (_) async => throw const SocketException('No internet'),
        ),
      )..refresh = 'refresh-token';
      expect((await api.cachedHome())?['user']['id'], 'owner');
      await expectLater(api.logout(), throwsA(isA<SocketException>()));
      expect(await api.cachedHome(), null);
      expect(await api.storage.read(key: 'offline_keys'), null);
    },
  );

  test('Proof binds device, nonce, method, path and exact request body', () {
    final proof = localProof(key, 'ESP-1', nonce, 'POST', '/api/v1/gpio', '{}');
    // Independent reference generated with Node.js crypto.createHmac.
    expect(
      proof,
      '792187f4abe5196105826faf8610bad51945c320c2cde7cd6603c53a14adb148',
    );
    expect(
      localProof(key, 'ESP-2', nonce, 'POST', '/api/v1/gpio', '{}'),
      isNot(proof),
    );
    expect(
      localProof(key, 'ESP-1', 'c' * 64, 'POST', '/api/v1/gpio', '{}'),
      isNot(proof),
    );
    expect(
      localProof(key, 'ESP-1', nonce, 'GET', '/api/v1/gpio', '{}'),
      isNot(proof),
    );
    expect(
      localProof(key, 'ESP-1', nonce, 'POST', '/api/v1/status', '{}'),
      isNot(proof),
    );
    expect(
      localProof(key, 'ESP-1', nonce, 'POST', '/api/v1/gpio', '{"state":true}'),
      isNot(proof),
    );
  });

  test(
    'Clearing a session during enrollment cannot restore its offline key',
    () async {
      final started = Completer<void>();
      final response = Completer<http.Response>();
      final api = Api(
        client: MockClient((request) async {
          if (request.url.path.endsWith('local-token')) {
            return ok({
              'token': 'owner-token',
              'expires_at': DateTime.now()
                  .add(const Duration(seconds: 60))
                  .toIso8601String(),
            });
          }
          started.complete();
          return response.future;
        }),
      );
      final network = DeviceNetwork(api)
        ..addresses['ESP-1'] = 'http://192.168.1.26';
      final pending = network.deviceLocal('ESP-1', '/api/v1/status');
      await started.future;
      await network.clear();
      final rejected = expectLater(pending, throwsStateError);
      response.complete(ok({'key': key}));
      await rejected;
      final restored = DeviceNetwork(api);
      await restored.restoreLocal();
      expect(restored.offlineKeys, isEmpty);
    },
  );
}
