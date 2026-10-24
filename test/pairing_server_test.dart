import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:my_tv/data/models.dart';
import 'package:my_tv/data/pairing_server.dart';

/// The pairing form is reachable by anything on the same network, so the PIN
/// gate and the shutdown behaviour are the parts worth pinning down.
void main() {
  late PairingServer server;
  late PairingSession session;

  setUp(() async {
    server = PairingServer(lifetime: const Duration(seconds: 30));
    try {
      session = await server.start();
    } on PairingException {
      // No usable network interface on this machine.
      markTestSkipped('no local network address available');
      rethrow;
    }
  });

  tearDown(() async {
    await server.dispose();
  });

  Future<HttpClientResponse> post(String body) async {
    final client = HttpClient();
    final request = await client.postUrl(
      Uri.parse('http://127.0.0.1:${session.port}/add'),
    );
    request.headers.contentType = ContentType(
      'application',
      'x-www-form-urlencoded',
    );
    request.write(body);
    final response = await request.close();
    client.close();
    return response;
  }

  Future<HttpClientResponse> get(String path) async {
    final client = HttpClient();
    final request = await client.getUrl(
      Uri.parse('http://127.0.0.1:${session.port}$path'),
    );
    final response = await request.close();
    client.close();
    return response;
  }

  test('the session exposes an address, a port and a four digit code', () {
    expect(session.address, isNotEmpty);
    expect(session.port, greaterThan(0));
    expect(session.pin, matches(RegExp(r'^\d{4}$')));
    expect(session.url, 'http://${session.address}:${session.port}');
    expect(session.urlWithPin, endsWith('/?k=${session.pin}'));
  });

  test('the form is served over the network', () async {
    final response = await get('/');
    expect(response.statusCode, 200);
    final body = await utf8.decoder.bind(response).join();
    expect(body, contains('Add a playlist'));
    expect(body, contains('name="pin"'));
  });

  test('the code is prefilled only when the scanned link carries it', () async {
    final scanned = await utf8.decoder
        .bind(await get('/?k=${session.pin}'))
        .join();
    expect(scanned, contains('value="${session.pin}"'));

    final typed = await utf8.decoder.bind(await get('/')).join();
    expect(typed, contains('value=""'));
  });

  test('a wrong code is refused and submits nothing', () async {
    final received = <PlaylistSource>[];
    final sub = server.submissions.listen(received.add);

    final wrong = session.pin == '0000' ? '1111' : '0000';
    final response = await post(
      'pin=$wrong&host=http://example.com&username=u&password=p',
    );
    expect(response.statusCode, 403);

    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(received, isEmpty);
    await sub.cancel();
  });

  test('the three fields submit an Xtream source', () async {
    final received = <PlaylistSource>[];
    final sub = server.submissions.listen(received.add);

    final response = await post(
      'pin=${session.pin}&name=Mine&host=${Uri.encodeQueryComponent('http://example.com:8080')}'
      '&username=user1&password=pass1',
    );
    expect(response.statusCode, 200);

    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(received, hasLength(1));
    final source = received.single;
    expect(source.kind, SourceKind.xtream);
    expect(source.name, 'Mine');
    expect(source.host, 'http://example.com:8080');
    expect(source.username, 'user1');
    expect(source.password, 'pass1');
    await sub.cancel();
  });

  test('a pasted provider link is split into the three fields', () async {
    final received = <PlaylistSource>[];
    final sub = server.submissions.listen(received.add);

    final link = Uri.encodeQueryComponent(
      'http://example.com:8080/get.php?username=abc&password=xyz&type=m3u_plus',
    );
    final response = await post('pin=${session.pin}&link=$link');
    expect(response.statusCode, 200);

    await Future<void>.delayed(const Duration(milliseconds: 200));
    final source = received.single;
    expect(source.kind, SourceKind.xtream);
    expect(source.host, 'http://example.com:8080');
    expect(source.username, 'abc');
    expect(source.password, 'xyz');
    await sub.cancel();
  });

  test('a pasted .m3u link becomes an M3U source', () async {
    final received = <PlaylistSource>[];
    final sub = server.submissions.listen(received.add);

    final link = Uri.encodeQueryComponent('http://example.com/list.m3u');
    final response = await post('pin=${session.pin}&link=$link');
    expect(response.statusCode, 200);

    await Future<void>.delayed(const Duration(milliseconds: 200));
    final source = received.single;
    expect(source.kind, SourceKind.m3u);
    expect(source.url, 'http://example.com/list.m3u');
    await sub.cancel();
  });

  test('an empty submission is rejected rather than stored', () async {
    final received = <PlaylistSource>[];
    final sub = server.submissions.listen(received.add);

    final response = await post('pin=${session.pin}&host=&username=&password=');
    expect(response.statusCode, 400);

    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(received, isEmpty);
    await sub.cancel();
  });

  test('the server stops itself once a playlist arrives', () async {
    final sub = server.submissions.listen((_) {});
    await post(
      'pin=${session.pin}&host=http://example.com&username=u&password=p',
    );
    await Future<void>.delayed(const Duration(milliseconds: 1600));
    expect(server.isRunning, isFalse, reason: 'the port must not stay open');
    await sub.cancel();
  });

  test('stop closes the port', () async {
    expect(server.isRunning, isTrue);
    await server.stop();
    expect(server.isRunning, isFalse);
    expect(server.session, isNull);
  });
}
