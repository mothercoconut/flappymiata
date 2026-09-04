/// Run codes: a whole recorded run as a short ASCII string somebody can paste
/// into a chat message, and the decoder that refuses to be lied to.
///
/// ============================================================================
/// WHY A CHECKSUM BELONGS IN THE CODE
/// ============================================================================
///
/// The bytes underneath a run code are a seed, a frame count and a list of tap
/// frames. Almost every possible byte string is a *valid-looking* one of those.
/// So without a checksum, a code with one character mistyped does not fail — it
/// decodes into a different, perfectly legal run, which replays to a different
/// score. The verifier then reports "your score does not match", the player
/// swears they scored 47, and both of them are right: the code that arrived was
/// not the code that was sent.
///
/// A checksum is what separates those two situations. `CHECKSUM_MISMATCH` means
/// "this is not a code" and `SCORE_MISMATCH` means "this is a code, and it does
/// not do what you claim". A system that cannot tell corruption from dishonesty
/// has to treat honest people as liars, and it eventually will.
///
/// CRC-32 rather than something shorter: it costs 7 characters of the code and
/// catches every burst error up to 32 bits, all odd numbers of flipped bits,
/// and all but one in four billion of everything else. Seven characters is a
/// cheap price for never having to argue about whether a code was typed
/// correctly. It is NOT a signature and is not trying to be — see
/// `verified_score.dart` for what actually stops a cheat, which is re-execution
/// and not cryptography.
///
/// ============================================================================
/// THE ALPHABET, AND WHY THESE THIRTY-TWO CHARACTERS
/// ============================================================================
///
/// Crockford's Base32: the digits and the uppercase letters, minus `I`, `L`,
/// `O` and `U`.
///
///   - `I`, `L` and `1` are one smudge apart in most sans-serif fonts, and `O`
///     and `0` are worse. They are excluded from the OUTPUT, and accepted on
///     input as the digit they are mistaken for — so a code read aloud over a
///     phone, or retyped off a screenshot, survives the obvious substitutions
///     instead of failing a checksum for a reason nobody can see.
///   - `U` is excluded so that no run code ever spells an obscenity by chance.
///     A game handed to a class of students will generate thousands of these.
///   - Uppercase only, and case-insensitive on input, because chat clients
///     capitalise the first letter of a "sentence" and phone keyboards
///     autocorrect. Nothing about the code should depend on shift keys.
///   - No `+`, `/`, `=` or other punctuation, which is what rules out Base64:
///     those characters get URL-escaped, line-wrapped, turned into links or
///     eaten by markdown. Every character here is a bare word character that
///     survives being pasted anywhere.
///
/// ============================================================================
/// THE LAYOUT
/// ============================================================================
///
///     byte  0      format version
///     ...          varint: course seed
///     ...          varint: frame count
///     ...          varint: number of taps
///     ...          varint x N: the first tap frame, then each subsequent
///                  tap as (gap since the previous one) - 1
///     last 4       CRC-32 of everything above, big-endian
///
/// Then the whole thing is Base32-encoded, five bits per character.
///
/// DELTAS, NOT ABSOLUTE FRAME NUMBERS: the taps are strictly increasing, so
/// storing differences keeps every number small and every varint one byte. A
/// tap frame late in a long run is a three-byte varint on its own; the gap
/// since the previous tap is almost always under 128 and costs one. The `- 1`
/// is free and is there because a gap of zero is impossible — two taps cannot
/// share a frame — so the smallest real gap should encode as the smallest
/// number.
///
/// Same directory rule as the rest of `lib/game/`: no Flame, no Flutter, no
/// clock, no randomness.
library;

import 'replay.dart';

/// The characters a run code is written in. Crockford Base32; see the header.
const String runCodeAlphabet = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';

/// Which layout the encoder writes.
///
/// A version byte costs two characters and buys the ability to change the
/// layout later without every old code silently decoding as garbage under the
/// new rules. Old codes get [RunCodeError.unsupportedVersion], which is a
/// sentence a person can act on.
const int runCodeFormatVersion = 1;

