/// Mutation testing for `lib/game/` — the tool that grades the test suite.
///
/// A passing test suite tells you the tests agree with the code. It does not
/// tell you the tests would NOTICE if the code were wrong. Mutation testing
/// asks exactly that: break the code on purpose, one small edit at a time, and
/// see whether anything goes red. An edit nothing catches is a "survivor", and
/// a survivor is a hole in the suite — or, occasionally, a piece of code whose
/// behaviour genuinely does not matter, which is a different and rarer thing.
///
///     dart run tool\mutate.dart              # every mutant
///     dart run tool\mutate.dart --quick      # the CI subset (see quickSubset)
///     dart run tool\mutate.dart --list       # generate, print, run nothing
///     dart run tool\mutate.dart --selftest   # prove the tool can say all three
///     dart run tool\mutate.dart --only=R017,C044
///
/// WHY THIS FILE IS PURE DART AND MUTATES ONLY `lib/game/`: the rules live in
/// two files with no renderer, no clock and no randomness, so a mutant's effect
/// is a deterministic function of the source. That is what makes "the suite did
/// not notice" a fact rather than a flake.
///
/// THE THREE VERDICTS, AND WHY THERE ARE THREE AND NOT TWO:
///
///   KILLED   — at least one test failed. The suite noticed. Good.
///   SURVIVED — every test passed with broken code. The suite did not notice.
///   INVALID  — the mutant did not COMPILE, so no test ever ran against it.
///
/// The third one is the whole reason this tool can be trusted. Swapping `<` for
/// `<=` on two enums, or `*` for `/` where the operands are not numbers, is not
/// a program at all — the compiler rejects it before a single test executes.
/// Counting those as kills is the classic way to fake a high mutation score:
/// they are free "wins" that no test earned, and a suite that asserts nothing
/// would still collect them. They are counted separately here and removed from
/// both the numerator and the denominator, because a mutant that never ran is
/// evidence about the mutation generator, not about the tests.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

// =============================================================================
// Configuration
// =============================================================================

/// The only files that get mutated. Deliberately narrow: `lib/game/` is the
/// model, it is pure Dart, and it is the part of the app whose correctness the
/// test suite claims to establish. Mutating the renderer would mostly generate
/// mutants no headless test could ever kill, which inflates the survivor list
/// with noise and teaches the reader to ignore it.
const List<String> targetFiles = <String>[
  'lib/game/game_model.dart',
  'lib/game/geometry.dart',
];

/// TIER 1 — the fast gate. These are exactly the test files that import the
/// model (directly, or through `tool/headless_sim.dart`) and assert on its
/// behaviour.
///
/// WHY A SUBSET IS SAFE HERE, WHICH IS NOT OBVIOUS AND MATTERS:
///
/// Running fewer tests can only ever UNDER-kill. If a tier-1 test fails, that
/// same test is in the full suite and would fail there too, so a tier-1 kill is
/// a full-suite kill with no further checking. The reverse is not true — a
/// tier-1 pass is not a full-suite pass — so every tier-1 survivor is re-run
/// against the WHOLE suite before it is called a survivor (see [tier2Tests]).
/// The final verdict for every mutant is therefore identical to what running
/// the full suite on all of them would produce; the tiering only saves time on
/// the ~95% of mutants that die immediately.
///
/// Measured on this machine: tier 1 is 2.9s, the full suite is 9.5s. Nearly all
/// of that 6.6s difference is `fairness_prover_test.dart`, which searches a
/// reachability bitmap and is by far the most expensive file in the suite.
const List<String> tier1Tests = <String>[
  'test/game_model_test.dart',
  'test/car_geometry_test.dart',
  'test/headless_sim_test.dart',
  'test/tuning_constants_test.dart',
  'test/model_boundaries_test.dart',
];

/// TIER 2 — the escalation. An empty argument list means "every test file",
/// which is what `flutter test` does with no paths: all 57 tests, including
/// `fairness_prover_test.dart` (whose prover re-derives the model's physics and
/// so can see constant changes tier 1 might not) and `widget_test.dart`.
const List<String> tier2Tests = <String>[];

/// Files and directories copied into a worker sandbox by `--jobs=N`.
///
/// WHY A SANDBOX IS NEEDED AT ALL: a mutant is a broken file on disk, and there
/// is only one `lib/game/game_model.dart`. Two workers mutating it at once
/// would judge each other's mutants and every verdict would be nonsense. Each
/// worker therefore gets its own copy of the package and never touches the real
/// one — which also means that in `--jobs=N` mode the repository is not
/// modified at all, and the hash check at the end is proving something stronger
/// than "we put it back".
///
/// `.dart_tool/flutter_build` is deliberately NOT copied: it is 185 MB of asset
/// build output that `flutter test` regenerates on demand, and copying it once
/// per worker would cost more than the parallelism saves.
const List<String> sandboxFiles = <String>[
  'pubspec.yaml',
  'pubspec.lock',
  'analysis_options.yaml',
  '.dart_tool/package_config.json',
  '.dart_tool/package_graph.json',
  '.dart_tool/version',
];

const List<String> sandboxDirs = <String>['lib', 'test', 'tool', 'assets'];

/// How long a single test run may take before it is killed.
///
/// WHY A TIMEOUT KILL IS WEAKER EVIDENCE THAN A TEST FAILURE, and is reported
/// separately below: a failing assertion names the behaviour that changed. A
/// timeout only says the run did not finish, and "did not finish" has innocent
/// explanations — a slow machine, a cold compile, another process hogging the
/// disk. It is still counted as a kill, because a mutant that hangs the suite
/// is unquestionably detected, but a reader deserves to know how many of the
/// kills rest on that softer argument. The full suite takes ~10s, so 45s is
/// roughly a 4x margin: comfortably clear of normal variation, tight enough
/// that a genuine infinite loop does not stall the run for a minute.
const Duration defaultTimeout = Duration(seconds: 45);

// =============================================================================
// Known-equivalent mutants
// =============================================================================

/// A mutant that is EXCLUDED from the score because the mutated program has
/// identical observable behaviour to the original for every possible input.
///
/// WHY EACH ONE CARRIES A WRITTEN ARGUMENT, and why "probably equivalent" is
/// not allowed anywhere in this list:
///
/// Excluding a mutant removes it from the denominator, which RAISES the score.
/// That makes this list the one place in the tool where carelessness pays, so
/// it is the one place that has to be checked by a human reading a reason. An
/// unargued exclusion is indistinguishable from a survivor swept under the rug,
/// and a mutation score built on those is worth less than no score at all.
///
/// Equivalence is also undecidable in general, so no tool can find these for
/// you — the argument is the deliverable.
class KnownEquivalent {
  const KnownEquivalent({
    required this.file,
    required this.line,
    required this.original,
    required this.replacement,
    required this.argument,
  });

  /// Repo-relative path, matching [targetFiles].
  final String file;

  /// 1-based line the mutated token sits on.
  final int line;

  /// The exact source text being replaced. Checked against the generated
  /// mutant at startup: if `lib/game/` changes under this table, the tool
  /// aborts rather than silently excluding the wrong mutant.
  final String original;

  /// The exact replacement text.
  final String replacement;

  /// Why no test can distinguish the two programs. Printed in the report.
  final String argument;
}

