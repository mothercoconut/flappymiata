/// The palette's own structure: that it is complete, that nothing escapes it,
/// and that the things it claims are the same colour really are.
///
/// ============================================================================
/// THIS IS THE FILE THAT MAKES THE CONTRAST TEST MEAN ANYTHING
/// ============================================================================
///
/// `test/palette_contrast_test.dart` grades a list of pairs. A list is only as
/// good as the guarantee that everything the app draws is on it, and there is
/// no such guarantee available from inside Dart — a `Color(0xFFBADBAD)` typed
/// into a widget compiles, renders, and is invisible to any test that iterates
/// over a palette.
///
/// So the guarantee is made outside the type system, by reading the source:
/// `lib/main.dart` and `lib/ui/` may not contain a colour literal, and
/// `lib/ui/palette.dart` may not contain a colour the enumeration has forgotten.
/// Between them, every colour that reaches a pixel is a colour something grades.
///
/// WHAT THE SCAN DOES NOT COVER, stated rather than left to be discovered:
///
///   * `lib/dev/` and `lib/game/` are not scanned. `lib/game/` is pure Dart with
///     no Flutter import at all and therefore cannot name a colour; `lib/dev/`
///     is a developer harness that never ships.
///   * Whole-line comments are stripped before scanning and trailing comments
///     are not, so a colour literal written after code on the same line as a
///     `//` would be reported. That is the failure direction to prefer: it
///     complains about something harmless rather than passing something real.
///   * It cannot see a colour that arrives at runtime — from a shader, a decoded
///     image, or arithmetic on another colour. The gradient in `_BackdropLayer`
///     interpolates between two palette entries, and the pixels in between are
///     not graded. See `test/palette_contrast_test.dart` for why that is
///     acceptable here and where it would not be.
library;

import 'dart:io';

import 'package:flutter/widgets.dart' show Color;
import 'package:flutter_test/flutter_test.dart';

import 'package:flappymiata/ui/colour_math.dart';
import 'package:flappymiata/ui/game_screens.dart';
import 'package:flappymiata/ui/palette.dart' as palette;

/// The files that draw, and are therefore forbidden their own colours: every
/// file under `lib/ui/` plus `lib/main.dart`, minus the palette itself.
///
/// Listed rather than globbed, so that a new file added to `lib/ui/` and left
/// off this list is a visible omission in a diff instead of an invisible one.
const List<String> scannedFiles = <String>[
  'lib/main.dart',
  'lib/ui/game_screens.dart',
  'lib/ui/motion.dart',
  'lib/ui/high_score_store.dart',
  'lib/ui/assist.dart',
  'lib/ui/colour_math.dart',
];

/// Ways to write a colour that this scan refuses outside the palette.
final List<RegExp> colourLiteralPatterns = <RegExp>[
  RegExp(r'Color\s*\(\s*0x'),
  RegExp(r'Color\s*\.\s*fromARGB'),
  RegExp(r'Color\s*\.\s*fromRGBO'),
  RegExp(r'\bColors\s*\.'),
];

/// [source] with every whole-line comment BLANKED — not deleted.
///
/// Blanked rather than dropped so the line numbering survives. A scan that
/// deletes lines reports offences at the wrong line, and a line number that
/// points at innocent code is worse than no line number: the reader goes and
/// looks, finds nothing, and stops trusting the check.
String withoutLineComments(String source) => source
    .split('\n')
    .map((String line) => line.trimLeft().startsWith('//') ? '' : line)
    .join('\n');