/// Why a code could not be decoded.
///
/// Separate cases rather than one `false`, because the caller's next move
/// differs: a bad character means "you copied it wrong", a checksum failure
/// means "something changed in transit", an unsupported version means "this
/// code is from a different build of the game".
enum RunCodeError {
  /// Nothing but separators.
  empty,

  /// A character that is not in the alphabet and is not a separator.
  illegalCharacter,

  /// The number of characters is not the number this many bytes would produce.
  /// A character was added or dropped.
  nonCanonicalLength,

  /// The bits left over after the last whole byte were not zero, so the final
  /// character was not one this encoder would have written.
  paddingNotZero,

  /// Too short to hold even a version byte and a checksum.
  tooShort,

  /// A format version this build does not know how to read.
  unsupportedVersion,

  /// The CRC did not match. The code was corrupted somewhere.
  checksumMismatch,

  /// A varint ran off the end of the payload, or the tap list was shorter than
  /// its own count said.
  truncated,

  /// Bytes left over after the last tap. The code says more than the layout
  /// accounts for.
  trailingBytes,

  /// The numbers decoded cleanly and do not describe a run: a seed too wide, a
  /// frame count past the cap, a tap outside the run.
  malformedRun,
}

/// What came back from [decodeRunCode]: exactly one of a replay or an error.
class RunCodeDecoding {
  /// The run, when the code was good.
  final Replay? replay;

  /// Why not, when it was not.
  final RunCodeError? error;

  /// A sentence naming the specific thing that was wrong, for reports.
  final String detail;

  const RunCodeDecoding.success(Replay this.replay)
    : error = null,
      detail = '';

  const RunCodeDecoding.failure(RunCodeError this.error, this.detail)
    : replay = null;

  /// True when a run came back.
  bool get ok => replay != null;

  @override
  String toString() => ok ? 'ok($replay)' : '${error!.name}: $detail';
}

// =============================================================================
// Encoding
// =============================================================================

/// Encodes [replay] as a run code.
String encodeRunCode(Replay replay) {
  final List<int> payload = <int>[runCodeFormatVersion];
  _writeVarint(payload, replay.seed);
  _writeVarint(payload, replay.frames);
  _writeVarint(payload, replay.tapFrames.length);

  int previous = -1;
  for (final int tap in replay.tapFrames) {
    // The first tap is stored as itself (previous is -1, so the -1 cancels);
    // every later one as the gap since the last, minus the one frame that gap
    // can never be.
    _writeVarint(payload, tap - previous - 1);
    previous = tap;
  }

  final int checksum = crc32(payload);
  payload.add((checksum >> 24) & 0xFF);
  payload.add((checksum >> 16) & 0xFF);
  payload.add((checksum >> 8) & 0xFF);
  payload.add(checksum & 0xFF);

  return _base32Encode(payload);
}

// =============================================================================
// Decoding
// =============================================================================