/// Populated only by argument. Four entries, each with a proof rather than a
/// hunch. Everything else that survived the first run was killed by a test.
const List<KnownEquivalent> knownEquivalents = <KnownEquivalent>[
  KnownEquivalent(
    file: 'lib/game/game_model.dart',
    line: 357,
    original: '<',
    replacement: '<=',
    argument:
        'clampGapCentre: `if (centre < minGapCentre) return minGapCentre;`. '
        'The two versions differ on exactly one input, centre == minGapCentre. '
        'The mutant returns minGapCentre. The original falls through to '
        '`if (centre > maxGapCentre)` — false, because minGapCentre < '
        'maxGapCentre — and then returns `centre`, which IS minGapCentre. Same '
        'double, by the same equality that selected the branch. For every '
        'other input the condition has the same truth value, so the two '
        'functions are equal everywhere and no test can separate them.',
  ),
  KnownEquivalent(
    file: 'lib/game/game_model.dart',
    line: 358,
    original: '>',
    replacement: '>=',
    argument:
        'clampGapCentre: `if (centre > maxGapCentre) return maxGapCentre;`. '
        'The mirror of the case above. They differ only at '
        'centre == maxGapCentre, where the mutant returns maxGapCentre and the '
        'original returns `centre`, which is that same double. Equal '
        'everywhere else by identical truth values.',
  ),
  KnownEquivalent(
    file: 'lib/game/game_model.dart',
    line: 497,
    original: '<',
    replacement: '<=',
    argument:
        '`final double restingY = nextY < minY ? minY : maxY;`. This line is '
        'reached ONLY under the guard on line 491, `nextY < minY || nextY > '
        'maxY`. Inside that guard nextY == minY is impossible: the first '
        'disjunct excludes it outright, and the second requires nextY > maxY, '
        'which with minY < maxY also excludes it. `<` and `<=` differ only at '
        'equality, and equality is unreachable at this point, so the ternary '
        'selects the same branch for every input that can ever reach it. '
        '(NaN cannot reach it either: every comparison against NaN is false, '
        'so the guard on 491 is false and the line is skipped.)',
  ),
  KnownEquivalent(
    file: 'lib/game/game_model.dart',
    line: 110,
    original: 'playfieldTop',
    replacement: '0.0',
    argument:
        '`static const double minY = playfieldTop;` becomes '
        '`static const double minY = 0.0;`. `playfieldTop` is itself declared '
        '`const double playfieldTop = 0.0;` in geometry.dart, so both '
        'initialisers are the SAME compile-time constant: after const '
        'evaluation the two programs are byte-for-byte the same program. Not '
        '"behaves the same" — literally the same value, including its sign '
        'bit, so no input and no observation of any kind can distinguish them.',
  ),
];

// =============================================================================
// Mutation operators
// =============================================================================

/// The six operator families. Named, because the report groups by them and
/// `--quick` samples within them.
enum MutOp {
  relational('REL', 'relational: < <= > >= == != swapped among neighbours'),
  arithmetic('ARI', 'arithmetic: binary + - * / swapped for each other'),
  boolean('BOO', 'boolean: && <-> ||, unary ! dropped, if/while conditions negated'),
  constant('CON', 'constants: numeric literals and named const initialisers -> 0, -x, x + step'),
  returns('RET', 'returns: every bool-returning expression forced to true and to false'),
  assignment('ASG', 'assignment: compound operators swapped (+= <-> -=, *= <-> /=, ++ <-> --)');

  const MutOp(this.tag, this.description);

  /// Short prefix used in mutant ids, e.g. `REL017`.
  final String tag;

  /// One line for the report header, so the operator set is stated by the tool
  /// rather than only in prose that can drift away from the code.
  final String description;
}

/// One single-point edit: replace `[offset, offset + length)` in [file] with
/// [replacement].
class Mutant {
  Mutant({
    required this.id,
    required this.file,
    required this.offset,
    required this.length,
    required this.original,
    required this.replacement,
    required this.op,
    required this.line,
    required this.column,
  });

  final String id;
  final String file;
  final int offset;
  final int length;
  final String original;
  final String replacement;
  final MutOp op;
  final int line;
  final int column;

  /// `lib/game/geometry.dart:85:12  REL  '<' -> '<='`
  String describe() =>
      '$file:$line:$column  ${op.tag}  ${_q(original)} -> ${_q(replacement)}';

  static String _q(String s) => "'${s.replaceAll('\n', r'\n')}'";
}

/// What happened when the suite was run against one mutant.
enum Verdict {
  /// A test failed. The suite noticed.
  killed,

  /// The run did not finish inside [defaultTimeout]. Counted as a kill,
  /// reported separately, because "hung" is weaker evidence than "failed".
  killedByTimeout,

  /// Every test passed against broken code. A hole in the suite.
  survived,

  /// Did not compile, so no test ran. Neither a kill nor a survivor.
  invalid,

  /// Argued equivalent in [knownEquivalents]. Excluded from the denominator.
  equivalent,
}

class MutantResult {
  MutantResult(this.mutant, this.verdict, this.elapsed, this.detail);

  final Mutant mutant;
  final Verdict verdict;
  final Duration elapsed;

  /// First useful line of compiler or test output, for the invalid list.
  final String detail;
}

// =============================================================================
// Source scanning
// =============================================================================

enum TokKind { op, number, word, other }

class Tok {
  Tok(this.start, this.end, this.text, this.kind);

  final int start;
  final int end;
  final String text;
  final TokKind kind;
}

/// Multi-character operators, longest first.
///
/// WHY THE LONGEST-MATCH ORDER IS LOAD-BEARING: `>>` has to be recognised as a
/// single shift token, or the hash mixer's `h >> 16` would look like two `>`
/// comparisons and get "swapped" into code that does not parse. Same story for
/// `=>`, which would otherwise donate a bogus `>` to the relational operator.
const List<String> _multiCharOps = <String>[
  '>>>=', '<<=', '>>=', '~/=', '??=',
  '>>>', '...',
  '~/', '=>', '==', '!=', '<=', '>=', '&&', '||', '??', '<<', '>>',
  '++', '--', '+=', '-=', '*=', '/=', '%=', '&=', '|=', '^=',
];

/// Tokenises [src], skipping comments and string literals entirely.
///
/// WHY COMMENTS AND STRINGS ARE INVISIBLE TO THE MUTATOR: `game_model.dart` is
/// mostly prose, and that prose is full of things that look like operators —
/// `velocity += flapImpulse`, `y > maxY`, `2.2`. Mutating a comment produces a
/// mutant that no test can kill because it changes nothing, which would fill
/// the survivor list with hundreds of entries that mean nothing. Mutating a
/// string would change a `toString()` no test asserts on, for the same effect.
List<Tok> scan(String src) {
  final List<Tok> out = <Tok>[];
  final int n = src.length;
  int i = 0;

  while (i < n) {
    final String c = src[i];

    // Whitespace.
    if (c == ' ' || c == '\t' || c == '\r' || c == '\n') {
      i++;
      continue;
    }

    // Line comment.
    if (c == '/' && i + 1 < n && src[i + 1] == '/') {
      while (i < n && src[i] != '\n') {
        i++;
      }
      continue;
    }

    // Block comment. Dart nests these, so count depth rather than searching
    // for the first `*/`.
    if (c == '/' && i + 1 < n && src[i + 1] == '*') {
      int depth = 1;
      i += 2;
      while (i < n && depth > 0) {
        if (src[i] == '/' && i + 1 < n && src[i + 1] == '*') {
          depth++;
          i += 2;
        } else if (src[i] == '*' && i + 1 < n && src[i + 1] == '/') {
          depth--;
          i += 2;
        } else {
          i++;
        }
      }
      continue;
    }

    // Raw string: r'...' or r"...".
    if (c == 'r' && i + 1 < n && (src[i + 1] == "'" || src[i + 1] == '"')) {
      i = _skipString(src, i + 1, raw: true);
      continue;
    }

    // Ordinary string.
    if (c == "'" || c == '"') {
      i = _skipString(src, i, raw: false);
      continue;
    }

    // Number.
    if (_isDigit(c)) {
      final int start = i;
      if (c == '0' && i + 1 < n && (src[i + 1] == 'x' || src[i + 1] == 'X')) {
        i += 2;
        while (i < n && _isHexDigit(src[i])) {
          i++;
        }
      } else {
        while (i < n && _isDigit(src[i])) {
          i++;
        }
        if (i < n && src[i] == '.' && i + 1 < n && _isDigit(src[i + 1])) {
          i++;
          while (i < n && _isDigit(src[i])) {
            i++;
          }
        }
        if (i < n && (src[i] == 'e' || src[i] == 'E')) {
          int j = i + 1;
          if (j < n && (src[j] == '+' || src[j] == '-')) {
            j++;
          }
          if (j < n && _isDigit(src[j])) {
            i = j;
            while (i < n && _isDigit(src[i])) {
              i++;
            }
          }
        }
      }
      out.add(Tok(start, i, src.substring(start, i), TokKind.number));
      continue;
    }

    // Identifier or keyword.
    if (_isWordStart(c)) {
      final int start = i;
      while (i < n && _isWordPart(src[i])) {
        i++;
      }
      out.add(Tok(start, i, src.substring(start, i), TokKind.word));
      continue;
    }

    // Operator, longest match first.
    String? matched;
    for (final String op in _multiCharOps) {
      if (src.startsWith(op, i)) {
        matched = op;
        break;
      }
    }
    matched ??= c;
    out.add(
      Tok(i, i + matched.length, matched, TokKind.op),
    );
    i += matched.length;
  }

  return out;
}

