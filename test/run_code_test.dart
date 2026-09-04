/// PART 2 — run codes: the round trip, the checksum, and the alphabet.
///
/// The three claims being checked here, and what each one costs to break:
///
///   ROUND TRIP     `decode(encode(r)) == r` for every replay, not just for
///                  the ones somebody thought to write down. A single asymmetry
///                  — an off-by-one in the tap deltas, a varint that loses its
///                  top bit — silently turns a stored best run into a different
///                  run, and nothing anywhere would report it.
///   REJECTION      A corrupted code must FAIL, not decode into a different
///                  legal run. Every byte string is a plausible run, so without
///                  the checksum this is not merely unlikely to be caught, it
///                  is guaranteed not to be.
///   ALPHABET       The characters have to survive a chat client, a screenshot
///                  and being read aloud.
///
/// The reference encoder below is a deliberately separate implementation, in
/// the same spirit as `referenceGapCentre` in `test/tuning_constants_test.dart`
/// and `ReferenceProver` in `tool/fairness.dart`. It builds the bit string as
/// text and chunks it five characters at a time — no shift registers, nothing
/// shared with the encoder it is checking except the published alphabet and the
/// layout described in `run_code.dart`'s header.
library;

import 'dart:math';

import 'package:flutter_test/flutter_test.dart';

import 'package:flappymiata/game/course_seed.dart';
import 'package:flappymiata/game/replay.dart';
import 'package:flappymiata/game/run_code.dart';

/// LEB128, written out again from the documented layout.
void refVarint(List<int> out, int value) {
  int v = value;
  while (v >= 128) {
    out.add((v % 128) + 128);
    v = v ~/ 128;
  }
  out.add(v);
}

/// Base32 by way of a literal string of ones and zeros. Slow and obvious.
String refBase32(List<int> bytes) {
  final StringBuffer bits = StringBuffer();
  for (final int b in bytes) {
    bits.write(b.toRadixString(2).padLeft(8, '0'));
  }
  String s = bits.toString();
  while (s.length % 5 != 0) {
    s = '${s}0';
  }
  final StringBuffer out = StringBuffer();
  for (int i = 0; i < s.length; i += 5) {
    out.write(runCodeAlphabet[int.parse(s.substring(i, i + 5), radix: 2)]);
  }
  return out.toString();
}

/// The payload for a replay, without the checksum.
List<int> refBody(Replay r) {
  final List<int> body = <int>[runCodeFormatVersion];
  refVarint(body, r.seed);
  refVarint(body, r.frames);
  refVarint(body, r.tapFrames.length);
  int previous = -1;
  for (final int tap in r.tapFrames) {
    refVarint(body, tap - previous - 1);
    previous = tap;
  }
  return body;
}

/// A whole run code, built independently of `encodeRunCode`.
String refEncode(Replay r) {
  final List<int> body = refBody(r);
  final int c = crc32(body);
  return refBase32(<int>[
    ...body,
    (c >> 24) & 0xFF,
    (c >> 16) & 0xFF,
    (c >> 8) & 0xFF,
    c & 0xFF,
  ]);
}

/// A replay with a plausible shape: a course, a length, and taps at gaps a
/// player might plausibly leave.
Replay randomReplay(Random rng) {
  final int frames = rng.nextInt(4001);
  final int seed = rng.nextInt(4294967296);
  // A quarter of the runs mash the button, so the "gap of exactly one frame"
  // path — which encodes as a zero byte — is exercised heavily rather than by
  // accident.
  final bool mashing = rng.nextInt(4) == 0;
  final List<int> taps = <int>[];
  int f = rng.nextInt(8);
  while (f < frames) {
    taps.add(f);
    f += mashing ? 1 : 1 + rng.nextInt(40);
  }
  return Replay(seed: seed, tapFrames: taps, frames: frames);
}

/// How many generated replays the round-trip property is checked over.
const int roundTripSamples = 2000;