/// Decodes a run code, or says precisely why it could not.
///
/// Tolerant of the ways a code gets mangled by being moved through a human:
/// lowercase, spaces, hyphens, and the `I`/`L`/`O` confusions the alphabet was
/// chosen to survive. Intolerant of everything else — every remaining
/// difference from the original is a real difference and is reported as one.
RunCodeDecoding decodeRunCode(String code) {
  final _Base32Result unpacked = _base32Decode(code);
  final List<int>? bytes = unpacked.bytes;
  if (bytes == null) return unpacked.failure!;

  if (bytes.length < 5) {
    return RunCodeDecoding.failure(
      RunCodeError.tooShort,
      '${bytes.length} byte(s); a code needs a version byte and 4 checksum '
          'bytes at the very least',
    );
  }

  final int split = bytes.length - 4;
  final List<int> body = bytes.sublist(0, split);
  final int claimed =
      (bytes[split] << 24) |
      (bytes[split + 1] << 16) |
      (bytes[split + 2] << 8) |
      bytes[split + 3];
  final int actual = crc32(body);
  if (claimed != actual) {
    return RunCodeDecoding.failure(
      RunCodeError.checksumMismatch,
      'code carries ${_hex8(claimed)}, contents hash to ${_hex8(actual)}',
    );
  }

  // Version is checked AFTER the checksum on purpose. A wrong version byte in a
  // corrupted code is a symptom, not the disease, and reporting "unsupported
  // version" for a mistyped character would send the reader looking for the
  // wrong problem.
  if (body[0] != runCodeFormatVersion) {
    return RunCodeDecoding.failure(
      RunCodeError.unsupportedVersion,
      'code is format ${body[0]}, this build reads $runCodeFormatVersion',
    );
  }

  final _Cursor cursor = _Cursor(body, 1);
  final int? seed = cursor.readVarint();
  final int? frames = cursor.readVarint();
  final int? tapCount = cursor.readVarint();
  if (seed == null || frames == null || tapCount == null) {
    return RunCodeDecoding.failure(
      RunCodeError.truncated,
      'header ran off the end of the payload',
    );
  }
  // BOTH BOUNDS ARE CHECKED BEFORE THE TAP LIST IS ALLOCATED. A corrupt count
  // of two billion would otherwise be an out-of-memory crash rather than a
  // rejection, and a verifier that can be crashed by the input it is verifying
  // is not a verifier. `Replay` re-checks both, but it re-checks them after
  // being handed a list that has already been built.
  //
  // The tap bound is one tap per frame rather than the absolute cap, because
  // that is the real limit: taps are strictly increasing and every one of them
  // is a frame of the run.
  if (frames > maxReplayFrames) {
    return RunCodeDecoding.failure(
      RunCodeError.malformedRun,
      'claims $frames frames; the cap is $maxReplayFrames',
    );
  }
  if (tapCount > frames) {
    return RunCodeDecoding.failure(
      RunCodeError.malformedRun,
      'claims $tapCount taps in a $frames-frame run',
    );
  }

  final List<int> taps = <int>[];
  int previous = -1;
  for (int i = 0; i < tapCount; i++) {
    final int? gap = cursor.readVarint();
    if (gap == null) {
      return RunCodeDecoding.failure(
        RunCodeError.truncated,
        'tap ${i + 1} of $tapCount ran off the end of the payload',
      );
    }
    previous = previous + gap + 1;
    taps.add(previous);
  }
  if (!cursor.atEnd) {
    return RunCodeDecoding.failure(
      RunCodeError.trailingBytes,
      '${cursor.remaining} byte(s) after the last tap',
    );
  }

  // The Replay constructor owns what a run IS — seed range, frame cap, taps in
  // range and strictly increasing. Re-stating those rules here would be a
  // second copy of them, and the day the two copies disagree is the day an
  // impossible run gets through.
  try {
    return RunCodeDecoding.success(
      Replay(seed: seed, tapFrames: taps, frames: frames),
    );
  } on ArgumentError catch (e) {
    return RunCodeDecoding.failure(
      RunCodeError.malformedRun,
      '${e.message} (${e.invalidValue})',
    );
  }
}

// =============================================================================
// Varints
// =============================================================================

/// Appends [value] as an unsigned LEB128 varint: seven bits per byte, low bits
/// first, high bit set on every byte but the last.
///
/// Chosen over a fixed width because almost every number in a run code is
/// small. A tap gap of 24 frames costs one byte here and four in any fixed
/// layout wide enough for the frame cap, and a typical run has a hundred of
/// them.
void _writeVarint(List<int> out, int value) {
  int v = value;
  while (v >= 0x80) {
    out.add((v & 0x7F) | 0x80);
    v = v >> 7;
  }
  out.add(v);
}

/// A read position in a payload.
class _Cursor {
  final List<int> bytes;
  int at;

  _Cursor(this.bytes, this.at);

  bool get atEnd => at >= bytes.length;

  int get remaining => bytes.length - at;

