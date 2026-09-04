/// Prints the numbers behind every colour claim this app makes.
///
///     dart run tool\palette_report.dart
///     dart run tool\palette_report.dart --csv
///
/// WHY A TOOL AS WELL AS A TEST: the tests in `test/palette_contrast_test.dart`
/// and `test/palette_colourblind_test.dart` answer one question — does the
/// palette pass — and a test that passes prints nothing. This prints the whole
/// table, including the pairs that pass comfortably and by how much, which is
/// what somebody changing a colour actually needs. It runs under a bare
/// `dart run` because `lib/ui/palette.dart` and `lib/ui/colour_math.dart` are
/// pure Dart with no `dart:ui` in them.
///
/// The tool and the tests share the same functions and the same palette, so
/// this cannot report one thing while the suite asserts another. What it does
/// NOT cover is the widget-tree crawl and the car sprite, both of which need a
/// Flutter engine — see `test/palette_contrast_test.dart` and
/// `test/sprite_colours.dart`.
library;

import 'dart:io';

import 'package:flappymiata/ui/colour_math.dart';
import 'package:flappymiata/ui/palette.dart';

void main(List<String> args) {
  final bool csv = args.contains('--csv');

  _calculatorCheck();
  _contrastTable(csv: csv);
  _colourblindTable(csv: csv);

  final int failures = textPairs.where((TextPair p) => !p.passes).length +
      distinctPairs
          .where((DistinctPair p) => <Dichromacy?>[
                null,
                Dichromacy.deuteranopia,
                Dichromacy.protanopia,
              ].any((Dichromacy? t) =>
                  p.worstDifference(t) < distinguishableDeltaE))
          .length;

  stdout.writeln('');
  if (failures == 0) {
    stdout.writeln('OK — every pair clears its bar.');
  } else {
    stdout.writeln('$failures pair(s) below the bar.');
    exitCode = 1;
  }
}

/// The calculator, checked against answers computed by somebody else, before
/// anything is graded by it. Printed rather than assumed, because a reader who
/// does not trust the table below should be able to see the instrument being
/// zeroed.
void _calculatorCheck() {
  stdout.writeln('CONTRAST CALCULATOR — reference pairs');
  stdout.writeln('-' * 72);
  const List<(String, int, int, double)> references =
      <(String, int, int, double)>[
    ('black on white', 0xFF000000, 0xFFFFFFFF, 21.0),
    ('white on white', 0xFFFFFFFF, 0xFFFFFFFF, 1.0),
    ('black on black', 0xFF000000, 0xFF000000, 1.0),
    ('mid grey #767676 on white', 0xFF767676, 0xFFFFFFFF, 4.54),
    ('pure blue on white', 0xFF0000FF, 0xFFFFFFFF, 8.59),
    ('pure red on white', 0xFFFF0000, 0xFFFFFFFF, 3.99),
    ('pure green on black', 0xFF00FF00, 0xFF000000, 15.30),
  ];
  for (final (String name, int fg, int bg, double want) in references) {
    final double got = contrastRatio(fg, bg);
    stdout.writeln('  ${name.padRight(28)} '
        'expected ${want.toStringAsFixed(2).padLeft(6)}  '
        'got ${got.toStringAsFixed(4).padLeft(8)}');
  }
  stdout.writeln('');
}

void _contrastTable({required bool csv}) {
  stdout.writeln('TEXT AND CONTROL CONTRAST — WCAG 2.x, AA');
  stdout.writeln('-' * 96);
  if (csv) {
    stdout.writeln('where,foreground,background,ratio,required,verdict');
  } else {
    stdout.writeln('  ${'where'.padRight(44)}${'fg'.padRight(11)}'
        '${'bg'.padRight(11)}${'ratio'.padLeft(9)}  req  verdict');
  }
  for (final TextPair p in textPairs) {
    final String verdict = p.passes ? 'PASS' : 'FAIL';
    if (csv) {
      stdout.writeln('"${p.where}",${hexOf(p.foreground)},'
          '${hexOf(p.background)},${p.ratio.toStringAsFixed(4)},'
          '${p.required},$verdict');
    } else {
      stdout.writeln('  ${p.where.padRight(44)}'
          '${hexOf(p.foreground).padRight(11)}'
          '${hexOf(p.background).padRight(11)}'
          '${'${p.ratio.toStringAsFixed(2)}:1'.padLeft(9)}  '
          '${p.required.toStringAsFixed(1)}  $verdict');
    }
  }
  stdout.writeln('');
}

void _colourblindTable({required bool csv}) {
  stdout.writeln('DISTINGUISHABILITY — CIEDE2000, worst backdrop, '
      'bar ${distinguishableDeltaE.toStringAsFixed(1)}');
  stdout.writeln('-' * 96);
  if (csv) {
    stdout.writeln('pair,normal,deuteranopia,protanopia,verdict');
  } else {
    stdout.writeln('  ${'pair'.padRight(48)}${'normal'.padLeft(9)}'
        '${'deutan'.padLeft(9)}${'protan'.padLeft(9)}  verdict');
  }
  for (final DistinctPair p in distinctPairs) {
    final double normal = p.worstDifference(null);
    final double deutan = p.worstDifference(Dichromacy.deuteranopia);
    final double protan = p.worstDifference(Dichromacy.protanopia);
    final bool ok = normal >= distinguishableDeltaE &&
        deutan >= distinguishableDeltaE &&
        protan >= distinguishableDeltaE;
    if (csv) {
      stdout.writeln('"${p.label}",${normal.toStringAsFixed(4)},'
          '${deutan.toStringAsFixed(4)},${protan.toStringAsFixed(4)},'
          '${ok ? 'PASS' : 'FAIL'}');
    } else {
      stdout.writeln('  ${p.label.padRight(48)}'
          '${normal.toStringAsFixed(2).padLeft(9)}'
          '${deutan.toStringAsFixed(2).padLeft(9)}'
          '${protan.toStringAsFixed(2).padLeft(9)}  '
          '${ok ? 'PASS' : 'FAIL'}');
    }
  }
  stdout.writeln('');
  stdout.writeln('  These are simulations of DICHROMACY — a missing cone —');
  stdout.writeln('  not of the far commoner anomalous trichromacy, and not of');
  stdout.writeln('  anybody\'s experience. No colourblind player has seen this');
  stdout.writeln('  game. See lib/ui/colour_math.dart for the full caveats.');
}