void main() {
  group('the checksum is the published CRC-32', () {
    test("the standard's own check value", () {
      // CRC-32/ISO-HDLC's documented check value: the ASCII string "123456789"
      // hashes to 0xCBF43926. Anchoring to a number from OUTSIDE this repo is
      // what makes this a hash rather than a spelling — a table built with the
      // wrong polynomial would still round-trip against itself perfectly.
      expect(crc32('123456789'.codeUnits), 0xCBF43926);
      // The empty message is 0, and one zero byte is not.
      expect(crc32(<int>[]), 0x00000000);
      expect(crc32(<int>[0]), 0xD202EF8D);
      expect(crc32(<int>[0, 0]), 0x41D912FF);
    });

    test('one flipped bit anywhere changes it', () {
      final List<int> message = <int>[1, 2, 3, 4, 5, 6, 7, 8];
      final int base = crc32(message);
      for (int byte = 0; byte < message.length; byte++) {
        for (int bit = 0; bit < 8; bit++) {
          final List<int> flipped = List<int>.of(message);
          flipped[byte] ^= 1 << bit;
          expect(
            crc32(flipped),
            isNot(base),
            reason: 'byte $byte bit $bit did not move the checksum',
          );
        }
      }
    });
  });

  group('the alphabet is safe for humans and for chat clients', () {
    test('thirty-two distinct characters, none of them confusable', () {
      expect(runCodeAlphabet, hasLength(32));
      expect(runCodeAlphabet.split('').toSet(), hasLength(32));
      // I and L look like 1; O looks like 0; U is excluded so a code can never
      // spell something a student has to explain to a lecturer.
      for (final String banned in <String>['I', 'L', 'O', 'U']) {
        expect(
          runCodeAlphabet.contains(banned),
          isFalse,
          reason: '$banned is in the alphabet',
        );
      }
      // Word characters only: nothing that gets URL-escaped, line-wrapped,
      // auto-linked or eaten by markdown.
      expect(RegExp(r'^[0-9A-Z]+$').hasMatch(runCodeAlphabet), isTrue);
    });

    test('an encoded code uses nothing but the alphabet', () {
      final Random rng = Random(20260904);
      for (int i = 0; i < 200; i++) {
        final String code = encodeRunCode(randomReplay(rng));
        for (int k = 0; k < code.length; k++) {
          expect(
            runCodeAlphabet.contains(code[k]),
            isTrue,
            reason: "'${code[k]}' is not a run-code character",
          );
        }
      }
    });

    test('the confusions the alphabet exists to absorb are absorbed', () {
      // THE SUBJECT HAS TO CONTAIN THE CHARACTERS BEING SMUDGED. The first
      // version of this test used a replay whose code happened to contain no
      // '1' at all, so `replaceAll('1', 'I')` was a no-op and the entire I/L
      // folding path went untested — `tool/mutate.dart` found it by turning the
      // `||` in that fold into `&&` and watching the suite stay green. The two
      // assertions below are what stop this test being satisfied by doing
      // nothing.
      final Replay r =
          Replay(seed: 0, tapFrames: <int>[1, 9, 25], frames: 40);
      final String code = encodeRunCode(r);
      expect(code.contains('1'), isTrue, reason: 'nothing to smudge: $code');
      expect(code.contains('0'), isTrue, reason: 'nothing to smudge: $code');

      // Lowercase, because chat clients capitalise and keyboards autocorrect.
      expect(decodeRunCode(code.toLowerCase()).replay, r);

      // Separators somebody added to make it readable, or a line wrap.
      expect(decodeRunCode(code.split('').join('-')).replay, r);
      expect(decodeRunCode('  $code \n').replay, r);

      // Every separator individually, including the two a copy-paste out of a
      // Windows terminal adds and nobody thinks about.
      expect(decodeRunCode('\t$code\t').replay, r, reason: 'tab');
      expect(decodeRunCode('$code\r\n').replay, r, reason: 'CR LF');
      expect(decodeRunCode('-$code-').replay, r, reason: 'hyphen');

      // The three substitutions a person makes reading a code off a screen,
      // each one on its own so that a fold that stopped working for exactly
      // one of them cannot hide behind the other two.
      expect(decodeRunCode(code.replaceAll('1', 'I')).replay, r, reason: 'I');
      expect(decodeRunCode(code.replaceAll('1', 'i')).replay, r, reason: 'i');
      expect(decodeRunCode(code.replaceAll('1', 'L')).replay, r, reason: 'L');
      expect(decodeRunCode(code.replaceAll('1', 'l')).replay, r, reason: 'l');
      expect(decodeRunCode(code.replaceAll('0', 'O')).replay, r, reason: 'O');
      expect(decodeRunCode(code.replaceAll('0', 'o')).replay, r, reason: 'o');

      // And all of them at once, lowercased, which is what a code retyped off
      // a screenshot actually looks like.
      final String smudged = code
          .replaceAll('1', 'I')
          .replaceAll('0', 'O')
          .toLowerCase();
      expect(decodeRunCode(smudged).replay, r, reason: smudged);
    });
  });

  group('the format limits are the numbers they claim to be', () {
    test('the caps are absolute, not whatever the constants happen to say', () {
      // Stated as the game-facing CONSEQUENCE rather than as
      // `expect(maxReplayFrames, 216000)`. Every other assertion about the caps
      // in this suite is written in terms of the constants themselves, so all
      // of them move together when one is retuned and none of them notices.
      expect(
        maxReplayFrames * replayFrameSeconds,
        3600.0,
        reason: 'the longest recordable run is exactly one hour of play',
      );
      expect(
        maxCourseSeed,
        0xFFFFFFFF,
        reason: 'a seed is 32 bits, because the hash that consumes it is',
      );
      expect(replayFrameSeconds * 60, 1.0, reason: 'sixty frames per second');
    });

    test('a run reports its own length in seconds', () {
      expect(
        Replay(seed: 0, tapFrames: <int>[], frames: 1800).seconds,
        closeTo(30.0, 1e-9),
      );
      expect(Replay(seed: 0, tapFrames: <int>[], frames: 0).seconds, 0.0);
    });
  });

  group('the encoder is the documented layout', () {
    test('it agrees with an independent implementation over 200 replays', () {
      final Random rng = Random(11);
      for (int i = 0; i < 200; i++) {
        final Replay r = randomReplay(rng);
        expect(encodeRunCode(r), refEncode(r), reason: '$r');
      }
    });

    test('a golden code, so the format cannot drift silently', () {
      // Pinned as a LITERAL STRING, not as "whatever the reference encoder
      // says". Every other assertion in this file compares the encoder to the
      // reference or to itself, and all of those move together when a layout
      // constant is retuned — including the format version, which appears on
      // both sides of every one of them. This is the one assertion that is
      // anchored outside the code.
      //
      // If this string has to change, every code anybody has already pasted
      // anywhere stops decoding. That is a decision, not a refactor.
      final Replay r = Replay(seed: 0, tapFrames: <int>[0, 5, 6], frames: 12);
      expect(encodeRunCode(r), '0400R0R00G08GCJK44');
      expect(encodeRunCode(r), refEncode(r));
      expect(decodeRunCode(encodeRunCode(r)).replay, r);
      // Four header bytes plus three tap bytes plus four checksum bytes is
      // eleven bytes, which is 18 characters at five bits each.
      expect(encodeRunCode(r), hasLength(18));
      // And the version byte really is the first thing in it.
      expect(runCodeFormatVersion, 1);
    });
  });

  group('the round trip is exact', () {
    test('$roundTripSamples generated replays decode back to themselves', () {
      final Random rng = Random(4330);
      int totalTaps = 0;
      int longest = 0;
      for (int i = 0; i < roundTripSamples; i++) {
        final Replay r = randomReplay(rng);
        final String code = encodeRunCode(r);
        final RunCodeDecoding back = decodeRunCode(code);
        expect(back.ok, isTrue, reason: '$r -> $code -> ${back.detail}');
        expect(back.replay, r, reason: code);
        // Field by field as well as by `==`, so a broken `==` cannot make this
        // whole test vacuous.
        expect(back.replay!.seed, r.seed);
        expect(back.replay!.frames, r.frames);
        expect(back.replay!.tapFrames, r.tapFrames);
        totalTaps += r.tapFrames.length;
        if (code.length > longest) longest = code.length;
      }
      // Non-vacuous: the samples really did contain long runs and lots of taps.
      expect(totalTaps, greaterThan(100000));
      expect(longest, greaterThan(500));
    });

    test('the edges of the format round-trip too', () {
      final List<Replay> edges = <Replay>[
        // Nothing at all.
        Replay(seed: 0, tapFrames: <int>[], frames: 0),
        // The widest seed and the longest run the format allows.
        Replay(seed: maxCourseSeed, tapFrames: <int>[], frames: maxReplayFrames),
        // A tap on the very first and very last frame.
        Replay(seed: 1, tapFrames: <int>[0, 999], frames: 1000),
        // Taps on consecutive frames, which is the gap-of-zero encoding.
        Replay(seed: 2, tapFrames: <int>[0, 1, 2, 3, 4], frames: 5),
        // A single tap a long way in, so the first delta needs three bytes.
        Replay(seed: 3, tapFrames: <int>[200000], frames: maxReplayFrames),
      ];
      for (final Replay r in edges) {
        expect(decodeRunCode(encodeRunCode(r)).replay, r, reason: '$r');
      }
    });
  });

  group('corruption is rejected, not silently decoded', () {
    test('every single-character substitution in three real codes is caught',
        () {
      // The strong form of the claim. Not "corruption is usually caught" — for
      // a one-character change, which is a burst of at most five bits, CRC-32
      // catches ALL of them, and this enumerates every one: every position,
      // every one of the other 31 characters.
      final List<Replay> subjects = <Replay>[
        Replay(seed: 0, tapFrames: <int>[0, 5, 6], frames: 12),
        Replay(seed: 4242, tapFrames: <int>[3, 40, 41, 90], frames: 400),
        randomReplay(Random(7)),
      ];
      int checked = 0;
      final Map<RunCodeError, int> kinds = <RunCodeError, int>{};
      for (final Replay r in subjects) {
        final String code = encodeRunCode(r);
        for (int i = 0; i < code.length; i++) {
          for (int v = 0; v < runCodeAlphabet.length; v++) {
            final String ch = runCodeAlphabet[v];
            if (ch == code[i]) continue;
            final String bad =
                code.substring(0, i) + ch + code.substring(i + 1);
            final RunCodeDecoding d = decodeRunCode(bad);
            expect(
              d.ok,
              isFalse,
              reason: 'flipping position $i of\n  $code\nto $ch decoded to '
                  '${d.replay}',
            );
            kinds[d.error!] = (kinds[d.error] ?? 0) + 1;
            checked++;
          }
        }
      }
      expect(checked, greaterThan(5000));
      // WHAT A FLIPPED CHARACTER ACTUALLY DOES: nearly all of them are caught
      // by the checksum. A few land in the final character, where they change
      // padding bits the encoder never sets, and are caught one layer earlier
      // with a more specific complaint. Both are refusals; neither is a
      // different run.
      expect(kinds[RunCodeError.checksumMismatch], greaterThan(5000));
      expect(
        kinds.keys.toSet().difference(<RunCodeError>{
          RunCodeError.checksumMismatch,
          RunCodeError.paddingNotZero,
          RunCodeError.malformedRun,
          RunCodeError.truncated,
          RunCodeError.trailingBytes,
        }),
        isEmpty,
        reason: 'a substitution produced an unexpected failure kind: '
            '${kinds.keys}',
      );
    });

    test('dropping, adding or reordering characters is caught', () {
      final Replay r = Replay(
        seed: 9,
        tapFrames: <int>[2, 17, 18, 60],
        frames: 300,
      );
      final String code = encodeRunCode(r);

      // A lost character.
      expect(decodeRunCode(code.substring(1)).ok, isFalse);
      expect(decodeRunCode(code.substring(0, code.length - 1)).ok, isFalse);
      // An extra one.
      expect(decodeRunCode('${code}A').ok, isFalse);
      expect(decodeRunCode('A$code').ok, isFalse);
      // Two characters swapped. (Skipped when the two happen to be equal, in
      // which case nothing was swapped.)
      int swapsChecked = 0;
      for (int i = 0; i + 1 < code.length; i++) {
        if (code[i] == code[i + 1]) continue;
        final String swapped = code.substring(0, i) +
            code[i + 1] +
            code[i] +
            code.substring(i + 2);
        expect(decodeRunCode(swapped).ok, isFalse, reason: 'swap at $i');
        swapsChecked++;
      }
      expect(swapsChecked, greaterThan(10));
    });

    /// A code built from arbitrary bytes with a correct checksum, so a decode
    /// failure below is always about the thing being tested and never about the
    /// checksum.
    String codeFor(List<int> body) {
      final int c = crc32(body);
      return refBase32(<int>[
        ...body,
        (c >> 24) & 0xFF,
        (c >> 16) & 0xFF,
        (c >> 8) & 0xFF,
        c & 0xFF,
      ]);
    }

    test('each way a code can be malformed is reported as itself', () {
      final Replay r = Replay(seed: 5, tapFrames: <int>[1], frames: 9);
      final String code = encodeRunCode(r);

      expect(decodeRunCode('').error, RunCodeError.empty);
      expect(decodeRunCode('  --  ').error, RunCodeError.empty);
      expect(decodeRunCode('$code!').error, RunCodeError.illegalCharacter);
      // The position in the complaint is 1-based and points at the character
      // that is actually wrong — pinned because an off-by-one in an error
      // message is invisible to every other assertion in this file.
      expect(decodeRunCode('AB!DEFGH').detail, contains('position 3'));
      // Four characters is two bytes: a canonical length with zero padding, so
      // it gets past both base32 checks and is refused for what it really is.
      expect(decodeRunCode('0000').error, RunCodeError.tooShort);
      // Five bytes is the shortest thing that is NOT too short, so it gets all
      // the way to the checksum. This is the other side of that boundary.
      expect(decodeRunCode('ZZZZZZZZ').error, RunCodeError.checksumMismatch);
      // Four characters that are NOT all zeros fail one layer earlier, because
      // the leftover bits of the last character are bits this encoder never
      // sets.
      expect(decodeRunCode('AAAA').error, RunCodeError.paddingNotZero);
      // Six characters is not a length this encoder can produce: three bytes
      // take five characters and four take seven, so a six-character code has
      // had one added or lost.
      expect(decodeRunCode('000000').error, RunCodeError.nonCanonicalLength);
      // The checksum complaint quotes both numbers, in full 32-bit hex, so a
      // report of one can be compared against a report of the other.
      expect(
        decodeRunCode('ZZZZZZZZ').detail,
        matches(RegExp(r'0x[0-9A-F]{8}.*0x[0-9A-F]{8}')),
      );
      // Pinned exactly on a pair of checksums that BOTH have leading zeros.
      // Without a case that actually needs padding, the width in `_hex8` is
      // untested: every checksum that happens to use all eight digits reads the
      // same however the number is padded, and "0xF6A70" versus "0x000F6A70"
      // is precisely the difference that makes two reported checksums hard to
      // compare by eye.
      expect(
        decodeRunCode(refBase32(<int>[38, 0, 0, 0, 0])).detail,
        'code carries 0x00000000, contents hash to 0x000F6A70',
      );

      // A code whose contents are a valid payload for a format this build does
      // not read. Built from bytes so the version byte can be set to something
      // the encoder would never write, with a checksum that is nonetheless
      // correct — otherwise the checksum, not the version, is what fails.
      final List<int> body = refBody(r);
      body[0] = 99;
      final int c = crc32(body);
      final String future = refBase32(<int>[
        ...body,
        (c >> 24) & 0xFF,
        (c >> 16) & 0xFF,
        (c >> 8) & 0xFF,
        c & 0xFF,
      ]);
      expect(decodeRunCode(future).error, RunCodeError.unsupportedVersion);

      // A payload that decodes cleanly and is not a run: a tap past the end.
      final List<int> impossible = <int>[runCodeFormatVersion];
      refVarint(impossible, 0); // seed
      refVarint(impossible, 5); // frames
      refVarint(impossible, 1); // one tap
      refVarint(impossible, 900); // ...on frame 900 of a five-frame run
      final int c2 = crc32(impossible);
      final String bogus = refBase32(<int>[
        ...impossible,
        (c2 >> 24) & 0xFF,
        (c2 >> 16) & 0xFF,
        (c2 >> 8) & 0xFF,
        c2 & 0xFF,
      ]);
      expect(decodeRunCode(bogus).error, RunCodeError.malformedRun);

      // A payload with a byte left over after the last tap.
      final List<int> extra = <int>[...refBody(r), 0];
      final int c3 = crc32(extra);
      final String trailing = refBase32(<int>[
        ...extra,
        (c3 >> 24) & 0xFF,
        (c3 >> 16) & 0xFF,
        (c3 >> 8) & 0xFF,
        c3 & 0xFF,
      ]);
      expect(decodeRunCode(trailing).error, RunCodeError.trailingBytes);
      // How MANY bytes were left over, which is the only place the cursor's
      // remaining-bytes arithmetic is visible from outside.
      //
      // EQUALITY, NOT `contains`, AND THE REASON IS EMBARRASSING: this was
      // written as `contains('1 byte(s)')` and `tool/mutate.dart` found that a
      // mutant reporting "11 byte(s)" passed it, because "1 byte(s)" is a
      // substring of "11 byte(s)". A `contains` assertion about a number is
      // satisfied by every number that ends with it.
      expect(
        decodeRunCode(trailing).detail,
        '1 byte(s) after the last tap',
      );
      final List<int> extra3 = <int>[...refBody(r), 0, 0, 0];
      final int c3b = crc32(extra3);
      expect(
        decodeRunCode(refBase32(<int>[
          ...extra3,
          (c3b >> 24) & 0xFF,
          (c3b >> 16) & 0xFF,
          (c3b >> 8) & 0xFF,
          c3b & 0xFF,
        ])).detail,
        '3 byte(s) after the last tap',
      );

      // A header that runs off the end of its own payload.
      expect(
        decodeRunCode(codeFor(<int>[runCodeFormatVersion, 0x80])).error,
        RunCodeError.truncated,
      );

      // A tap list shorter than its own count, and the complaint says WHICH tap
      // ran out — a 1-based position, pinned because an off-by-one in an error
      // message is invisible to every other assertion in this file.
      final List<int> shortList = <int>[runCodeFormatVersion];
      refVarint(shortList, 0); // seed
      refVarint(shortList, 40); // frames
      refVarint(shortList, 3); // three taps promised
      refVarint(shortList, 0); // ...one delivered
      final RunCodeDecoding short = decodeRunCode(codeFor(shortList));
      expect(short.error, RunCodeError.truncated);
      expect(short.detail, contains('tap 2 of 3'));
    });

    test('the format\'s own limits are enforced at their exact edges', () {
      // Each of these is a hand-built payload with a correct checksum, so the
      // only thing that can reject it is the limit being tested. Each is paired
      // with the neighbouring value that must be ACCEPTED, which is what makes
      // these tests of a boundary rather than of a ban.

      // A varint may be five bytes and no more. Five bytes is exactly what a
      // 32-bit seed needs, so the cap cannot be tightened; six bytes is not a
      // number, it is a corrupt run of continuation bits.
      final List<int> sixByteVarint = <int>[
        runCodeFormatVersion,
        0x80, 0x80, 0x80, 0x80, 0x80, 0x01, // six bytes, still going
        0, 0,
      ];
      expect(decodeRunCode(codeFor(sixByteVarint)).error,
          RunCodeError.truncated);
      expect(
        decodeRunCode(
          encodeRunCode(
            Replay(seed: maxCourseSeed, tapFrames: <int>[], frames: 1),
          ),
        ).ok,
        isTrue,
        reason: 'the widest legal seed is a five-byte varint and must pass',
      );

      // The frame cap.
      List<int> withFrames(int frames) {
        final List<int> body = <int>[runCodeFormatVersion];
        refVarint(body, 0);
        refVarint(body, frames);
        refVarint(body, 0);
        return body;
      }
      expect(decodeRunCode(codeFor(withFrames(maxReplayFrames))).ok, isTrue);
      expect(
        decodeRunCode(codeFor(withFrames(maxReplayFrames + 1))).error,
        RunCodeError.malformedRun,
      );

      // One tap per frame, and not one more. A five-frame run with five taps is
      // legal — the player mashed the button — and six is impossible.
      List<int> withTapCount(int frames, int taps) {
        final List<int> body = <int>[runCodeFormatVersion];
        refVarint(body, 0);
        refVarint(body, frames);
        refVarint(body, taps);
        for (int i = 0; i < taps; i++) {
          refVarint(body, 0);
        }
        return body;
      }
      expect(decodeRunCode(codeFor(withTapCount(5, 5))).ok, isTrue);
      expect(
        decodeRunCode(codeFor(withTapCount(5, 6))).error,
        RunCodeError.malformedRun,
      );
    });

    test('a decoding carries either a replay or an error, never both', () {
      final Replay r = Replay(seed: 0, tapFrames: <int>[0], frames: 2);
      final RunCodeDecoding good = decodeRunCode(encodeRunCode(r));
      expect(good.ok, isTrue);
      expect(good.error, isNull);
      expect(good.detail, isEmpty);

      final RunCodeDecoding bad = decodeRunCode('ZZZZZZZZ');
      expect(bad.ok, isFalse);
      expect(bad.replay, isNull);
      expect(bad.error, isNotNull);
      expect(bad.detail, isNotEmpty);
      expect(bad.toString(), contains(bad.error!.name));
    });
  });

  group('how long a code actually is', () {
    // These numbers are the answer to "can a person paste this into a chat
    // message". They are asserted rather than only reported, because a change
    // to the encoding that quietly doubled them would otherwise go unnoticed —
    // the round trip would still pass.
    //
    // Measured on the reference bot's runs (`tool/replay_report.dart` prints
    // the table):
    //   30 seconds, 25-142 taps   58 to 244 characters   (151 on seed 0)
    //   the full 60s run, 309 taps                       517 characters
    //
    // The floor is one byte per tap: header (4) + one varint per tap + CRC (4),
    // at eight bits per five characters.
    test('a thirty-second run fits in a chat message', () {
      final Replay thirty = Replay(
        seed: 0,
        // 85 taps in 1033 frames, which is what the reference bot produces on
        // the shipped course.
        tapFrames: <int>[for (int i = 0; i < 85; i++) i * 12],
        frames: 1800,
      );
      final String code = encodeRunCode(thirty);
      expect(code.length, greaterThan(120));
      expect(code.length, lessThan(200));
    });

    test('a long run is still one paste, and the growth is linear in taps', () {
      final Replay long = Replay(
        seed: 0xFFFFFFFF,
        tapFrames: <int>[for (int i = 0; i < 309; i++) i * 11],
        frames: 3600,
      );
      final String code = encodeRunCode(long);
      expect(code.length, greaterThan(480));
      expect(code.length, lessThan(560));

      // Twice the taps is about twice the code, not four times: the deltas keep
      // every tap at one byte however late in the run it happens.
      final Replay half = Replay(
        seed: 0xFFFFFFFF,
        tapFrames: <int>[for (int i = 0; i < 154; i++) i * 11],
        frames: 3600,
      );
      final double ratio = code.length / encodeRunCode(half).length;
      expect(ratio, closeTo(2.0, 0.15));
    });
  });
}
