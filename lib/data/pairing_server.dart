import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'models.dart';
import 'xtream_link.dart';

/// Where to point a phone, and the code that proves the person can see the
/// screen showing it.
class PairingSession {
  const PairingSession({
    required this.address,
    required this.port,
    required this.pin,
  });

  final String address;
  final int port;
  final String pin;

  String get url => 'http://$address:$port';

  /// Encoded into the QR code, so scanning skips typing the code as well.
  String get urlWithPin => '$url/?k=$pin';
}

class PairingException implements Exception {
  PairingException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Serves a one-page form on the local network so a playlist can be typed on
/// a phone instead of with a TV remote.
///
/// It is deliberately small and short-lived: bound to the LAN, gated by a PIN
/// shown on the screen, and stopped as soon as a playlist arrives or after
/// [lifetime]. It never reaches the internet and stores nothing itself.
class PairingServer {
  PairingServer({this.lifetime = const Duration(minutes: 5)});

  /// How long the form stays reachable if nothing is submitted.
  final Duration lifetime;

  static const _preferredPort = 8099;

  HttpServer? _server;
  Timer? _expiry;
  PairingSession? _session;

  final _submissions = StreamController<PlaylistSource>.broadcast();

  /// Playlists submitted from the phone.
  Stream<PlaylistSource> get submissions => _submissions.stream;

  bool get isRunning => _server != null;
  PairingSession? get session => _session;

  Future<PairingSession> start() async {
    if (_session case final existing? when _server != null) return existing;

    final address = await _lanAddress();
    if (address == null) {
      throw PairingException(
        'This device is not on a local network. Connect it to the same '
        'Wi-Fi as your phone and try again.',
      );
    }

    HttpServer server;
    try {
      server = await HttpServer.bind(InternetAddress.anyIPv4, _preferredPort);
    } on SocketException {
      // Something else holds the friendly port; any free one will do.
      server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
    }

    final pin = _pin();
    _server = server;
    _session = PairingSession(
      address: address,
      port: server.port,
      pin: pin,
    );

    server.listen(
      (request) => _handle(request, pin),
      onError: (_) {},
      cancelOnError: false,
    );

    _expiry = Timer(lifetime, stop);
    return _session!;
  }

  Future<void> stop() async {
    _expiry?.cancel();
    _expiry = null;
    final server = _server;
    _server = null;
    _session = null;
    await server?.close(force: true);
  }

  Future<void> dispose() async {
    await stop();
    await _submissions.close();
  }

  // --- Request handling ----------------------------------------------------

  Future<void> _handle(HttpRequest request, String pin) async {
    try {
      if (request.method == 'GET') {
        final supplied = request.uri.queryParameters['k'] ?? '';
        await _send(request, _formPage(prefilledPin: supplied == pin ? pin : ''));
        return;
      }

      if (request.method == 'POST' && request.uri.path == '/add') {
        final body = await utf8.decoder.bind(request).join();
        final form = Uri.splitQueryString(body);

        if ((form['pin'] ?? '').trim() != pin) {
          await _send(
            request,
            _formPage(
              prefilledPin: '',
              error: 'That code does not match the one on the screen.',
            ),
            status: HttpStatus.forbidden,
          );
          return;
        }

        final source = _toSource(form);
        if (source == null) {
          await _send(
            request,
            _formPage(
              prefilledPin: pin,
              error: 'Fill in the server, username and password — or paste '
                  'your provider link into the first box.',
            ),
            status: HttpStatus.badRequest,
          );
          return;
        }

        await _send(request, _donePage(source.name));
        _submissions.add(source);
        // The form has done its job; close rather than leave a port open.
        unawaited(Future<void>.delayed(const Duration(seconds: 1), stop));
        return;
      }

      await _send(request, _formPage(prefilledPin: ''));
    } catch (_) {
      try {
        request.response.statusCode = HttpStatus.internalServerError;
        await request.response.close();
      } catch (_) {
        // The phone navigated away mid-request.
      }
    }
  }

  static Future<void> _send(
    HttpRequest request,
    String html, {
    int status = HttpStatus.ok,
  }) async {
    request.response
      ..statusCode = status
      ..headers.contentType = ContentType.html
      ..headers.set('Cache-Control', 'no-store');
    request.response.write(html);
    await request.response.close();
  }

  /// Builds a source from the form, accepting either a pasted provider link
  /// or the three fields typed out.
  static PlaylistSource? _toSource(Map<String, String> form) {
    final id = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
    final name = (form['name'] ?? '').trim();

    final link = (form['link'] ?? '').trim();
    if (link.isNotEmpty) {
      // Credentials in the link mean Xtream, whatever the rest of it says.
      // A get.php export URL carries `type=m3u_plus` but is still an Xtream
      // account - and the API side of a panel often works when the export is
      // blocked, so reading it that way is the more useful of the two.
      final parsed = XtreamLink.parse(link);
      if (parsed != null && parsed.isComplete) {
        return PlaylistSource(
          id: id,
          name: name.isEmpty ? parsed.origin : name,
          kind: SourceKind.xtream,
          host: parsed.origin,
          username: parsed.username,
          password: parsed.password,
        );
      }
      // No credentials to find: treat it as a plain playlist URL.
      if (link.toLowerCase().startsWith('http')) {
        return PlaylistSource(
          id: id,
          name: name.isEmpty ? 'Playlist' : name,
          kind: SourceKind.m3u,
          url: link,
        );
      }
      return null;
    }

    final host = (form['host'] ?? '').trim();
    final username = (form['username'] ?? '').trim();
    final password = (form['password'] ?? '').trim();
    if (host.isEmpty || username.isEmpty || password.isEmpty) return null;

    return PlaylistSource(
      id: id,
      name: name.isEmpty ? host : name,
      kind: SourceKind.xtream,
      host: host,
      username: username,
      password: password,
    );
  }

