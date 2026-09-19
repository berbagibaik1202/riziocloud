import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:rizio/services.dart';

void main(){
 test('QR URI and JSON supported',(){expect(parseClaim('ESPCTRL://claim?sn=ESP-1&code=abc')['sn'],'ESP-1');expect(parseClaim('{"type":"esp-cloud","sn":"ESP-1","claim_code":"abc"}')['claim_code'],'abc');});
 test('Invalid QR and missing code rejected',(){expect(()=>parseClaim('https://evil.test'),throwsFormatException);expect(()=>parseClaim('ESPCTRL://claim?sn=ESP-1'),throwsFormatException);expect(()=>parseClaim('{"type":"esp-cloud","sn":"ESP-1","device_key":"secret"}'),throwsFormatException);});
 test('Local failure reuses request ID and waits for cloud ACK',()async{
 String? localId,cloudId;var polls=0;
 final api=Api(client:MockClient((r)async{
 dynamic data;
 if(r.url.path.endsWith('local-token')){data={'token':'short','expires_at':DateTime.now().add(const Duration(seconds:60)).toIso8601String()};}
 else if(r.url.path=='/api/v1/gpio'){localId=jsonDecode(r.body)['request_id'];return http.Response('{"status":"error","message":"lost response"}',503);}
 else if(r.method=='POST'){cloudId=jsonDecode(r.body)['request_id'];data={'request_id':cloudId,'command_status':'pending'};}
 else {polls++;data={'request_id':cloudId,'command_status':polls==1?'sent':'success'};}
 return http.Response(jsonEncode({'status':'success','data':data}),200);
 }));
 final network=DeviceNetwork(api);network.addresses['ESP-1']='http://192.168.1.20';final ack=await network.command('ESP-1','gpio.set',pin:5,state:true);
 expect(localId,isNotNull);expect(cloudId,localId);expect(polls,2);expect(ack['command_status'],'success');expect(network.modes['ESP-1'],'Cloud');
 });
 test('Failed ACK never reports success',()async{
 final api=Api(client:MockClient((r)async=>http.Response(jsonEncode({'status':'success','data':{'command_status':r.method=='POST'?'pending':'failed','error':'pin rejected'}}),200)));
 final network=DeviceNetwork(api);await expectLater(network.command('ESP-1','gpio.set',pin:5,state:true),throwsException);expect(network.modes,isEmpty);
 });
}