void main() {
  group('every colour the UI draws comes from the palette', () {
    test('the files that draw contain no colour literals', () {
      final List<String> offences = <String>[];
      for (final String path in scannedFiles) {
        final File file = File(path);
        expect(file.existsSync(), isTrue,
            reason: '$path is on the scan list but does not exist — the list '
                'has gone stale and the scan is checking less than it claims');
        final List<String> lines = withoutLineComments(
          file.readAsStringSync(),
        ).split('\n');
        for (int i = 0; i < lines.length; i++) {
          for (final RegExp pattern in colourLiteralPatterns) {
            if (pattern.hasMatch(lines[i])) {
              offences.add('$path:${i + 1}: ${lines[i].trim()}');
            }
          }
        }
      }
      expect(offences, isEmpty,
          reason: 'a colour was written where it is drawn instead of in '
              'lib/ui/palette.dart, so nothing grades it for contrast:\n'
              '${offences.join('\n')}');
    });

    test('the scan would actually catch one', () {
      // THE DETECTOR, DETECTED. A regex that matched nothing would make the
      // test above pass on any source at all, which is precisely the failure
      // this whole file exists to rule out elsewhere. So the patterns are run
      // against lines that definitely are colour literals, and against lines
      // that definitely are not.
      const List<String> shouldMatch = <String>[
        'static final Paint p = Paint()..color = const Color(0xFF123456);',
        '  color: Color(0xF20A1D32),',
        'const Color x = Color.fromARGB(255, 1, 2, 3);',
        'const Color y = Color.fromRGBO(1, 2, 3, 1.0);',
        '  color: Colors.red,',
      ];
      const List<String> shouldNotMatch = <String>[
        'const Color screenInk = Color(palette.ink);',
        'canvas.drawRect(box, _pipeBody);',
        'final int argb = 0xFF123456;',
        'import "package:flappymiata/ui/palette.dart" as palette;',
      ];
      for (final String line in shouldMatch) {
        expect(colourLiteralPatterns.any((RegExp r) => r.hasMatch(line)),
            isTrue, reason: 'missed: $line');
      }
      for (final String line in shouldNotMatch) {
        expect(colourLiteralPatterns.any((RegExp r) => r.hasMatch(line)),
            isFalse, reason: 'false positive: $line');
      }
    });

    test('the comment stripper only strips comments', () {
      expect(withoutLineComments('  // Color(0xFF000000)\nkeep'), '\nkeep');
      expect(withoutLineComments('/// Color(0xFF000000)\nkeep'), '\nkeep');
      expect(withoutLineComments('const Color a = Color(0x1);'),
          'const Color a = Color(0x1);');
    });
  });

  group('the palette enumerates itself completely', () {
    test('every const colour in palette.dart has an entry in paletteColours',
        () {
      final String source = File('lib/ui/palette.dart').readAsStringSync();
      final Iterable<RegExpMatch> declared =
          RegExp(r'^const int (\w+) = (0x[0-9A-Fa-f]+);', multiLine: true)
              .allMatches(source);

      final List<String> names =
          declared.map((RegExpMatch m) => m.group(1)!).toList();
      expect(names.length, greaterThanOrEqualTo(20),
          reason: 'the declaration regex found almost nothing, so this test is '
              'checking almost nothing');

      final Map<String, int> listed = <String, int>{
        for (final palette.PaletteColour c in palette.paletteColours)
          c.name: c.argb,
      };

      for (final RegExpMatch m in declared) {
        final String name = m.group(1)!;
        final int value = int.parse(m.group(2)!);
        expect(listed, contains(name),
            reason: '$name is a colour in the app that paletteColours does '
                'not list, so nothing grades it');
        expect(listed[name], value,
            reason: '$name is listed as ${hexOf(listed[name]!)} but declared '
                'as ${hexOf(value)}');
      }

      expect(listed.length, names.length,
          reason: 'paletteColours lists something that is not a declared '
              'colour: ${listed.keys.toSet().difference(names.toSet())}');
    });

    test('no two entries share a name', () {
      final Set<String> seen = <String>{};
      for (final palette.PaletteColour c in palette.paletteColours) {
        expect(seen.add(c.name), isTrue, reason: 'duplicate name ${c.name}');
      }
    });

    test('every entry says what it is for', () {
      for (final palette.PaletteColour c in palette.paletteColours) {
        expect(c.role.trim(), isNotEmpty, reason: c.name);
      }
    });
  });

  group('colours that claim to be the same colour are', () {
    test('the ghost, the assist window and every panel border share one teal',
        () {
      // Three places call themselves "the game's teal" and three constants say
      // so. Without this they can drift, and the drift shows up as one teal
      // being graded and another being drawn.
      int rgb(int argb) => argb & 0x00FFFFFF;
      expect(rgb(palette.ghostSilhouette), rgb(palette.panelBorder),
          reason: 'the ghost is a different teal from the panels');
      expect(rgb(palette.assistWindow), rgb(palette.panelBorder),
          reason: 'the assist window is a different teal from the panels');
      // And they differ only in alpha, which is the intended difference.
      expect(alphaOf(palette.ghostSilhouette), lessThan(0xFF));
      expect(alphaOf(palette.panelBorder), 0xFF);
    });

    test('the deadline mark and the collision overlay share one pink', () {
      expect(palette.assistDeadline & 0x00FFFFFF,
          palette.debugCarBox & 0x00FFFFFF);
    });
  });

  group('the widget layer is wired to the palette', () {
    test('every exported screen colour is its palette entry', () {
      // The seam between a pure-Dart palette of ints and a widget tree that
      // wants `Color`s. It is one conversion per colour and it is exactly the
      // kind of line a copy-paste gets wrong.
      expect(screenCardBacking, const Color(palette.cardSurface));
      expect(screenBorder, const Color(palette.panelBorder));
      expect(screenInk, const Color(palette.ink));
      expect(screenInkDim, const Color(palette.inkDim));
      expect(screenScrim, const Color(palette.scrim));
      expect(screenButtonFill, const Color(palette.buttonFill));
      expect(screenButtonPlainFill, const Color(palette.buttonPlainFill));
    });
  });

  group('surfaces that carry text are opaque', () {
    test('all of them, and the list is not empty', () {
      // WHY THIS IS AN ASSERTION AND NOT A COMMENT: the HUD panel's own comment
      // insisted its alpha "is FF and has to stay FF" while the constant beside
      // it said 0xE8. A paragraph cannot fail. This can.
      expect(palette.textBearingSurfaces, isNotEmpty);
      for (final palette.PaletteColour s in palette.textBearingSurfaces) {
        expect(isOpaque(s.argb), isTrue,
            reason: '${s.name} is ${hexOf(s.argb)}: text drawn on it is being '
                'read against whatever happens to be passing behind, so its '
                'contrast is a property of the frame and not of the palette');
      }
    });

    test('the scrim is deliberately NOT one of them', () {
      // The other side of the rule. The scrim has to stay translucent — a
      // paused game must still look like the game behind it — and that is only
      // safe because no text is ever drawn directly on it.
      expect(isOpaque(palette.scrim), isFalse);
      expect(
        palette.textBearingSurfaces
            .any((palette.PaletteColour s) => s.argb == palette.scrim),
        isFalse,
      );
    });
  });
}