  // --- Network -------------------------------------------------------------

  /// The device's address on the local network, preferring the usual private
  /// ranges over anything else the interfaces report.
  static Future<String?> _lanAddress() async {
    final List<NetworkInterface> interfaces;
    try {
      interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
        includeLinkLocal: false,
      );
    } on OSError {
      return null;
    }

    String? fallback;
    for (final interface in interfaces) {
      for (final address in interface.addresses) {
        final ip = address.address;
        if (ip.startsWith('127.') || ip.startsWith('169.254.')) continue;
        if (_isPrivate(ip)) return ip;
        fallback ??= ip;
      }
    }
    return fallback;
  }

  static bool _isPrivate(String ip) {
    if (ip.startsWith('192.168.') || ip.startsWith('10.')) return true;
    if (!ip.startsWith('172.')) return false;
    final second = int.tryParse(ip.split('.').elementAt(1));
    return second != null && second >= 16 && second <= 31;
  }

  static String _pin() {
    final random = Random.secure();
    return List.generate(4, (_) => random.nextInt(10)).join();
  }

  // --- Pages ---------------------------------------------------------------

  static String _formPage({required String prefilledPin, String? error}) {
    final errorBlock = error == null
        ? ''
        : '<p class="error">${_escape(error)}</p>';
    return '''
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<title>My TV — add a playlist</title>
<style>
  :root { color-scheme: dark; }
  * { box-sizing: border-box; }
  body {
    margin: 0; padding: 24px 16px 48px;
    background: #0A0D12; color: #fff;
    font: 16px/1.5 -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
  }
  .wrap { max-width: 460px; margin: 0 auto; }
  h1 { font-size: 21px; margin: 0 0 4px; }
  .sub { color: #8A97A8; font-size: 14px; margin: 0 0 24px; }
  label { display: block; font-size: 13px; color: #B8C2CF; margin: 18px 0 6px; }
  input {
    width: 100%; padding: 14px; font-size: 16px;
    background: #1B222D; color: #fff;
    border: 1px solid #2A3341; border-radius: 12px;
  }
  input:focus { outline: none; border-color: #22D3A7; }
  .hint { font-size: 12.5px; color: #6E7B8C; margin-top: 6px; }
  .or { text-align: center; color: #6E7B8C; font-size: 13px; margin: 26px 0 0; }
  button {
    width: 100%; margin-top: 28px; padding: 16px;
    font-size: 16px; font-weight: 600;
    background: #22D3A7; color: #06231E;
    border: 0; border-radius: 12px;
  }
  .error {
    background: rgba(255,59,48,.12); border: 1px solid rgba(255,59,48,.45);
    color: #FF8077; padding: 12px 14px; border-radius: 10px; font-size: 14px;
  }
  fieldset { border: 0; padding: 0; margin: 0; }
</style>
</head>
<body>
<div class="wrap">
  <h1>Add a playlist</h1>
  <p class="sub">Typed here, sent straight to the screen.</p>
  $errorBlock
  <form method="post" action="/add">
    <label for="link">Provider link</label>
    <input id="link" name="link" type="url" inputmode="url"
           autocapitalize="off" autocorrect="off" spellcheck="false"
           placeholder="http://example.com:8080/get.php?username=...">
    <p class="hint">Paste the whole link and the rest is filled in for you.
      An .m3u link works here too.</p>

    <p class="or">— or fill these in —</p>

    <fieldset>
      <label for="host">Server</label>
      <input id="host" name="host" type="url" inputmode="url"
             autocapitalize="off" autocorrect="off" spellcheck="false"
             placeholder="http://example.com:8080">

      <label for="username">Username</label>
      <input id="username" name="username" autocapitalize="off"
             autocorrect="off" spellcheck="false">

      <label for="password">Password</label>
      <input id="password" name="password" autocapitalize="off"
             autocorrect="off" spellcheck="false">
    </fieldset>

    <label for="name">Name (optional)</label>
    <input id="name" name="name" placeholder="My provider">

    <label for="pin">Code shown on the screen</label>
    <input id="pin" name="pin" inputmode="numeric" pattern="[0-9]*"
           maxlength="4" required value="${_escape(prefilledPin)}">

    <button type="submit">Send to the screen</button>
  </form>
</div>
</body>
</html>
''';
  }

  static String _donePage(String name) => '''
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Sent</title>
<style>
  :root { color-scheme: dark; }
  body {
    margin: 0; min-height: 100vh; display: flex;
    align-items: center; justify-content: center;
    background: #0A0D12; color: #fff; text-align: center;
    font: 16px/1.6 -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
  }
  .tick { font-size: 54px; color: #22D3A7; }
  h1 { font-size: 20px; margin: 14px 0 6px; }
  p { color: #8A97A8; margin: 0; padding: 0 24px; }
</style>
</head>
<body>
  <div>
    <div class="tick">&#10003;</div>
    <h1>Sent to the screen</h1>
    <p>${_escape(name)} is loading on your TV. You can close this page.</p>
  </div>
</body>
</html>
''';

  static String _escape(String value) => value
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;');
}