  /// The next varint, or null if it runs off the end or is longer than this
  /// encoder would ever write.
  ///
  /// FIVE BYTES, WHICH IS EXACTLY THE WIDEST FIELD: seven bits each, so five
  /// bytes carry 35 bits, and the widest thing a run code holds is a 32-bit
  /// seed at five bytes. A sixth byte is therefore not a big number, it is a
  /// corrupt one — a run of bytes that all happen to have their continuation
  /// bit set — and rejecting it here stops a damaged code from being ground
  /// into a plausible-looking integer before the checksum gets a chance to
  /// complain about it.
  int? readVarint() {
    int result = 0;
    int shift = 0;
    for (int i = 0; i < 5; i++) {
      if (at >= bytes.length) return null;
      final int b = bytes[at];
      at++;
      result |= (b & 0x7F) << shift;
      // `b < 0x80` rather than `(b & 0x80) == 0`. The two say the same thing
      // for a byte, but the masked form cannot be tested at its edge: every
      // value of `b` here is in 0..255, so `b & -0x80` and `b & 0x80` agree on
      // all of them and the constant could be negated without any test
      // noticing. A comparison against the threshold discriminates — one below
      // and the continuation bit is misread, one above and it is never seen.
      if (b < 0x80) return result;
      shift += 7;
    }
    // Five bytes all carrying a continuation bit. Not a big number — a corrupt
    // one.
    return null;
  }
}

// =============================================================================
// CRC-32
// =============================================================================