/// Skips a string literal starting at [start] and returns the index just past
/// its closing quote.
///
/// Interpolation is skipped whole: `${...}` is treated as opaque, brace-counted
/// so a nested map literal does not end the string early. That means the mutator
/// cannot reach code inside an interpolation — there is none in `lib/game/`
/// beyond field reads in `toString()`, and a real parser here would be more
/// machinery than the rule is worth.
int _skipString(String src, int start, {required bool raw}) {
  final int n = src.length;
  final String quote = src[start];
  int i = start;
  bool triple = false;

  if (src.startsWith(quote * 3, i)) {
    triple = true;
    i += 3;
  } else {
    i += 1;
  }

  while (i < n) {
    if (!raw && src[i] == r'\') {
      i += 2;
      continue;
    }
    if (!raw && src[i] == r'$' && i + 1 < n && src[i + 1] == '{') {
      int depth = 0;
      i += 1;
      while (i < n) {
        if (src[i] == '{') {
          depth++;
        } else if (src[i] == '}') {
          depth--;
          if (depth == 0) {
            i++;
            break;
          }
        }
        i++;
      }
      continue;
    }
    if (triple && src.startsWith(quote * 3, i)) {
      return i + 3;
    }
    if (!triple && src[i] == quote) {
      return i + 1;
    }
    if (!triple && src[i] == '\n') {
      // Unterminated single-line string. Should not happen in valid Dart; bail
      // out rather than run to end of file.
      return i;
    }
    i++;
  }
  return n;
}

bool _isDigit(String c) => c.codeUnitAt(0) >= 0x30 && c.codeUnitAt(0) <= 0x39;

bool _isHexDigit(String c) {
  final int u = c.codeUnitAt(0);
  return (u >= 0x30 && u <= 0x39) ||
      (u >= 0x41 && u <= 0x46) ||
      (u >= 0x61 && u <= 0x66);
}

bool _isWordStart(String c) {
  final int u = c.codeUnitAt(0);
  return (u >= 0x41 && u <= 0x5A) || (u >= 0x61 && u <= 0x7A) || u == 0x5F;
}

bool _isWordPart(String c) => _isWordStart(c) || _isDigit(c);

// =============================================================================
// Mutation generation
// =============================================================================

/// Tokens that can only be followed by an expression, so a `+`, `-` or `!`
/// immediately after one of them is UNARY rather than binary.
///
/// WHY UNARY `+`/`-` IS EXCLUDED FROM THE ARITHMETIC OPERATOR: `-0.72` is a
/// negative literal, not a subtraction. Turning its `-` into a `*` produces
/// `= *0.72`, which is not a program; turning it into `+` produces a sign flip
/// that the constant operator already generates as `x -> -x`, more precisely
/// and without the duplicate. So the sign of a literal is the constant
/// operator's business and the arithmetic operator stays out of it.
const Set<String> _prefixContexts = <String>{
  '(', '[', '{', ',', ';', ':', '?', '=', '=>',
  '+', '-', '*', '/', '%', '<', '>', '<=', '>=', '==', '!=',
  '&&', '||', '!', '??', '&', '|', '^', '~/', '<<', '>>',
  '+=', '-=', '*=', '/=', 'return', 'case',
};

/// Which replacements each relational operator gets.
///
/// Three per ordering operator, chosen to cover the three ways a comparison
/// goes wrong in practice: the boundary moves by one (`<` vs `<=`), the
/// direction is mirrored (`<` vs `>`), or the whole test is inverted
/// (`<` vs `>=`). Equality operators only have one neighbour worth trying.
const Map<String, List<String>> _relationalSwaps = <String, List<String>>{
  '<': <String>['<=', '>', '>='],
  '<=': <String>['<', '>=', '>'],
  '>': <String>['>=', '<', '<='],
  '>=': <String>['>', '<=', '<'],
  '==': <String>['!='],
  '!=': <String>['=='],
};

const Map<String, List<String>> _arithmeticSwaps = <String, List<String>>{
  '+': <String>['-', '*', '/'],
  '-': <String>['+', '*', '/'],
  '*': <String>['+', '-', '/'],
  '/': <String>['+', '-', '*'],
};

const Map<String, String> _booleanSwaps = <String, String>{
  '&&': '||',
  '||': '&&',
};

const Map<String, String> _assignmentSwaps = <String, String>{
  '+=': '-=',
  '-=': '+=',
  '*=': '/=',
  '/=': '*=',
  '++': '--',
  '--': '++',
};

/// Generates every mutant for one file.
List<Mutant> generateForFile(String path, String src) {
  final List<Tok> toks = scan(src);
  final List<int> lineStarts = _lineStarts(src);
  final Set<int> genericAngles = _genericAngleTokens(toks, src);

  // Raw edits, before ids and de-duplication.
  final List<_Edit> edits = <_Edit>[];

  void add(int start, int end, String replacement, MutOp op) {
    final String original = src.substring(start, end);
    // Never emit a "mutant" that is textually the original. That is not a
    // weakened operator set — an edit that changes nothing is not a mutation,
    // and counting it as a kill or a survivor would both be lies.
    if (original == replacement) {
      return;
    }
    edits.add(_Edit(start, end, replacement, op));
  }

  for (int k = 0; k < toks.length; k++) {
    final Tok t = toks[k];

    // ---- relational -------------------------------------------------------
    if (t.kind == TokKind.op &&
        _relationalSwaps.containsKey(t.text) &&
        !genericAngles.contains(t.start)) {
      for (final String rep in _relationalSwaps[t.text]!) {
        add(t.start, t.end, rep, MutOp.relational);
      }
    }

    // ---- arithmetic (binary only) ----------------------------------------
    if (t.kind == TokKind.op && _arithmeticSwaps.containsKey(t.text)) {
      final Tok? prev = k > 0 ? toks[k - 1] : null;
      final bool unary = prev == null || _prefixContexts.contains(prev.text);
      if (!unary) {
        for (final String rep in _arithmeticSwaps[t.text]!) {
          add(t.start, t.end, rep, MutOp.arithmetic);
        }
      }
    }

    // ---- boolean: && <-> || ----------------------------------------------
    if (t.kind == TokKind.op && _booleanSwaps.containsKey(t.text)) {
      add(t.start, t.end, _booleanSwaps[t.text]!, MutOp.boolean);
    }

    // ---- boolean: drop a unary `!` ---------------------------------------
    // `if (!obstacle.scored && ...)` becomes `if (obstacle.scored && ...)`.
    // That flag is the only thing stopping one pipe scoring on 33 consecutive
    // frames, so this is a mutant with real teeth.
    if (t.kind == TokKind.op && t.text == '!') {
      final Tok? prev = k > 0 ? toks[k - 1] : null;
      final bool unary = prev == null || _prefixContexts.contains(prev.text);
      if (unary) {
        add(t.start, t.end, '', MutOp.boolean);
      }
    }

    // ---- boolean: negate an if/while condition ---------------------------
    if (t.kind == TokKind.word && (t.text == 'if' || t.text == 'while')) {
      if (k + 1 < toks.length && toks[k + 1].text == '(') {
        final int close = _matchBracket(toks, k + 1, '(', ')');
        if (close > k + 1) {
          final int condStart = toks[k + 2].start;
          final int condEnd = toks[close - 1].end;
          final String cond = src.substring(condStart, condEnd);
          add(condStart, condEnd, '!($cond)', MutOp.boolean);
        }
      }
    }

    // ---- assignment ------------------------------------------------------
    if (t.kind == TokKind.op && _assignmentSwaps.containsKey(t.text)) {
      add(t.start, t.end, _assignmentSwaps[t.text]!, MutOp.assignment);
    }

    // ---- constants: numeric literals -------------------------------------
    if (t.kind == TokKind.number) {
      final _Num num = _parseNum(t.text);

      // -> 0. Skipped when the literal is already zero: replacing `0` with `0`
      // is not an edit.
      add(t.start, t.end, num.isDouble ? '0.0' : '0', MutOp.constant);

      // -> -x. Parenthesised so it composes safely: the source `-0.72` becomes
      // `-(-(0.72))`, which parses, rather than `--0.72`, which lexes as a
      // decrement and does not.
      //
      // Skipped for an INT zero only, because `-0` and `0` are the same int:
      // the source would differ and the program would not, so it is a no-op
      // edit rather than a mutant. Double zero is kept — `-0.0` really is a
      // different double, and if nothing can tell it apart that is an
      // equivalence to be argued, not assumed.
      if (!(num.value == 0 && !num.isDouble)) {
        add(t.start, t.end, '(-(${t.text}))', MutOp.constant);
      }

      // -> x + one meaningful step. Ten percent of the literal's own magnitude,
      // so the step scales with what it is perturbing: gravity 2.2 becomes
      // 2.42, an obstacle width 0.16 becomes 0.176. A fixed step would be
      // invisible against 4294967296 and catastrophic against 0.031, and
      // neither extreme tests anything useful.
      add(t.start, t.end, '(${t.text} + ${num.step})', MutOp.constant);
    }

    // ---- constants: named const initialisers ------------------------------
    // Catches the ones with no literal of their own to perturb, such as
    // `static const double minY = playfieldTop;` and
    // `static const double carWidth = carHeight * referenceAspect * ...;`.
    // Where the initialiser IS a single literal the edit is identical to the
    // one above and is removed by de-duplication.
    if (t.kind == TokKind.word && t.text == 'const') {
      final _ConstDecl? decl = _readConstDecl(toks, k, src);
      if (decl != null) {
        final String zero = decl.type == 'int' ? '0' : '0.0';
        final String step = decl.type == 'int' ? '1' : '0.1';
        add(decl.exprStart, decl.exprEnd, zero, MutOp.constant);
        add(
          decl.exprStart,
          decl.exprEnd,
          '(-(${decl.expr}))',
          MutOp.constant,
        );
        add(
          decl.exprStart,
          decl.exprEnd,
          '(${decl.expr} + $step)',
          MutOp.constant,
        );
      }
    }
  }

  // ---- returns: force every bool result to true and to false --------------
  for (final _BoolBody body in _boolReturnExpressions(toks, src)) {
    add(body.start, body.end, 'true', MutOp.returns);
    add(body.start, body.end, 'false', MutOp.returns);
  }

  // De-duplicate on the exact edit. Two operators can propose the same source
  // change (a const initialiser that is one literal, most obviously) and
  // running it twice would double-count both the work and the score.
  final Map<String, _Edit> unique = <String, _Edit>{};
  for (final _Edit e in edits) {
    unique.putIfAbsent('${e.start}:${e.end}:${e.replacement}', () => e);
  }

  final List<_Edit> sorted = unique.values.toList()
    ..sort((_Edit a, _Edit b) {
      final int byStart = a.start.compareTo(b.start);
      return byStart != 0 ? byStart : a.replacement.compareTo(b.replacement);
    });

  final List<Mutant> out = <Mutant>[];
  for (final _Edit e in sorted) {
    final ({int line, int column}) pos = _lineCol(lineStarts, e.start);
    out.add(
      Mutant(
        id: '', // assigned after all files are generated
        file: path,
        offset: e.start,
        length: e.end - e.start,
        original: src.substring(e.start, e.end),
        replacement: e.replacement,
        op: e.op,
        line: pos.line,
        column: pos.column,
      ),
    );
  }
  return out;
}

