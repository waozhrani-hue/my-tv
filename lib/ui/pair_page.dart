import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../data/models.dart';
import '../data/pairing_server.dart';
import '../state/app_state.dart';
import 'widgets/common.dart';

/// Lets a playlist be typed on a phone instead of with a TV remote.
///
/// The screen runs a one-page form on the local network and shows where to
/// find it, as a QR code and as plain text. Scanning the code carries the PIN
/// with it; typing the address in by hand means entering the PIN as well.
class PairPage extends StatefulWidget {
  const PairPage({super.key});

  @override
  State<PairPage> createState() => _PairPageState();
}

class _PairPageState extends State<PairPage> {
  final _server = PairingServer();
  StreamSubscription<PlaylistSource>? _subscription;

  PairingSession? _session;
  String? _error;
  var _adding = false;

  @override
  void initState() {
    super.initState();
    _subscription = _server.submissions.listen(_accept);
    _start();
  }

  @override
  void dispose() {
    _subscription?.cancel();
    _server.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    try {
      final session = await _server.start();
      if (mounted) setState(() => _session = session);
    } on PairingException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not start — $e');
    }
  }

  Future<void> _accept(PlaylistSource source) async {
    if (!mounted || _adding) return;
    setState(() => _adding = true);
    await context.read<AppState>().addSource(source);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Add from your phone')),
      body: SafeArea(child: Center(child: _body())),
    );
  }

  Widget _body() {
    if (_error != null) {
      return StatusView(
        icon: Icons.wifi_off_rounded,
        title: 'Cannot reach your network',
        message: _error,
        isError: true,
        action: FilledButton(
          onPressed: () {
            setState(() => _error = null);
            _start();
          },
          child: const Text('Try again'),
        ),
      );
    }

    final session = _session;
    if (session == null) {
      return const LoadingView(label: 'Starting…');
    }
    if (_adding) {
      return const LoadingView(label: 'Received — adding your playlist…');
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final side = constraints.maxWidth >= 620;
            final qr = _QrPanel(data: session.urlWithPin);
            final details = _Details(session: session);
            return side
                ? Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      qr,
                      const SizedBox(width: 32),
                      Expanded(child: details),
                    ],
                  )
                : Column(
                    children: [qr, const SizedBox(height: 28), details],
                  );
          },
        ),
      ),
    );
  }
}

class _QrPanel extends StatelessWidget {
  const _QrPanel({required this.data});

  final String data;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
      ),
      child: QrImageView(
        data: data,
        size: 208,
        version: QrVersions.auto,
        backgroundColor: Colors.white,
        // The TV may be across the room; the highest correction level keeps
        // it readable at an angle or slightly out of focus.
        errorCorrectionLevel: QrErrorCorrectLevel.H,
      ),
    );
  }
}

class _Details extends StatelessWidget {
  const _Details({required this.session});

  final PairingSession session;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        const Text(
          'Point your phone camera at the code',
          style: TextStyle(fontSize: 19, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 8),
        Text(
          'It opens a page where you can type with a proper keyboard. '
          'Your phone must be on the same Wi-Fi as this device.',
          style: TextStyle(
            fontSize: 13.5,
            height: 1.5,
            color: Colors.white.withValues(alpha: 0.6),
          ),
        ),
        const SizedBox(height: 24),
        Text(
          'Or open this address',
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w700,
            letterSpacing: 1,
            color: scheme.primary,
          ),
        ),
        const SizedBox(height: 8),
        SelectableText(
          session.url,
          style: const TextStyle(
            fontSize: 22,
            fontWeight: FontWeight.w600,
            fontFeatures: [FontFeature.tabularFigures()],
          ),
        ),
        const SizedBox(height: 18),
        Row(
          children: [
            Text(
              'Code',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                letterSpacing: 1,
                color: scheme.primary,
              ),
            ),
            const SizedBox(width: 14),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: scheme.outline),
              ),
              child: Text(
                session.pin,
                style: const TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 6,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 22),
        Row(
          children: [
            const SizedBox(
              width: 15,
              height: 15,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 10),
            Text(
              'Waiting for your phone…',
              style: TextStyle(
                fontSize: 13,
                color: Colors.white.withValues(alpha: 0.6),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Text(
          'This page closes itself after five minutes, and the moment your '
          'playlist arrives.',
          style: TextStyle(
            fontSize: 12,
            height: 1.45,
            color: Colors.white.withValues(alpha: 0.4),
          ),
        ),
      ],
    );
  }
}