/// CRC-32 (IEEE 802.3, the one `zip` and `png` use) of [bytes].
///
/// Written out rather than pulled from a package: it is a dozen lines, it has
/// to run in a directory that may not import anything, and its output is pinned
/// against the published check value in `test/run_code_test.dart` — the string
/// `123456789` hashes to 0xCBF43926, which is the standard's own test vector.
/// A hash checked against an external constant is a hash; one checked only
/// against itself is a spelling.
///
/// BIT BY BIT RATHER THAN THROUGH THE USUAL 256-ENTRY TABLE, and the reason is
/// worth stating because the table is the textbook version:
///
/// a lookup table is indexed by a byte, so its 256 entries are the only ones
/// that can ever be read — and a table built with 257 entries, or 300, behaves
/// identically for every possible input. That makes the table's SIZE an
/// unobservable constant, which is exactly the kind of thing
/// `tool/mutate.dart` reports as a surviving mutant and which no test can ever
/// kill. Every constant in the loop below is observable: change the polynomial,
/// the round count, the shift or the initial value and the check value moves.
/// The cost is eight shifts per byte instead of one lookup, on payloads that
/// are a hundred bytes long.
int crc32(List<int> bytes) {
  int crc = 0xFFFFFFFF;
  for (final int b in bytes) {
    crc = crc ^ (b & 0xFF);
    for (int k = 0; k < 8; k++) {
      crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB88320 : crc >> 1;
    }
  }
  return (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
}

// =============================================================================
// Base32
// =============================================================================

/// Either the bytes, or the reason there are none.
///
/// A two-field result rather than a null return plus a shared error variable:
/// a decoder is a pure function of its input, and parking the reason in a
/// top-level field would make two decodes running in the same isolate able to
/// overwrite each other's diagnosis.
class _Base32Result {
  final List<int>? bytes;
  final RunCodeDecoding? failure;

  const _Base32Result.bytes(List<int> this.bytes) : failure = null;
  const _Base32Result.failure(RunCodeDecoding this.failure) : bytes = null;
}

String _base32Encode(List<int> bytes) {
  final StringBuffer out = StringBuffer();
  int buffer = 0;
  int bits = 0;
  for (final int b in bytes) {
    buffer = (buffer << 8) | b;
    bits += 8;

    // THE NUMBER OF GROUPS IS COMPUTED, NOT DRAINED BY A GUARD.
    //
    // The textbook form is `while (bits >= 5) { bits -= 5; emit(); }`, and it
    // has slack in it: eight bits arrive per byte and five leave per group, so
    // a guard of `>= 6` drains just as correctly — the one group it defers is
    // emitted on the next iteration, or by the padding block below, whose
    // shift is zero at exactly five leftover bits. The two versions produce
    // byte-identical output for every possible input, which makes the bound
    // unobservable and the comparison incapable of discriminating.
    // `tool/mutate.dart` found precisely that. Counting the whole groups first
    // leaves nothing with slack in it: change the 5 and the count changes.
    final int groups = bits ~/ 5;
    for (int g = 0; g < groups; g++) {
      bits -= 5;
      out.write(runCodeAlphabet[(buffer >> bits) & 0x1F]);
    }
  }
  if (bits > 0) {
    // Pad the final group with zero bits. The decoder insists they are zero,
    // which turns "somebody appended a character" into a rejection instead of
    // into a silently different run.
    out.write(runCodeAlphabet[(buffer << (5 - bits)) & 0x1F]);
  }
  return out.toString();
}

/// Unpacks [code] into the bytes it stands for, or says why it does not.
_Base32Result _base32Decode(String code) {
  final StringBuffer cleaned = StringBuffer();
  for (int i = 0; i < code.length; i++) {
    final String ch = code[i];
    // Separators people add or that chat clients insert. Dropped silently:
    // they carry no information, so a code with them is the same code.
    if (ch == '-' || ch == ' ' || ch == '\t' || ch == '\n' || ch == '\r') {
      continue;
    }
    cleaned.write(ch);
  }
  final String text = cleaned.toString().toUpperCase();

  if (text.isEmpty) {
    return const _Base32Result.failure(
      RunCodeDecoding.failure(RunCodeError.empty, 'no code characters at all'),
    );
  }

  final List<int> values = <int>[];
  for (int i = 0; i < text.length; i++) {
    final String ch = text[i];
    // The three deliberate confusions the alphabet exists to absorb. Folding
    // them here rather than rejecting them is the entire practical benefit of
    // Crockford's alphabet over plain Base32.
    final String folded = (ch == 'I' || ch == 'L')
        ? '1'
        : (ch == 'O' ? '0' : ch);
    final int v = runCodeAlphabet.indexOf(folded);
    if (v < 0) {
      return _Base32Result.failure(
        RunCodeDecoding.failure(
          RunCodeError.illegalCharacter,
          "'$ch' at position ${i + 1} is not a run-code character",
        ),
      );
    }
    values.add(v);
  }

  final int byteCount = (values.length * 5) ~/ 8;
  // A canonical code has exactly the number of characters its byte count
  // produces. Anything else means a character was added or lost, which the CRC
  // would also catch — but catching it here names the fault precisely.
  if (values.length != (byteCount * 8 + 4) ~/ 5) {
    return _Base32Result.failure(
      RunCodeDecoding.failure(
        RunCodeError.nonCanonicalLength,
        '${values.length} characters encode no whole number of bytes',
      ),
    );
  }

  final List<int> bytes = <int>[];
  int buffer = 0;
  int bits = 0;
  for (final int v in values) {
    buffer = (buffer << 5) | v;
    bits += 5;
    if (bits >= 8) {
      bits -= 8;
      bytes.add((buffer >> bits) & 0xFF);
    }
  }
  // No `bits > 0 &&` guard in front of this. At bits == 0 the mask is
  // `(1 << 0) - 1`, which is zero, so the whole condition is already false —
  // the guard was redundant, and a redundant comparison is one whose two
  // neighbours agree on every input, which is a mutant no test can kill.
  if ((buffer & ((1 << bits) - 1)) != 0) {
    return _Base32Result.failure(
      RunCodeDecoding.failure(
        RunCodeError.paddingNotZero,
        'the last character carries $bits bit(s) this encoder never sets',
      ),
    );
  }
  return _Base32Result.bytes(bytes);
}

String _hex8(int v) => '0x${v.toRadixString(16).toUpperCase().padLeft(8, '0')}';