class _Edit {
  _Edit(this.start, this.end, this.replacement, this.op);

  final int start;
  final int end;
  final String replacement;
  final MutOp op;
}

class _Num {
  _Num(this.value, this.isDouble, this.step);

  final double value;
  final bool isDouble;
  final String step;
}

_Num _parseNum(String text) {
  if (text.startsWith('0x') || text.startsWith('0X')) {
    final int v = int.parse(text.substring(2), radix: 16);
    return _Num(v.toDouble(), false, '1');
  }
  final bool isDouble = text.contains('.') || text.contains('e') || text.contains('E');
  final double v = double.parse(text);
  if (!isDouble) {
    return _Num(v, false, '1');
  }
  final double magnitude = v == 0 ? 1.0 : v.abs();
  // Ten percent of the magnitude, trimmed of float noise so the generated
  // source reads as a number a person would have typed.
  final double step = double.parse((magnitude * 0.1).toStringAsPrecision(3));
  return _Num(v, true, step.toString());
}

class _ConstDecl {
  _ConstDecl(this.type, this.expr, this.exprStart, this.exprEnd);

  final String type;
  final String expr;
  final int exprStart;
  final int exprEnd;
}

/// Reads `const <type> <name> = <expr>;` starting at the `const` token [k].
/// Returns null for anything else — `const GameModel.ready(...)`,
/// `const <Obstacle>[]`, a const constructor — none of which have an
/// initialiser to perturb.
_ConstDecl? _readConstDecl(List<Tok> toks, int k, String src) {
  const Set<String> scalarTypes = <String>{'double', 'int', 'bool'};
  int j = k + 1;
  if (j >= toks.length || !scalarTypes.contains(toks[j].text)) {
    return null;
  }
  final String type = toks[j].text;
  j++;
  if (j >= toks.length || toks[j].kind != TokKind.word) {
    return null;
  }
  j++;
  if (j >= toks.length || toks[j].text != '=') {
    return null;
  }
  j++;
  if (j >= toks.length) {
    return null;
  }
  final int exprStart = toks[j].start;
  int depth = 0;
  while (j < toks.length) {
    final String s = toks[j].text;
    if (s == '(' || s == '[' || s == '{') {
      depth++;
    } else if (s == ')' || s == ']' || s == '}') {
      depth--;
    } else if (s == ';' && depth == 0) {
      final int exprEnd = toks[j - 1].end;
      return _ConstDecl(type, src.substring(exprStart, exprEnd), exprStart, exprEnd);
    }
    j++;
  }
  return null;
}

class _BoolBody {
  _BoolBody(this.start, this.end);

  final int start;
  final int end;
}

/// Finds every expression whose value becomes the `bool` result of a
/// bool-returning member: the right-hand side of an `=>` body, and every
/// `return <expr>;` inside a `{ ... }` body.
///
/// WHY THIS OPERATOR MATTERS MORE THAN IT LOOKS: `Box.overlaps` is the whole of
/// collision detection, and `_hitsAnyObstacle` is the whole of "did the car
/// crash". Forcing either to a constant is the crudest possible break, so a
/// suite that does not catch it is not testing collision at all — it is
/// testing that the car falls.
List<_BoolBody> _boolReturnExpressions(List<Tok> toks, String src) {
  final List<_BoolBody> out = <_BoolBody>[];

  for (int k = 0; k < toks.length; k++) {
    if (toks[k].kind != TokKind.word || toks[k].text != 'bool') {
      continue;
    }
    int j = k + 1;
    if (j >= toks.length) {
      continue;
    }

    if (toks[j].text == 'operator') {
      j += 2; // `operator` then the operator symbol itself
    } else if (toks[j].text == 'get') {
      j += 2; // `get` then the getter name
    } else {
      j += 1; // the method name
    }
    if (j >= toks.length) {
      continue;
    }

    // Optional parameter list. A `bool` that is a FIELD or a parameter type
    // (`final bool scored;`) reaches here with `;` or `,` next and is skipped,
    // which is the point of this guard.
    if (toks[j].text == '(') {
      final int close = _matchBracket(toks, j, '(', ')');
      if (close < 0) {
        continue;
      }
      j = close + 1;
    }
    if (j >= toks.length) {
      continue;
    }

    if (toks[j].text == '=>') {
      final int end = _findSemicolon(toks, j + 1);
      if (end > j + 1) {
        out.add(_BoolBody(toks[j + 1].start, toks[end - 1].end));
      }
    } else if (toks[j].text == '{') {
      final int close = _matchBracket(toks, j, '{', '}');
      if (close < 0) {
        continue;
      }
      for (int m = j + 1; m < close; m++) {
        if (toks[m].kind == TokKind.word && toks[m].text == 'return') {
          final int end = _findSemicolon(toks, m + 1);
          if (end > m + 1) {
            out.add(_BoolBody(toks[m + 1].start, toks[end - 1].end));
          }
        }
      }
    }
  }

  return out;
}

/// Index of the `;` that ends the expression starting at [from], ignoring any
/// `;` nested inside brackets.
int _findSemicolon(List<Tok> toks, int from) {
  int depth = 0;
  for (int j = from; j < toks.length; j++) {
    final String s = toks[j].text;
    if (s == '(' || s == '[' || s == '{') {
      depth++;
    } else if (s == ')' || s == ']' || s == '}') {
      depth--;
    } else if (s == ';' && depth == 0) {
      return j;
    }
  }
  return -1;
}

int _matchBracket(List<Tok> toks, int open, String openText, String closeText) {
  int depth = 0;
  for (int j = open; j < toks.length; j++) {
    if (toks[j].text == openText) {
      depth++;
    } else if (toks[j].text == closeText) {
      depth--;
      if (depth == 0) {
        return j;
      }
    }
  }
  return -1;
}

