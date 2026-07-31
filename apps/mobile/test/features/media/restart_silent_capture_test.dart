import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:halo_mobile/features/media/live_call_audio.dart';

/// The dead first capture of a launch delivers only zeros; the guard must
/// reopen it. A quiet room still has a noise floor and must NOT trigger it.
void main() {
  Uint8List silence() => Uint8List(3200);

  Uint8List voice() {
    final bytes = Uint8List(3200);
    for (var i = 0; i < bytes.length; i += 2) {
      bytes[i] = 200; // s16le low byte: clearly above the dither allowance.
    }
    return bytes;
  }

  test('an all-zero head restarts the capture and audio then flows', () async {
    var opens = 0;
    var closes = 0;
    final received = <int>[];

    final stream = restartSilentCapture(
      silentLeadLimit: 3,
      open: () async {
        opens += 1;
        if (opens == 1) {
          // The broken first bind: nothing but digital silence.
          return Stream<Uint8List>.fromIterable(
            List.generate(10, (_) => silence()),
          );
        }
        return Stream<Uint8List>.fromIterable([voice(), voice()]);
      },
      close: () async => closes += 1,
    );

    await for (final chunk in stream) {
      received.add(chunk[0]);
    }

    expect(opens, 2, reason: 'the silent capture must be reopened');
    expect(closes, 1, reason: 'the dead recorder must be stopped first');
    expect(received, contains(200), reason: 'audio flows after the restart');
  });

  test('a live microphone with a noise floor is left alone', () async {
    var opens = 0;
    final quiet = Uint8List(3200)..[0] = 20; // tiny but real signal

    final stream = restartSilentCapture(
      silentLeadLimit: 3,
      open: () async {
        opens += 1;
        return Stream<Uint8List>.fromIterable([quiet, quiet, quiet, quiet]);
      },
      close: () async {},
    );

    final chunks = await stream.take(4).toList();

    expect(opens, 1);
    expect(chunks, hasLength(4));
  });

  test('restarts stop after the cap so a truly dead input cannot loop', () async {
    var opens = 0;
    final stream = restartSilentCapture(
      silentLeadLimit: 2,
      maxRestarts: 2,
      open: () async {
        opens += 1;
        return Stream<Uint8List>.fromIterable(
          List.generate(6, (_) => silence()),
        );
      },
      close: () async {},
    );

    // Silence keeps flowing to the uplink even while restarts happen.
    final chunks = await stream.take(8).toList();

    expect(opens, 3, reason: 'first open plus exactly two restarts');
    expect(chunks, hasLength(8));
  });
}