/// Offsets of `<` and `>` tokens that open or close a TYPE ARGUMENT list, so
/// the relational operator leaves them alone.
///
/// WHY THIS EXISTS: `List<Obstacle>` and `x < y` share a character. Mutating
/// the first gives `List<=Obstacle>`, which is not a program — it would be
/// counted as invalid and cost a full compile to discover, dozens of times over.
/// Suppressing them up front keeps the invalid count meaningful: what remains
/// there is a genuine type error the mutation exposed, not a known false start.
///
/// The rule is deliberately narrow — a `<` is a type argument list only when
/// the very next thing is an upper-case identifier — because every generic in
/// `lib/game/` is `List<Obstacle>` or `<Obstacle>[]` and a broader rule would
/// start swallowing real comparisons.
Set<int> _genericAngleTokens(List<Tok> toks, String src) {
  final Set<int> out = <int>{};
  for (int k = 0; k < toks.length; k++) {
    if (toks[k].text != '<' || toks[k].kind != TokKind.op) {
      continue;
    }
    final Tok? next = k + 1 < toks.length ? toks[k + 1] : null;
    if (next == null || next.kind != TokKind.word) {
      continue;
    }
    final int first = next.text.codeUnitAt(0);
    if (first < 0x41 || first > 0x5A) {
      continue; // not an upper-case type name
    }
    final int close = _matchBracket(toks, k, '<', '>');
    if (close < 0) {
      continue;
    }
    out.add(toks[k].start);
    out.add(toks[close].start);
  }
  return out;
}

List<int> _lineStarts(String src) {
  final List<int> starts = <int>[0];
  for (int i = 0; i < src.length; i++) {
    if (src.codeUnitAt(i) == 0x0A) {
      starts.add(i + 1);
    }
  }
  return starts;
}

({int line, int column}) _lineCol(List<int> starts, int offset) {
  int lo = 0;
  int hi = starts.length - 1;
  while (lo < hi) {
    final int mid = (lo + hi + 1) ~/ 2;
    if (starts[mid] <= offset) {
      lo = mid;
    } else {
      hi = mid - 1;
    }
  }
  return (line: lo + 1, column: offset - starts[lo] + 1);
}

// =============================================================================
// Test running
// =============================================================================

class TestRun {
  TestRun(this.verdict, this.detail, this.elapsed);

  final Verdict verdict;
  final String detail;
  final Duration elapsed;
}

/// Runs `flutter test` over [testPaths] (empty means the whole suite) and
/// classifies the result.
///
/// THE CLASSIFIER IS THE PART THAT COULD LIE, so it is written to fail loudly
/// rather than default to a flattering answer. The compile check comes FIRST:
/// a mutant that does not build produces test output that superficially looks
/// like a failure, and reading it as one would quietly convert every unbuildable
/// mutant into a free kill.
Future<TestRun> runTests(
  String flutterCmd,
  String repoRoot,
  List<String> testPaths,
  Duration timeout,
) async {
  final Stopwatch sw = Stopwatch()..start();
  final Process proc = await Process.start(
    flutterCmd,
    <String>['test', '--no-pub', '--reporter=compact', ...testPaths],
    workingDirectory: repoRoot,
    runInShell: true,
  );

  final StringBuffer buf = StringBuffer();
  final Future<void> outDone =
      proc.stdout.transform(utf8.decoder).forEach(buf.write);
  final Future<void> errDone =
      proc.stderr.transform(utf8.decoder).forEach(buf.write);

  int? exitCode;
  bool timedOut = false;
  try {
    exitCode = await proc.exitCode.timeout(timeout);
    await Future.wait(<Future<void>>[outDone, errDone]);
  } on TimeoutException {
    timedOut = true;
    proc.kill(ProcessSignal.sigkill);
    // Do not await the stream drains here: the child may have grandchildren
    // holding the pipe open, and waiting on them would hang the very run the
    // timeout exists to unblock.
  }
  sw.stop();

  final String output = buf.toString();

  if (timedOut) {
    return TestRun(
      Verdict.killedByTimeout,
      'no result within ${timeout.inSeconds}s',
      sw.elapsed,
    );
  }

  // Compile failure. Checked before anything else — see the doc comment.
  if (output.contains('Compilation failed for testPath=') ||
      output.contains('Error: The Dart compiler exited unexpectedly') ||
      (output.contains('Failed to load "') && output.contains(': Error: '))) {
    return TestRun(Verdict.invalid, _firstCompilerError(output), sw.elapsed);
  }

  if (exitCode == 0 && output.contains('All tests passed!')) {
    return TestRun(Verdict.survived, '', sw.elapsed);
  }

  if (output.contains('Some tests failed.') || (exitCode ?? 1) != 0) {
    return TestRun(Verdict.killed, _firstFailure(output), sw.elapsed);
  }

  // Neither shape. Refusing to guess is the point: an unrecognised outcome
  // silently filed as a kill is exactly how a mutation score stops meaning
  // anything.
  return TestRun(
    Verdict.invalid,
    'UNRECOGNISED test output (exit $exitCode)',
    sw.elapsed,
  );
}

String _firstCompilerError(String output) {
  for (final String line in const LineSplitter().convert(output)) {
    if (line.contains(': Error: ')) {
      return line.trim();
    }
  }
  return 'compilation failed';
}

String _firstFailure(String output) {
  for (final String line in const LineSplitter().convert(output)) {
    if (line.contains('[E]')) {
      return line.trim();
    }
  }
  return 'tests failed';
}

// =============================================================================
// SHA-256, so "the source was restored" is a fact and not a hope
// =============================================================================

/// Minimal SHA-256. Written out rather than pulled from a package because
/// `pubspec.yaml` is off limits for this task and adding a dependency to
/// verify a restore would be a strange trade.
String sha256Hex(List<int> data) {
  const List<int> k = <int>[
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1,
    0x923f82a4, 0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
    0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786,
    0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147,
    0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
    0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b,
    0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a,
    0x5b9cca4f, 0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
    0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
  ];

  final Uint32List h = Uint32List.fromList(<int>[
    0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
    0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
  ]);

  final int bitLen = data.length * 8;
  final List<int> msg = <int>[...data, 0x80];
  while (msg.length % 64 != 56) {
    msg.add(0);
  }
  for (int i = 7; i >= 0; i--) {
    msg.add((bitLen >> (8 * i)) & 0xFF);
  }

  int rotr(int x, int n) => ((x >> n) | (x << (32 - n))) & 0xFFFFFFFF;

  final Uint32List w = Uint32List(64);
  for (int chunk = 0; chunk < msg.length; chunk += 64) {
    for (int i = 0; i < 16; i++) {
      w[i] = (msg[chunk + i * 4] << 24) |
          (msg[chunk + i * 4 + 1] << 16) |
          (msg[chunk + i * 4 + 2] << 8) |
          msg[chunk + i * 4 + 3];
    }
    for (int i = 16; i < 64; i++) {
      final int s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3);
      final int s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10);
      w[i] = (w[i - 16] + s0 + w[i - 7] + s1) & 0xFFFFFFFF;
    }

    int a = h[0];
    int b = h[1];
    int c = h[2];
    int d = h[3];
    int e = h[4];
    int f = h[5];
    int g = h[6];
    int hh = h[7];

    for (int i = 0; i < 64; i++) {
      final int s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25);
      final int ch = (e & f) ^ ((~e & 0xFFFFFFFF) & g);
      final int t1 = (hh + s1 + ch + k[i] + w[i]) & 0xFFFFFFFF;
      final int s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22);
      final int maj = (a & b) ^ (a & c) ^ (b & c);
      final int t2 = (s0 + maj) & 0xFFFFFFFF;
      hh = g;
      g = f;
      f = e;
      e = (d + t1) & 0xFFFFFFFF;
      d = c;
      c = b;
      b = a;
      a = (t1 + t2) & 0xFFFFFFFF;
    }

    h[0] = (h[0] + a) & 0xFFFFFFFF;
    h[1] = (h[1] + b) & 0xFFFFFFFF;
    h[2] = (h[2] + c) & 0xFFFFFFFF;
    h[3] = (h[3] + d) & 0xFFFFFFFF;
    h[4] = (h[4] + e) & 0xFFFFFFFF;
    h[5] = (h[5] + f) & 0xFFFFFFFF;
    h[6] = (h[6] + g) & 0xFFFFFFFF;
    h[7] = (h[7] + hh) & 0xFFFFFFFF;
  }

  return h.map((int v) => v.toRadixString(16).padLeft(8, '0')).join();
}

// =============================================================================
// Entry point
// =============================================================================

/// Exit status: 0 clean, 1 survivors (or a failed self-test), 2 the tool itself
/// could not do its job.
///
/// WHY THIS IS SET RATHER THAN RETURNED: Dart uses a `main` return value as the
/// process exit code only for a SYNCHRONOUS `int main()`. An async main's
/// returned future is awaited and its value discarded, so `return 1` here would
/// exit 0 — and a CI job wired to `--quick` would go green over a survivor. The
/// helper below makes that impossible to forget.
Future<int> main(List<String> args) async {
  final int status = await _run(args);
  exitCode = status;
  return status;
}

Future<int> _run(List<String> args) async {
  final Map<String, String> opts = _parseArgs(args);

  final String repoRoot = opts['root'] ?? Directory.current.path;
  final String flutterCmd = _resolveFlutter(opts['flutter']);
  final Duration timeout = Duration(
    seconds: int.parse(opts['timeout'] ?? '${defaultTimeout.inSeconds}'),
  );
  final bool quick = opts.containsKey('quick');
  final bool listOnly = opts.containsKey('list');
  final bool selftest = opts.containsKey('selftest');
  final Set<String>? only = opts['only']?.split(',').toSet();

  // ---- read the originals, once, as bytes --------------------------------
  final Map<String, Uint8List> originalBytes = <String, Uint8List>{};
  final Map<String, String> originalText = <String, String>{};
  final Map<String, String> originalHash = <String, String>{};
  for (final String rel in targetFiles) {
    final File f = File('$repoRoot/$rel');
    if (!f.existsSync()) {
      stdout.writeln('FATAL: $rel not found under $repoRoot');
      return 2;
    }
    final Uint8List bytes = f.readAsBytesSync();
    originalBytes[rel] = bytes;
    originalText[rel] = utf8.decode(bytes);
    originalHash[rel] = sha256Hex(bytes);
  }

  void restoreAll() {
    for (final String rel in targetFiles) {
      _writeWithRetry(File('$repoRoot/$rel'), originalBytes[rel]!);
    }
  }

  // A mutated file on disk is the one genuinely dangerous thing this tool does.
  // Ctrl-C during a test run would otherwise leave `lib/game/` broken and the
  // next person staring at a compile error with no idea why.
  late StreamSubscription<ProcessSignal> sigint;
  sigint = ProcessSignal.sigint.watch().listen((_) {
    restoreAll();
    stdout.writeln('\ninterrupted — lib/game restored');
    exit(130);
  });

  try {
    // ---- generate -------------------------------------------------------
    final List<Mutant> all = <Mutant>[];
    final Map<MutOp, int> counters = <MutOp, int>{};
    for (final String rel in targetFiles) {
      for (final Mutant m in generateForFile(rel, originalText[rel]!)) {
        final int n = (counters[m.op] ?? 0) + 1;
        counters[m.op] = n;
        all.add(
          Mutant(
            id: '${m.op.tag}${n.toString().padLeft(3, '0')}',
            file: m.file,
            offset: m.offset,
            length: m.length,
            original: m.original,
            replacement: m.replacement,
            op: m.op,
            line: m.line,
            column: m.column,
          ),
        );
      }
    }

    _printHeader(all, quick, timeout, int.parse(opts['jobs'] ?? '1'));

    if (listOnly) {
      for (final Mutant m in all) {
        stdout.writeln('${m.id.padRight(8)}${m.describe()}');
      }
      return 0;
    }

    if (selftest) {
      final bool ok = await _runSelfTest(
        flutterCmd,
        repoRoot,
        originalText,
        restoreAll,
        timeout,
      );
      return ok ? 0 : 1;
    }

    // ---- select ---------------------------------------------------------
    List<Mutant> selected = all;
    if (only != null) {
      selected = all.where((Mutant m) => only.contains(m.id)).toList();
      if (selected.isEmpty) {
        stdout.writeln('FATAL: --only matched no mutants');
        return 2;
      }
    } else if (quick) {
      selected = quickSubset(all);
    }

    // ---- validate the equivalence table against the real source ----------
    // A table entry that no longer matches the code would silently exclude the
    // wrong mutant, which is the one failure mode of this tool that RAISES the
    // score. Abort rather than guess.
    final Map<String, KnownEquivalent> equivalents = <String, KnownEquivalent>{};
    for (final KnownEquivalent e in knownEquivalents) {
      final Iterable<Mutant> match = all.where(
        (Mutant m) =>
            m.file == e.file &&
            m.line == e.line &&
            m.original == e.original &&
            m.replacement == e.replacement,
      );
      if (match.isEmpty) {
        stdout.writeln(
          'FATAL: equivalence table is stale — no mutant matches '
          '${e.file}:${e.line} ${e.original} -> ${e.replacement}',
        );
        return 2;
      }
      equivalents[match.first.id] = e;
    }

    // ---- run ------------------------------------------------------------
    final int jobs = int.parse(opts['jobs'] ?? '1');
    final Stopwatch wall = Stopwatch()..start();

    // Equivalents never run: no test can kill them, so spending a compile on
    // one would only be theatre.
    final List<MutantResult> results = <MutantResult>[];
    final List<Mutant> toRun = <Mutant>[];
    for (final Mutant m in selected) {
      if (equivalents.containsKey(m.id)) {
        results.add(
          MutantResult(m, Verdict.equivalent, Duration.zero, 'argued equivalent'),
        );
      } else {
        toRun.add(m);
      }
    }

    final List<String> roots = <String>[];
    if (jobs > 1) {
      stdout.writeln('preparing $jobs sandboxes (the repository itself is not '
          'mutated in this mode)...');
      for (int i = 0; i < jobs; i++) {
        roots.add(_makeSandbox(repoRoot, i));
      }
    } else {
      roots.add(repoRoot);
    }

    int nextIndex = 0;
    int done = 0;
    Future<void> worker(String root) async {
      while (true) {
        final int i = nextIndex++;
        if (i >= toRun.length) {
          return;
        }
        final Mutant m = toRun[i];
        final MutantResult r = await _judge(
          flutterCmd,
          root,
          m,
          originalText,
          originalBytes,
          timeout,
        );
        results.add(r);
        done++;
        stdout.writeln(
          '[${done.toString().padLeft(4)}/${toRun.length}] '
          '${m.id.padRight(8)}${_verdictLabel(r.verdict).padRight(12)}'
          '${m.describe()}',
        );
      }
    }

    await Future.wait(roots.map(worker));
    wall.stop();

    // ---- verify every tree is exactly as we found it ---------------------
    // Including the sandboxes: a worker that failed to restore its own copy
    // would have judged every later mutant against two mutations at once, and
    // the results after that point would be silently wrong.
    final Map<String, String> finalHash = <String, String>{};
    bool restored = true;
    for (final String root in <String>[repoRoot, ...roots.where((String r) => r != repoRoot)]) {
      for (final String rel in targetFiles) {
        final String h = sha256Hex(File('$root/$rel').readAsBytesSync());
        if (root == repoRoot) {
          finalHash[rel] = h;
        }
        if (h != originalHash[rel]) {
          restored = false;
          stdout.writeln('RESTORE FAILURE in $root/$rel');
        }
      }
    }

    for (final String root in roots) {
      if (root != repoRoot) {
        Directory(root).deleteSync(recursive: true);
      }
    }

    results.sort((MutantResult a, MutantResult b) =>
        a.mutant.id.compareTo(b.mutant.id));

    _printReport(
      selected: selected,
      results: results,
      equivalents: equivalents,
      originalHash: originalHash,
      finalHash: finalHash,
      restored: restored,
      wall: wall.elapsed,
      quick: quick,
    );

    if (!restored) {
      return 2;
    }
    final int survivors =
        results.where((MutantResult r) => r.verdict == Verdict.survived).length;
    return survivors == 0 ? 0 : 1;
  } finally {
    restoreAll();
    await sigint.cancel();
  }
}

/// Applies one mutant under [root], runs the tiered suite, restores, and
/// returns the verdict.
Future<MutantResult> _judge(
  String flutterCmd,
  String root,
  Mutant m,
  Map<String, String> originalText,
  Map<String, Uint8List> originalBytes,
  Duration timeout,
) async {
  _applyMutant(root, m, originalText[m.file]!);
  TestRun run = await runTests(flutterCmd, root, tier1Tests, timeout);

  // Escalation: tier 1 passing is not proof, because tier 1 is a subset of the
  // suite. Re-run everything before calling anything a survivor.
  if (run.verdict == Verdict.survived) {
    final TestRun full = await runTests(flutterCmd, root, tier2Tests, timeout);
    run = TestRun(full.verdict, full.detail, run.elapsed + full.elapsed);
  }

  for (final String rel in targetFiles) {
    _writeWithRetry(File('$root/$rel'), originalBytes[rel]!);
  }
  return MutantResult(m, run.verdict, run.elapsed, run.detail);
}

/// Creates worker sandbox [i]: a minimal copy of the package that `flutter
/// test` can run in, with its own `lib/game/` for this worker to break.
String _makeSandbox(String repoRoot, int i) {
  final Directory dir =
      Directory('${Directory.systemTemp.path}/flappymiata_mutate_$i');
  if (dir.existsSync()) {
    dir.deleteSync(recursive: true);
  }
  dir.createSync(recursive: true);

  for (final String rel in sandboxFiles) {
    final File src = File('$repoRoot/$rel');
    if (!src.existsSync()) {
      continue;
    }
    final File dst = File('${dir.path}/$rel');
    dst.parent.createSync(recursive: true);
    dst.writeAsBytesSync(src.readAsBytesSync());
  }
  for (final String rel in sandboxDirs) {
    final Directory src = Directory('$repoRoot/$rel');
    if (!src.existsSync()) {
      continue;
    }
    for (final FileSystemEntity e in src.listSync(recursive: true)) {
      if (e is! File) {
        continue;
      }
      final String relPath =
          e.path.substring(repoRoot.length + 1).replaceAll(r'\', '/');
      final File dst = File('${dir.path}/$relPath');
      dst.parent.createSync(recursive: true);
      dst.writeAsBytesSync(e.readAsBytesSync());
    }
  }
  return dir.path;
}

void _applyMutant(String repoRoot, Mutant m, String original) {
  final String mutated = original.substring(0, m.offset) +
      m.replacement +
      original.substring(m.offset + m.length);
  _writeWithRetry(File('$repoRoot/${m.file}'), utf8.encode(mutated));
}

/// Writes [bytes] to [file], retrying briefly on a sharing violation.
///
/// WHY THIS RETRY EXISTS AND IS NOT PARANOIA: on Windows an indexer, a virus
/// scanner or another tool reading the file holds an exclusive-ish handle for a
/// few milliseconds, and the write throws. This tool's one dangerous moment is
/// the instant `lib/game/` is mutated, so a failed RESTORE is the worst thing
/// it can do — it would leave the repository broken and blame nothing. A short
/// retry turns a transient collision into a pause instead of a wreck; a
/// persistent one still throws, which is what should happen.
void _writeWithRetry(File file, List<int> bytes) {
  Object? last;
  for (int attempt = 0; attempt < 40; attempt++) {
    try {
      file.writeAsBytesSync(bytes, flush: true);
      return;
    } on FileSystemException catch (e) {
      last = e;
      sleepMillis(25);
    }
  }
  throw StateError('could not write ${file.path} after 40 attempts: $last');
}

/// Blocking sleep. `dart:io` has no synchronous sleep, and this runs inside a
/// retry loop that must not yield to the event loop — a half-restored file is
/// exactly the state no other code should get to observe.
void sleepMillis(int ms) {
  final Stopwatch sw = Stopwatch()..start();
  while (sw.elapsedMilliseconds < ms) {
    // Busy wait. 25ms at a time, at most 40 times, only on a real collision.
  }
}

String _verdictLabel(Verdict v) => switch (v) {
      Verdict.killed => 'KILLED',
      Verdict.killedByTimeout => 'KILLED(t/o)',
      Verdict.survived => 'SURVIVED',
      Verdict.invalid => 'INVALID',
      Verdict.equivalent => 'EQUIVALENT',
    };

// =============================================================================
// --quick
// =============================================================================

/// The CI subset, stated precisely because "a subset" that nobody can reproduce
/// is not a gate.
///
/// THE RULE: within each operator family, sorted by file then source offset,
/// take every k-th mutant where k is chosen so the family contributes
/// `ceil(size / 8)` mutants, with a floor of 2 (or the whole family if it has
/// fewer than 2). Selection is by index arithmetic only — no randomness, no
/// clock — so the same commit always yields the same subset, and a CI failure
/// can be reproduced locally with `--only=<id>`.
///
/// WHY STRATIFIED RATHER THAN "THE FIRST N": every operator family stays
/// represented. A subset that happened to be all constant mutants would go
/// green while the relational operator was completely broken, and a gate that
/// cannot fail for a whole class of defect is not a gate.
///
/// WHAT IT IS AND IS NOT FOR: it is a smoke test that the tool still applies
/// mutants and the suite still kills them. Its pass rate is NOT the mutation
/// score, and the report says so.
List<Mutant> quickSubset(List<Mutant> all) {
  final List<Mutant> out = <Mutant>[];
  for (final MutOp op in MutOp.values) {
    final List<Mutant> family = all.where((Mutant m) => m.op == op).toList();
    if (family.isEmpty) {
      continue;
    }
    final int want = family.length <= 2 ? family.length : _max(2, (family.length + 7) ~/ 8);
    // Evenly spaced indices across the family, endpoints included.
    for (int i = 0; i < want; i++) {
      final int idx = want == 1 ? 0 : (i * (family.length - 1)) ~/ (want - 1);
      final Mutant m = family[idx];
      if (!out.contains(m)) {
        out.add(m);
      }
    }
  }
  return out;
}

int _max(int a, int b) => a > b ? a : b;

// =============================================================================
// --selftest  (Part 3: prove the tool is capable of every verdict)
// =============================================================================

/// Three controls, because a tool that can only say one thing says nothing.
///
/// A mutation harness that reports 100% because its mutants never reached the
/// disk looks exactly like a perfect test suite. The difference is only visible
/// if you can show the machinery producing each verdict ON DEMAND:
///
///   POSITIVE — an obviously fatal edit (gravity x10) must come back KILLED.
///   NEGATIVE — the SAME edit, judged by a test file that cannot observe the
///              model, must come back SURVIVED. This is the control that rules
///              out "always reports killed", and it is the one people leave out.
///   INVALID  — a syntactically broken edit must come back INVALID and must NOT
///              be counted as a kill.
///
/// The negative control uses `test/widget_test.dart`, which asserts only that
/// `main.dart` hands Flutter a `GameWidget`. It never ticks the model, so no
/// change to `lib/game/` can make it fail — which is exactly what makes it a
/// valid negative control rather than a rigged one.
Future<bool> _runSelfTest(
  String flutterCmd,
  String repoRoot,
  Map<String, String> originalText,
  void Function() restoreAll,
  Duration timeout,
) async {
  const String file = 'lib/game/game_model.dart';
  const String gravityDecl = 'static const double gravity = 2.2;';
  const String gravityBroken = 'static const double gravity = 22.0;';
  const String syntaxBroken = 'static const double gravity = 2.2 &&&;';

  final String src = originalText[file]!;
  if (!src.contains(gravityDecl)) {
    stdout.writeln('FATAL: selftest anchor not found: $gravityDecl');
    return false;
  }

  Future<TestRun> withSource(String replacement, List<String> tests) async {
    File('$repoRoot/$file')
        .writeAsStringSync(src.replaceFirst(gravityDecl, replacement), flush: true);
    final TestRun r = await runTests(flutterCmd, repoRoot, tests, timeout);
    restoreAll();
    return r;
  }

  stdout.writeln('');
  stdout.writeln('=== SELF-TEST: can the tool produce all three verdicts? ===');
  stdout.writeln('');

  final TestRun positive = await withSource(gravityBroken, tier1Tests);
  stdout.writeln(
    'POSITIVE  gravity 2.2 -> 22.0, judged by tier 1        '
    '=> ${_verdictLabel(positive.verdict)}   (want KILLED)',
  );
  if (positive.detail.isNotEmpty) {
    stdout.writeln('          ${positive.detail}');
  }

  final TestRun negative =
      await withSource(gravityBroken, <String>['test/widget_test.dart']);
  stdout.writeln(
    'NEGATIVE  the same edit, judged by widget_test only    '
    '=> ${_verdictLabel(negative.verdict)}   (want SURVIVED)',
  );

  final TestRun invalid = await withSource(syntaxBroken, tier1Tests);
  stdout.writeln(
    'INVALID   `2.2 &&&`, judged by tier 1                  '
    '=> ${_verdictLabel(invalid.verdict)}    (want INVALID)',
  );
  if (invalid.detail.isNotEmpty) {
    stdout.writeln('          ${invalid.detail}');
  }

  final bool ok = positive.verdict == Verdict.killed &&
      negative.verdict == Verdict.survived &&
      invalid.verdict == Verdict.invalid;

  stdout.writeln('');
  stdout.writeln(ok
      ? 'SELF-TEST PASSED — the classifier is capable of all three verdicts, so '
          'a KILLED is a real observation and not a default.'
      : 'SELF-TEST FAILED — do not trust any score this tool prints.');
  return ok;
}

// =============================================================================
// Reporting
// =============================================================================

void _printHeader(List<Mutant> all, bool quick, Duration timeout, int jobs) {
  stdout.writeln('mutate.dart — mutation testing for lib/game/');
  stdout.writeln('');
  stdout.writeln('targets:');
  for (final String f in targetFiles) {
    final int n = all.where((Mutant m) => m.file == f).length;
    stdout.writeln('  $f  ($n mutants)');
  }
  stdout.writeln('');
  stdout.writeln('operator set:');
  for (final MutOp op in MutOp.values) {
    final int n = all.where((Mutant m) => m.op == op).length;
    stdout.writeln('  ${op.tag}  ${n.toString().padLeft(4)}  ${op.description}');
  }
  stdout.writeln('');
  stdout.writeln('tier 1 (every mutant):   flutter test ${tier1Tests.join(' ')}');
  stdout.writeln('tier 2 (survivors only): flutter test        [whole suite]');
  stdout.writeln('timeout: ${timeout.inSeconds}s per run');
  stdout.writeln(jobs > 1
      ? 'jobs: $jobs sandboxed workers (the repo copy of lib/game is never '
          'written to in this mode)'
      : 'jobs: 1 (mutating lib/game in place, restored after every mutant)');
  if (quick) {
    stdout.writeln('mode: --quick (stratified CI subset; NOT the mutation score)');
  }
  stdout.writeln('');
}

void _printReport({
  required List<Mutant> selected,
  required List<MutantResult> results,
  required Map<String, KnownEquivalent> equivalents,
  required Map<String, String> originalHash,
  required Map<String, String> finalHash,
  required bool restored,
  required Duration wall,
  required bool quick,
}) {
  int count(Verdict v) =>
      results.where((MutantResult r) => r.verdict == v).length;

  final int total = results.length;
  final int invalid = count(Verdict.invalid);
  final int timeouts = count(Verdict.killedByTimeout);
  final int killed = count(Verdict.killed) + timeouts;
  final int survived = count(Verdict.survived);
  final int equivalent = count(Verdict.equivalent);

  // THE DENOMINATOR, spelled out because it is the number people fudge.
  // Invalid mutants never ran, so no test could have killed them; argued
  // equivalents cannot be killed by any test that could ever be written.
  // Everything else is a fair question to ask of the suite.
  final int denominator = total - invalid - equivalent;
  final double score = denominator == 0 ? 0 : 100.0 * killed / denominator;

  stdout.writeln('');
  stdout.writeln('=' * 78);
  stdout.writeln('RESULTS');
  stdout.writeln('=' * 78);
  stdout.writeln('');
  stdout.writeln('  mutants generated & run   ${total.toString().padLeft(5)}');
  stdout.writeln('  invalid (did not compile) ${invalid.toString().padLeft(5)}   '
      'neither a kill nor a survivor: no test ever ran');
  stdout.writeln('  equivalent (argued)       ${equivalent.toString().padLeft(5)}   '
      'excluded from the denominator');
  stdout.writeln('  killed                    ${killed.toString().padLeft(5)}');
  stdout.writeln('    of which by timeout     ${timeouts.toString().padLeft(5)}   '
      'weaker evidence: "did not finish", not "asserted wrong"');
  stdout.writeln('  SURVIVED                  ${survived.toString().padLeft(5)}');
  stdout.writeln('');
  stdout.writeln('  mutation score  $killed / $denominator = '
      '${score.toStringAsFixed(1)}%');
  if (quick) {
    stdout.writeln('  (--quick: a smoke test over a sampled subset. This is NOT '
        'the mutation score.)');
  }
  stdout.writeln('');

  // ---- per-operator breakdown ------------------------------------------
  stdout.writeln('by operator:');
  stdout.writeln('  op    run  invalid  equiv  killed  survived');
  for (final MutOp op in MutOp.values) {
    final List<MutantResult> fam =
        results.where((MutantResult r) => r.mutant.op == op).toList();
    if (fam.isEmpty) {
      continue;
    }
    int c(Verdict v) => fam.where((MutantResult r) => r.verdict == v).length;
    final int famKilled = c(Verdict.killed) + c(Verdict.killedByTimeout);
    stdout.writeln(
      '  ${op.tag}${fam.length.toString().padLeft(7)}'
      '${c(Verdict.invalid).toString().padLeft(9)}'
      '${c(Verdict.equivalent).toString().padLeft(7)}'
      '${famKilled.toString().padLeft(8)}'
      '${c(Verdict.survived).toString().padLeft(10)}',
    );
  }
  stdout.writeln('');

  // ---- survivors --------------------------------------------------------
  final List<MutantResult> survivors =
      results.where((MutantResult r) => r.verdict == Verdict.survived).toList();
  stdout.writeln('SURVIVORS (${survivors.length}) — each is a hole in the suite '
      'until it is killed or argued equivalent:');
  if (survivors.isEmpty) {
    stdout.writeln('  none');
  } else {
    for (final MutantResult r in survivors) {
      stdout.writeln('  ${r.mutant.id.padRight(8)}${r.mutant.describe()}');
    }
  }
  stdout.writeln('');

  // ---- invalid ----------------------------------------------------------
  final List<MutantResult> bad =
      results.where((MutantResult r) => r.verdict == Verdict.invalid).toList();
  stdout.writeln('INVALID (${bad.length}) — did not compile, so excluded from '
      'both sides of the score:');
  if (bad.isEmpty) {
    stdout.writeln('  none');
  } else {
    for (final MutantResult r in bad) {
      stdout.writeln('  ${r.mutant.id.padRight(8)}${r.mutant.describe()}');
    }
  }
  stdout.writeln('');

  // ---- equivalents ------------------------------------------------------
  if (equivalents.isNotEmpty) {
    stdout.writeln('EQUIVALENT (${equivalents.length}) — with the argument for '
        'each, because an unargued exclusion is a hidden survivor:');
    equivalents.forEach((String id, KnownEquivalent e) {
      stdout.writeln('  $id  ${e.file}:${e.line}  '
          "'${e.original}' -> '${e.replacement}'");
      stdout.writeln('      ${e.argument}');
    });
    stdout.writeln('');
  }

  // ---- restore proof ----------------------------------------------------
  stdout.writeln('source restoration (SHA-256 of each target, before and after):');
  for (final String rel in targetFiles) {
    final bool same = originalHash[rel] == finalHash[rel];
    stdout.writeln('  $rel');
    stdout.writeln('    before ${originalHash[rel]}');
    stdout.writeln('    after  ${finalHash[rel]}  ${same ? 'MATCH' : 'MISMATCH'}');
  }
  stdout.writeln(restored
      ? '  RESTORED — lib/game is byte-identical to how the run found it.'
      : '  NOT RESTORED — lib/game has been left modified. Fix before committing.');
  stdout.writeln('');
  stdout.writeln('wall clock: ${(wall.inMilliseconds / 1000).toStringAsFixed(1)}s'
      ' for $total mutants');
}

// =============================================================================
// CLI plumbing
// =============================================================================

Map<String, String> _parseArgs(List<String> args) {
  final Map<String, String> out = <String, String>{};
  for (final String a in args) {
    if (!a.startsWith('--')) {
      continue;
    }
    final int eq = a.indexOf('=');
    if (eq < 0) {
      out[a.substring(2)] = 'true';
    } else {
      out[a.substring(2, eq)] = a.substring(eq + 1);
    }
  }
  return out;
}

/// Finds the Flutter launcher. Flutter is not on PATH on the machine this was
/// written for, so an explicit search beats a cryptic "command not found".
String _resolveFlutter(String? override) {
  if (override != null) {
    return override;
  }
  final String? root = Platform.environment['FLUTTER_ROOT'];
  if (root != null) {
    final String candidate =
        Platform.isWindows ? '$root\\bin\\flutter.bat' : '$root/bin/flutter';
    if (File(candidate).existsSync()) {
      return candidate;
    }
  }
  if (Platform.isWindows) {
    const String wellKnown = r'C:\src\flutter\bin\flutter.bat';
    if (File(wellKnown).existsSync()) {
      return wellKnown;
    }
    return 'flutter.bat';
  }
  return 'flutter';
}
