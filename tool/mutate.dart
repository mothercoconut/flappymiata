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
/// APPEND, NEVER INSERT. Mutant ids are assigned per operator family in this
/// order, so putting a new file in the middle would renumber every mutant after
/// it and silently invalidate every `--only=` reproduction anybody has written
/// down, plus the line numbers in [knownEquivalents].
const List<String> targetFiles = <String>[
  'lib/game/game_model.dart',
  'lib/game/geometry.dart',
  // Added with the replay work. Every one of these is pure Dart with no clock
  // and no randomness, which is the condition for a mutant's effect to be a
  // deterministic function of the source — and therefore for "the suite did not
  // notice" to be a fact rather than a flake.
  //
  // WHY THEY HAD TO BE ADDED RATHER THAN LEFT OUT: a mutation score is a
  // statement about the code it covers. Shipping four new files of rules under
  // an unchanged 100% would have been a statement about the OLD code wearing
  // the new code's badge.
  'lib/game/course_seed.dart',
  'lib/game/replay.dart',
  'lib/game/run_code.dart',
  'lib/game/verified_score.dart',
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
/// `test/daily_challenge_test.dart` is deliberately NOT here even though it
/// asserts hard on `lib/game/course_seed.dart`: it runs the reachability prover
/// over 366 courses and costs about three seconds, which is the same reason
/// `fairness_prover_test.dart` is not here either. Both are in tier 2, so no
/// mutant is ever called a survivor without them — only the ~95% that die
/// immediately skip them.
const List<String> tier1Tests = <String>[
  'test/game_model_test.dart',
  'test/car_geometry_test.dart',
  'test/headless_sim_test.dart',
  'test/tuning_constants_test.dart',
  'test/model_boundaries_test.dart',
  'test/replay_test.dart',
  'test/run_code_test.dart',
  'test/verified_score_test.dart',
];

/// TIER 2 — the escalation. An empty argument list means "every test file",
/// which is what `flutter test` does with no paths: the whole suite, including
/// `fairness_prover_test.dart` (whose prover re-derives the model's physics and
/// so can see constant changes tier 1 might not) and `widget_test.dart`.
const List<String> tier2Tests = <String>[];

/// The judge for the `--selftest` NEGATIVE control: a test file that compiles
/// `lib/game/game_model.dart` but cannot observe a change to its physics.
///
/// Named here, as configuration, rather than buried in the self-test, because
/// it is the one input to this tool that is a claim about a file somebody else
/// owns — and it has already gone stale once. See [_runSelfTest] for the full
/// argument and for what to do if it goes stale again.
const String negativeControlTest = 'test/car_geometry_test.dart';

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

/// How long the output drains get AFTER the child process has already exited.
///
/// WHY A GRACE PERIOD IS NEEDED AT ALL, rather than either zero or infinity.
/// `flutter test` is not one process: it spawns a `flutter_tester` grandchild
/// that INHERITS the stdout/stderr pipes this tool reads. `proc.exitCode`
/// completes when the direct child dies, but a pipe stays readable until every
/// process holding its write end is gone. So a short wait after exit is normal
/// and necessary — the last few hundred bytes of the compact reporter's output
/// routinely arrive in that window, and those bytes are what the classifier
/// reads.
///
/// WHY TEN SECONDS, AND NOT ONE, AND NOT INFINITY. Infinity is what this code
/// used to do, and it is how the tool hung: an orphaned grandchild keeps the
/// pipe open, the wait on the drains never completes, and nothing is covering
/// it with a timeout because the timeout was already spent on `exitCode`. One
/// second would be safe against that hang but would start truncating real
/// output on a loaded CI runner, and truncated output changes verdicts — see
/// the argument written out at the drain-stall handler in [runTests]. Ten
/// seconds is far longer than any legitimate post-exit flush observed here and
/// is still bounded, which is the only property that actually matters.
const Duration drainGrace = Duration(seconds: 10);

/// Default `--heartbeat=<seconds>`. `--heartbeat=0` turns the ticker off.
///
/// WHY FIFTEEN. The heartbeat exists to make silence impossible: the CI failure
/// this was written for showed 26 seconds of no output followed by a SIGTERM,
/// and nothing in the log could distinguish "the tool was working" from "the
/// tool was hung" from "the tool was printing into a pipe nobody flushed". At
/// 15s a four-minute CI step costs about sixteen extra lines, which is cheap
/// enough to leave on by default and dense enough that any gap longer than one
/// tick is visibly a gap.
const int defaultHeartbeatSeconds = 15;

/// The literal string every worker sandbox path contains.
///
/// WHY IT IS A NAMED CONSTANT AND NOT SPELLED OUT AT EACH USE. Two very
/// different pieces of code depend on this exact text: [_makeSandbox], which
/// creates the directories, and [_sweepSandboxOrphans], which decides which
/// processes it is allowed to kill. If those two ever drifted apart the sweep
/// would match nothing and report a confident, permanent zero — a check that
/// cannot fail is worse than no check, because it is believed.
const String sandboxMarker = 'flappymiata_mutate_';

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

  // ---------------------------------------------------------------------------
  // Added with the replay work. Two shapes, both of them properties of the
  // arithmetic rather than of the tests:
  //
  //   * negating a floating-point zero, which IEEE-754 makes indistinguishable
  //     from positive zero under every operation this code performs;
  //   * seeding a bit-shift accumulator with a value that lives permanently
  //     above the window any read ever looks at.
  //
  // Each was also checked empirically before being written down — the mutated
  // variant was implemented beside the original and the two compared over
  // thousands of inputs — because "I cannot think of an input that separates
  // them" and "no input separates them" are different claims.
  // ---------------------------------------------------------------------------
  KnownEquivalent(
    file: 'lib/game/course_seed.dart',
    line: 151,
    original: '400',
    replacement: '(-(400))',
    argument:
        'daysFromCivil: `shiftedYear % 400` becomes `shiftedYear % -400`. Dart '
        'defines `%` as EUCLIDEAN modulo — the specification for `int.%` says '
        'the result r satisfies 0 <= r < b.abs() — so the sign of the divisor '
        'cannot reach the result at all, and x % 400 and x % -400 are the same '
        'number for every x. (This is where Dart differs from C and Java, '
        'whose `%` takes the sign of the dividend; in those languages the '
        'mutant would be a real bug.) Checked as well as argued: the whole '
        'function was evaluated both ways over 216,036 dates spanning the '
        'years -2000 to 4000 and every result was identical. The divisor of '
        'the `~/` on the same line is a separate mutant and IS killed.',
  ),
  KnownEquivalent(
    file: 'lib/game/replay.dart',
    line: 360,
    original: '0.0',
    replacement: '(-(0.0))',
    argument:
        'FixedStepAccumulator: `double _carry = 0.0;` becomes `-0.0`. IEEE-754 '
        'defines -0.0 == +0.0 as TRUE, and every operation this field is ever '
        'subjected to — `+=`, `-=`, `>=`, and the `==` inside the tests — '
        'treats the two identically: -0.0 + x is x for every finite x, and '
        '-0.0 >= y has the same truth value as 0.0 >= y for every y. The three '
        'operations that CAN distinguish them are `isNegative`, division (the '
        'sign of the resulting infinity) and `toString`, and none of the three '
        'appears anywhere in this file or in any test of it. Checked as well as '
        'argued: 20,000 randomised jittery frame sequences produce identical '
        'step counts from either starting value.',
  ),
  KnownEquivalent(
    file: 'lib/game/replay.dart',
    line: 389,
    original: '0.0',
    replacement: '(-(0.0))',
    argument:
        'FixedStepAccumulator.stepsFor: `_carry = 0.0;` — the over-budget '
        'reset — becomes `-0.0`. Identical argument to the initialiser above, '
        'and covered by the same 20,000-sequence check: the value written here '
        'is only ever read back through `+=`, `>=` and `==`, all of which treat '
        'the two zeros as the same number.',
  ),
  KnownEquivalent(
    file: 'lib/game/replay.dart',
    line: 374,
    original: '>',
    replacement: '>=',
    argument:
        'FixedStepAccumulator.stepsFor: `if (!(realSeconds > 0)) return 0;` '
        'becomes `>= 0`. The two differ on exactly one input, realSeconds == '
        '0.0. The guard version returns 0 immediately; the mutant falls '
        'through, executes `_carry += 0.0` — which leaves the carry bit-for-bit '
        'unchanged for every value it can hold, including NaN, which cannot be '
        'reached here because a NaN fails both comparisons — then finds the '
        'loop condition unchanged and returns the same 0. Adding zero is the '
        'identity, so no sequence of calls can separate them. This one cannot '
        'be restructured away: any guard that differs only at zero is '
        'unobservable precisely because zero is the additive identity.',
  ),
  KnownEquivalent(
    file: 'lib/game/run_code.dart',
    line: 424,
    original: '0',
    replacement: '(0 + 1)',
    argument:
        '_base32Encode: `int buffer = 0;` becomes 1. The stray bit starts at '
        'position 0 and is pushed up by 8 on every byte, so after k bytes it '
        'sits at position 8k. Every read is `(buffer >> bits) & 0x1F` with '
        'bits < 5, i.e. a window over positions [bits, bits + 4] which never '
        'reaches position 8; the padding write is `(buffer << (5 - bits)) & '
        '0x1F`, a window over the low five bits for the same reason. The seeded '
        'bit is therefore above every window that is ever read, for every input '
        'and every payload length. Checked: 6,020 payloads of 0 to 300 bytes '
        'encode to byte-identical strings from either starting value.',
  ),
  KnownEquivalent(
    file: 'lib/game/run_code.dart',
    line: 511,
    original: '0',
    replacement: '(0 + 1)',
    argument:
        '_base32Decode: `int buffer = 0;` becomes 1. Same shape, and the bound '
        'is provable rather than merely plausible. After k characters the '
        'stray bit is at position 5k and the code has emitted m bytes, so '
        'bits = 5k - 8m; the emit window is [bits, bits + 7], whose top is '
        '5k - 8m + 7. The stray bit clears that window exactly when 8m > 7, '
        'i.e. whenever any byte has been emitted at all — and before the first '
        'emission no read happens. The final padding test masks positions '
        '[0, bits - 1] and bits <= 5k, so the stray bit is outside that too. '
        'Checked: 6,020 code lengths from 0 to 300 characters decode to '
        'identical bytes AND to the identical padding verdict from either '
        'starting value.',
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
  MutantResult(this.mutant, this.verdict, this.elapsed, this.detail,
      {this.drainStalled = false});

  final Mutant mutant;
  final Verdict verdict;
  final Duration elapsed;

  /// First useful line of compiler or test output, for the invalid list.
  final String detail;

  /// True if any test run behind this verdict lost output to a stalled drain,
  /// so the verdict rests on possibly-truncated evidence. Reported by id in
  /// [_printReport]; deliberately not consulted by the exit code.
  final bool drainStalled;
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
// Process hygiene, and being able to say why a run died
// =============================================================================
//
// EVERYTHING IN THIS SECTION EXISTS TO ANSWER ONE QUESTION: when this tool
// stops, why did it stop? The mutation verdicts were never the problem — the
// problem was a CI job that printed seven of fifty verdicts, went silent for
// 26 seconds, and was killed with SIGTERM while the runner reported a live
// `dart:flutter_to` process it had to terminate as an orphan. A tool that
// cannot say why it died forces the next person to guess, and guessing is how
// the same failure gets "fixed" three times.
//
// NOTHING IN THIS SECTION MAY CHANGE A VERDICT OR AN EXIT CODE. It observes,
// it reports, and it cleans up after itself. The one exception is deliberate
// and documented: a SIGTERM or SIGHUP arriving mid-run exits 2, because a run
// that was killed did not do its job and its partial score is not evidence.

/// Kills [pid] and every process descended from it. Best effort. **Never
/// throws.** Returns how many pids it actually signalled, so a caller can say
/// something falsifiable instead of "cleaned up".
///
/// WHY THE WHOLE TREE AND NOT JUST THE CHILD. On Linux `flutter` is a bash
/// script that runs a `dart` snapshot that spawns `flutter_tester`. Signalling
/// only the direct child — which is what this code used to do — leaves two live
/// descendants still holding the stdout pipe this tool is draining, and that is
/// exactly the state that hangs the run. The old comment on the timeout path
/// explicitly declined to wait for those descendants; declining to wait for
/// them is not the same as reaping them, and only reaping them ends the hang.
///
/// WHY IT MUST NOT THROW, EVER. Every caller is already in trouble when it gets
/// here: a timeout fired, or a drain stalled, or the process is being torn down
/// by a signal. A cleanup path that throws in that moment replaces a
/// diagnosable problem with an undiagnosable one.
int _killTree(int pid) {
  if (Platform.isWindows) {
    // `/T` walks the child list itself. This is the only reliable way to do it
    // on Windows: there is no `ps`, and the parent/child relation is not
    // exposed anywhere a plain Dart program can read.
    try {
      final ProcessResult r =
          Process.runSync('taskkill', <String>['/T', '/F', '/PID', '$pid']);
      // taskkill prints one SUCCESS line per process it actually terminated, so
      // the count is readable straight out of its own output. The fallback
      // keeps the number roughly honest if that wording ever changes.
      final int n = 'SUCCESS'.allMatches('${r.stdout}').length;
      return n > 0 ? n : (r.exitCode == 0 ? 1 : 0);
    } catch (_) {
      // taskkill missing, or the pid was already gone. Either way there is
      // nothing left to do and nothing worth failing over.
      return 0;
    }
  }

  // POSIX. `ps -eo pid=,ppid=` is the portable way to get the parent map:
  // `pgrep -P` is not present everywhere, and /proc is Linux-only.
  try {
    final ProcessResult r = Process.runSync('ps', <String>['-eo', 'pid=,ppid=']);
    final Map<int, List<int>> children = <int, List<int>>{};
    for (final String line in const LineSplitter().convert('${r.stdout}')) {
      final List<String> parts = line
          .trim()
          .split(RegExp(r'\s+'))
          .where((String s) => s.isNotEmpty)
          .toList();
      if (parts.length < 2) {
        continue;
      }
      final int? child = int.tryParse(parts[0]);
      final int? parent = int.tryParse(parts[1]);
      if (child == null || parent == null) {
        continue;
      }
      (children[parent] ??= <int>[]).add(child);
    }

    // Breadth-first by level, so the kill can go DEEPEST-FIRST. Order is not
    // cosmetic here: killing a parent before its children is precisely how an
    // orphan is made, and an orphan gets reparented to init, at which point
    // this walk can no longer find it from the pid it started with.
    final List<List<int>> levels = <List<int>>[
      <int>[pid],
    ];
    final Set<int> seen = <int>{pid};
    while (true) {
      final List<int> next = <int>[];
      for (final int p in levels.last) {
        for (final int c in children[p] ?? const <int>[]) {
          if (seen.add(c)) {
            next.add(c);
          }
        }
      }
      if (next.isEmpty) {
        break;
      }
      levels.add(next);
    }

    int signalled = 0;
    for (int i = levels.length - 1; i >= 0; i--) {
      for (final int p in levels[i]) {
        try {
          // Verified on this machine: killPid returns false for a pid that no
          // longer exists rather than throwing, so an already-dead descendant
          // is a no-op and not an error.
          if (Process.killPid(p, ProcessSignal.sigkill)) {
            signalled++;
          }
        } catch (_) {
          // Permission denied, or it exited between the listing and the
          // signal. Both are ordinary; neither is this function's problem.
        }
      }
    }
    return signalled;
  } catch (_) {
    // No usable `ps` — verified: on Windows this throws ProcessException, and
    // a stripped container image can be missing it too. Falling back to the
    // single process is still strictly better than doing nothing.
    try {
      return Process.killPid(pid, ProcessSignal.sigkill) ? 1 : 0;
    } catch (_) {
      return 0;
    }
  }
}

/// What one worker is judging right now, and when it started.
class _InFlight {
  _InFlight(this.mutantId, this.startedMs);

  final String mutantId;

  /// Milliseconds on [_RunProgress.wall] when this mutant was picked up.
  final int startedMs;
}

/// Live state of the run, readable from anywhere in the process.
///
/// WHY ONE TOP-LEVEL OBJECT RATHER THAN PARAMETERS THREADED THROUGH EVERYTHING.
/// Three unrelated places need the same answer to "what is this process doing
/// right now": the heartbeat ticker, the signal handler that has to print a
/// death report in whatever time it has left, and the final report. Two of
/// those are callbacks that nothing gets to call with arguments. This is one
/// process running one mutation run, so a single shared instance is the honest
/// model of it rather than a shortcut around one.
class _RunProgress {
  /// Started once, at the top of [_run], and never reset. Every elapsed figure
  /// the heartbeat and the death report print is measured against it, so they
  /// cannot disagree with each other.
  final Stopwatch wall = Stopwatch();

  int total = 0;
  int done = 0;

  /// Run-level count of output drains that hit [drainGrace]. Reported loudly;
  /// never consulted by the exit code.
  int drainStalls = 0;

  /// Worker label to what it is judging. A worker with nothing in flight is
  /// absent from this map rather than present with a null.
  final Map<String, _InFlight> inFlight = <String, _InFlight>{};

  void begin(String worker, String id) {
    inFlight[worker] = _InFlight(id, wall.elapsedMilliseconds);
  }

  void finish(String worker) {
    inFlight.remove(worker);
    done++;
  }

  /// e.g. `R014 (48s), A007 (12s)`. Empty when nothing is running.
  ///
  /// The AGE is the load-bearing half. `done 7/50` on its own cannot tell a
  /// reader whether the run is progressing slowly or stopped dead; a mutant
  /// that has been in flight for 48 seconds against a 45-second timeout can.
  String describeInFlight() {
    final int now = wall.elapsedMilliseconds;
    final List<String> parts = <String>[];
    for (final MapEntry<String, _InFlight> e in inFlight.entries) {
      final int age = (now - e.value.startedMs) ~/ 1000;
      parts.add('${e.value.mutantId} (${age}s)');
    }
    return parts.join(', ');
  }
}

final _RunProgress _progress = _RunProgress();

/// Serialized "write one line and flush it", for every line that can be
/// printed while something else is also printing.
///
/// WHY THIS EXISTS, AND IT IS NOT DEFENSIVENESS — IT IS A CRASH THAT HAPPENED.
/// `dart:io` implements `IOSink.flush()` by calling `addStream` with an empty
/// stream, which BINDS the sink until that future completes. While a flush is
/// in flight, ANY other `stdout.write`/`writeln` throws
/// `StateError: StreamSink is bound to a stream`. The first version of this
/// change flushed the heartbeat and the drain warning without awaiting them,
/// and the very next line a worker printed blew up with that error — an
/// unhandled exception, exit 255, no report at all. Which is a spectacular way
/// for a change whose entire purpose is "always be able to say why you died"
/// to invent a brand new way of dying silently.
///
/// So: one queue, one writer at a time, write-then-flush as an atomic unit.
/// The queue swallows its own errors because a logging path that can throw is
/// the thing being fixed here, not a thing to add.
Future<void> _outTail = Future<void>.value();

void _emit(String line) {
  _outTail = _outTail.then<void>((_) async {
    stdout.writeln(line);
    await stdout.flush();
  }).catchError((Object _) {});
}

/// Completes once everything queued by [_emit] has actually been written.
/// Call this before any phase that prints with plain `stdout.writeln`, so that
/// no queued flush is still in flight when those unserialized writes land.
Future<void> _outIdle() async {
  try {
    await _outTail;
  } catch (_) {
    // Already swallowed inside the queue; this is belt and braces.
  }
}

/// `mm:ss`, zero-padded, for the heartbeat and the death report.
String _mmss(Duration d) {
  final int secs = d.inSeconds;
  return '${(secs ~/ 60).toString().padLeft(2, '0')}:'
      '${(secs % 60).toString().padLeft(2, '0')}';
}

/// This process's resident set size, in whole MB, or `-` if it cannot be read.
///
/// `ProcessInfo.currentRss` is a cheap native call and works on every platform
/// this tool runs on (verified on Windows; it is the same accessor on Linux).
/// It is on the heartbeat because "the runner killed us" and "we ran out of
/// memory" look identical from the outside, and a number that climbs across a
/// run separates them.
String _rssMb() {
  try {
    return '${ProcessInfo.currentRss ~/ (1024 * 1024)} MB';
  } catch (_) {
    // A heartbeat missing one field is still a heartbeat. A heartbeat that
    // throws is silence, which is the thing this whole mechanism exists to
    // prevent.
    return '-';
  }
}

/// How many processes exist on this machine right now, or `-` where that
/// cannot be counted cheaply.
///
/// WHY THIS IS ON THE HEARTBEAT. The failure being chased leaks orphaned
/// `flutter_tester` and `dart` processes. A count that climbs monotonically
/// across a run IS that leak, visible with no extra tooling; a count that
/// stays flat rules the leak out and points somewhere else. On Linux every
/// process is a numeric directory under /proc, so this costs one listing.
/// Windows has no equivalent that is cheap enough to run every 15 seconds, so
/// it honestly prints `-` rather than a number it did not measure.
String _processCount() {
  if (!Platform.isLinux) {
    return '-';
  }
  try {
    int n = 0;
    for (final FileSystemEntity e
        in Directory('/proc').listSync(followLinks: false)) {
      if (int.tryParse(e.path.split('/').last) != null) {
        n++;
      }
    }
    return '$n';
  } catch (_) {
    // /proc absent or unreadable. Not fatal, not even interesting.
    return '-';
  }
}

/// Returns the text after `key` on the first matching line of `/proc/meminfo`,
/// e.g. `_procMemInfoValue('MemAvailable:')` gives `'12345678 kB'`. Null off
/// Linux or if the file cannot be read.
String? _procMemInfoValue(String key) {
  try {
    final String text = File('/proc/meminfo').readAsStringSync();
    for (final String line in const LineSplitter().convert(text)) {
      if (line.startsWith(key)) {
        return line.substring(key.length).trim();
      }
    }
  } catch (_) {
    // Not Linux, or /proc is not mounted. The caller prints nothing.
  }
  return null;
}

/// The filesystem type backing [Directory.systemTemp], read from
/// `/proc/mounts`. Null off Linux.
///
/// WHY THIS IS WORTH READING. If the system temp folder is a tmpfs, every byte
/// of every worker sandbox — and every byte of the `.dart_tool/flutter_build`
/// output `flutter test` regenerates inside it — is RAM, and `--jobs=N`
/// multiplies that by N. On a hosted runner with a few GB that is a live
/// hypothesis for the kernel or the runner killing this process, and it is
/// invisible unless somebody prints it.
String? _tempFsType() {
  try {
    final String tmp = Directory.systemTemp.path;
    String? best;
    int bestLen = -1;
    for (final String line
        in const LineSplitter().convert(File('/proc/mounts').readAsStringSync())) {
      final List<String> f = line.split(' ');
      if (f.length < 3) {
        continue;
      }
      final String mount = f[1];
      // Longest matching mount point wins: `/` matches everything, so a plain
      // "starts with" would always report the root filesystem and never the
      // tmpfs actually mounted at /tmp.
      final bool covers =
          tmp == mount || tmp.startsWith(mount == '/' ? '/' : '$mount/');
      if (covers && mount.length > bestLen) {
        bestLen = mount.length;
        best = f[2];
      }
    }
    return best;
  } catch (_) {
    // Not Linux, or /proc/mounts unreadable.
    return null;
  }
}

/// One line at the start of the run describing the machine it is running on.
///
/// WHY THIS EARNS ITS LINE OF OUTPUT. This tool is developed on Windows and
/// graded on a hosted Linux runner, and both failures it has actually suffered
/// — a hang, then a SIGTERM at two minutes — are resource-shaped. These are the
/// facts that would tell a reader WHICH resource, and none of them can be
/// recovered afterwards from a log that did not record them.
void _printMachineLine() {
  try {
    final StringBuffer b =
        StringBuffer('machine: ${Platform.numberOfProcessors} cores');
    if (Platform.isLinux) {
      final String? avail = _procMemInfoValue('MemAvailable:');
      if (avail != null) {
        b.write(', MemAvailable $avail');
      }
      final String? fs = _tempFsType();
      b.write(', ${Directory.systemTemp.path} is ${fs ?? 'an unknown fs'}');
    }
    stdout.writeln(b.toString());
  } catch (_) {
    // Diagnostics are never allowed to be the reason a run fails.
  }
}

/// Everything worth knowing at the moment this process is killed from outside.
///
/// WHY THE HANDLER PRINTS BEFORE IT DOES ANYTHING ELSE. A SIGTERM from a CI
/// runner is the one event where there is no next session to investigate in:
/// the process is going away, and whatever it did not say is lost. So each
/// fact is fetched and printed independently, every one of them individually
/// wrapped, because a diagnostic that throws while dying tells nobody anything
/// — it just replaces the report with a stack trace about the report.
void _printDeathReport(String signalName) {
  // stderr is a SEPARATE sink, so it is not bound by a flush that may still be
  // in flight on stdout (see [_emit]). This is the one report that must not
  // lose a line to a logging mechanism, so it gets a second place to go.
  void say(String line) {
    try {
      stdout.writeln(line);
    } catch (_) {
      try {
        stderr.writeln(line);
      } catch (_) {
        // Both sinks are gone. Nothing left to try.
      }
    }
  }

  say('');
  say('=' * 78);
  say('KILLED BY $signalName after ${_mmss(_progress.wall.elapsed)} '
      '(wall clock since the run started)');
  say('=' * 78);

  try {
    say('  progress:  done ${_progress.done}/${_progress.total}');
    final String busy = _progress.describeInFlight();
    say('  in flight: ${busy.isEmpty ? '(nothing)' : busy}');
    say('  drain stalls so far: ${_progress.drainStalls}');
  } catch (_) {
    say('  progress: unavailable');
  }

  try {
    say('  rss now ${_rssMb()}, peak '
        '${ProcessInfo.maxRss ~/ (1024 * 1024)} MB');
  } catch (_) {
    say('  rss: unavailable');
  }

  if (Platform.isLinux) {
    // Memory pressure is the leading explanation for an outside kill, and
    // these three files are the only place the kernel writes down what it
    // thought at the time.
    try {
      final String? avail = _procMemInfoValue('MemAvailable:');
      final String? swap = _procMemInfoValue('SwapFree:');
      say('  MemAvailable ${avail ?? '?'} , SwapFree ${swap ?? '?'}');
    } catch (_) {
      say('  /proc/meminfo: unavailable');
    }
    try {
      final File pressure = File('/proc/pressure/memory');
      if (pressure.existsSync()) {
        for (final String line
            in const LineSplitter().convert(pressure.readAsStringSync())) {
          say('  pressure/memory: $line');
        }
      }
    } catch (_) {
      say('  /proc/pressure/memory: unavailable');
    }
  }

  if (!Platform.isWindows) {
    // The point of this table is to NAME any orphaned `flutter_tester` or
    // `dart` process that is still resident, with its RSS. The runner's own
    // "Terminate orphan process" line names exactly one and truncates it; this
    // names all of them.
    try {
      final ProcessResult ps = Process.runSync(
        'ps',
        <String>['-eo', 'pid,ppid,rss,etime,stat,comm', '--sort=-rss'],
      );
      say('  top processes by RSS:');
      final List<String> lines = const LineSplitter().convert('${ps.stdout}');
      for (final String line in lines.take(12)) {
        say('    $line');
      }
    } catch (_) {
      say('  ps: unavailable');
    }
  }

  say('=' * 78);
}

/// Kills anything still running that references a worker sandbox, and says how
/// many that was — **including when the answer is zero**.
///
/// WHY THE ZERO IS PRINTED. A sweep that only speaks when it finds something is
/// indistinguishable from a sweep that never ran, and both look like success.
/// `orphan sweep: 0 processes still referencing a sandbox` is the falsifiable
/// form: it proves the sweep executed and reports what it saw.
///
/// WHY IT IS ONLY EVER CALLED WITH `--jobs>1`, and why that guard is not
/// optional. In `--jobs=1` mode the working root is the REPOSITORY, so a
/// path-matching kill would be matching on the developer's own project path and
/// could take out their editor, their analysis server or an unrelated Flutter
/// process. The guard is what makes "kill everything that mentions this path"
/// a safe sentence: with `--jobs>1` every path it can match is a directory this
/// run created under the system temp folder minutes ago.
void _sweepSandboxOrphans() {
  int matched = 0;
  int signalled = 0;
  try {
    final Set<int> pids = _pidsReferencingSandboxes();
    matched = pids.length;
    for (final int p in pids) {
      signalled += _killTree(p);
    }
  } catch (_) {
    // Housekeeping does not get a vote on whether the gate is red — the same
    // rule the sandbox teardown already follows.
  }
  stdout.writeln(
    'orphan sweep: $matched processes still referencing a sandbox'
    '${matched == 0 ? '' : ' — $signalled pids signalled'}',
  );
}

/// This process's own pid, plus every ancestor of it.
///
/// WHY THE SWEEP MUST NEVER TOUCH ANY OF THESE, AND HOW THAT WAS LEARNED.
/// Found by running the sweep for real on Windows with a decoy process: the
/// matcher looks at COMMAND LINES, and the shell that launched this tool had
/// the marker string in its own command line simply because the command being
/// typed mentioned it. `taskkill /T` on that shell killed the shell and every
/// descendant of it — including this tool, mid-run, which lost the rest of its
/// report. Nothing about "only sweep when --jobs>1" prevents that, because
/// that guard is about which PATHS are matchable, not about who is above us in
/// the process tree.
///
/// Excluding ancestors cannot hide a real orphan: a process this run is
/// descended from is by definition not a process this run leaked.
///
/// [parentOf] maps pid to parent pid. The 64-step ceiling is a cycle guard; a
/// process tree is a tree, but this map is assembled from text produced by
/// another program and does not get to hang the run if it is malformed.
Set<int> _selfAndAncestors(Map<int, int> parentOf) {
  final Set<int> out = <int>{pid};
  int cur = pid;
  for (int guard = 0; guard < 64; guard++) {
    final int? parent = parentOf[cur];
    if (parent == null || parent <= 0 || out.contains(parent)) {
      break;
    }
    out.add(parent);
    cur = parent;
  }
  return out;
}

/// Parent pid of [p] from `/proc/<p>/stat`, or null.
///
/// Field 4 of that line is the ppid, but field 2 is the executable name in
/// parentheses and may itself contain spaces or parentheses, so the split has
/// to start after the LAST `)` rather than at the first space. Getting this
/// wrong would silently return a nonsense ppid, and a nonsense ppid means the
/// ancestor guard above protects the wrong process.
int? _ppidFromProc(int p) {
  try {
    final String stat = File('/proc/$p/stat').readAsStringSync();
    final int close = stat.lastIndexOf(')');
    if (close < 0) {
      return null;
    }
    final List<String> rest = stat
        .substring(close + 1)
        .trim()
        .split(RegExp(r'\s+'))
        .where((String s) => s.isNotEmpty)
        .toList();
    // rest[0] is the state character; rest[1] is the ppid.
    return rest.length < 2 ? null : int.tryParse(rest[1]);
  } catch (_) {
    return null;
  }
}

/// Every pid whose command line, or (on Linux) whose working directory, names a
/// worker sandbox. Excludes this process and every ancestor of it. **Never
/// throws.**
///
/// WHY THE WORKING DIRECTORY IS CHECKED TOO, ON LINUX, AND NOT JUST THE ARGS.
/// This is an addition to the obvious design, and it is load-bearing. The
/// processes in a sandboxed run are `flutter` (a bash script), the `dart`
/// snapshot it runs, and `flutter_tester`. Only the last of those carries the
/// sandbox path in its ARGUMENTS, via `--packages=<sandbox>/.dart_tool/...`;
/// the other two are launched with the sandbox merely as their WORKING
/// DIRECTORY, so an args-only sweep would silently miss both and still report
/// a confident number. `/proc/<pid>/cwd` is a symlink that says so directly,
/// and it is exactly as specific a marker, so it costs nothing in safety.
Set<int> _pidsReferencingSandboxes() {
  final Set<int> candidates = <int>{};
  final Map<int, int> parentOf = <int, int>{};

  if (Platform.isWindows) {
    try {
      // ONE query returns three things per process: pid, parent pid, and
      // whether its command line names a sandbox. The parent pid is not a
      // nicety — it is what builds the ancestor set that keeps this sweep from
      // killing the shell it is running under.
      //
      // `-ne $PID` IS ALSO LOAD-BEARING AND WAS ALSO FOUND BY RUNNING IT. The
      // marker appears in this PowerShell process's OWN command line — it is
      // right there in the `-like` pattern — so Win32_Process matches the
      // querying process every single time. Verified by hand with nothing else
      // running: the query returned exactly one row, itself. Without this the
      // sweep would report at least one orphan on every Windows run forever,
      // and a count that can never be zero cannot be evidence of anything.
      // The zero is the whole product here.
      final ProcessResult r = Process.runSync('powershell', <String>[
        '-NoProfile',
        '-Command',
        'Get-CimInstance Win32_Process | ForEach-Object { '
            "'{0} {1} {2}' -f \$_.ProcessId, \$_.ParentProcessId, "
            "\$(if (\$_.CommandLine -like '*$sandboxMarker*' "
            '-and \$_.ProcessId -ne \$PID) { 1 } else { 0 }) }',
      ]);
      for (final String line in const LineSplitter().convert('${r.stdout}')) {
        final List<String> f = line.trim().split(' ');
        if (f.length < 3) {
          continue;
        }
        final int? p = int.tryParse(f[0]);
        final int? pp = int.tryParse(f[1]);
        if (p == null) {
          continue;
        }
        if (pp != null) {
          parentOf[p] = pp;
        }
        if (f[2] == '1') {
          candidates.add(p);
        }
      }
    } catch (_) {
      // No PowerShell, or the CIM query failed. Report nothing rather than
      // guessing at pids — a wrong pid here is a killed process.
    }
  } else {
    try {
      // `args=` last, because it is the field that contains spaces.
      final ProcessResult r =
          Process.runSync('ps', <String>['-eo', 'pid=,ppid=,args=']);
      for (final String line in const LineSplitter().convert('${r.stdout}')) {
        final String trimmed = line.trim();
        if (trimmed.isEmpty) {
          continue;
        }
        final List<String> f = trimmed.split(RegExp(r'\s+'));
        if (f.length < 2) {
          continue;
        }
        final int? p = int.tryParse(f[0]);
        final int? pp = int.tryParse(f[1]);
        if (p == null) {
          continue;
        }
        if (pp != null) {
          parentOf[p] = pp;
        }
        // `ps`'s own command line is `ps -eo pid=,ppid=,args=`, which does not
        // contain the marker, so there is no self-match to exclude here the
        // way there is on Windows.
        if (trimmed.contains(sandboxMarker)) {
          candidates.add(p);
        }
      }
    } catch (_) {
      // No `ps`. The /proc pass below may still find them.
    }
  }

  if (Platform.isLinux) {
    // Fill any gaps in the parent map straight from /proc, so the ancestor
    // guard still works on a machine with no `ps` at all.
    int cur = pid;
    for (int guard = 0; guard < 64 && !parentOf.containsKey(cur); guard++) {
      final int? pp = _ppidFromProc(cur);
      if (pp == null || pp <= 0) {
        break;
      }
      parentOf[cur] = pp;
      cur = pp;
    }

    try {
      for (final FileSystemEntity e
          in Directory('/proc').listSync(followLinks: false)) {
        final int? p = int.tryParse(e.path.split('/').last);
        if (p == null) {
          continue;
        }
        try {
          final String cwd = Link('/proc/$p/cwd').resolveSymbolicLinksSync();
          if (cwd.contains(sandboxMarker)) {
            candidates.add(p);
          }
        } catch (_) {
          // Another user's process, or one that exited between the listing
          // and the readlink. Both are ordinary.
        }
      }
    } catch (_) {
      // /proc unreadable.
    }
  }

  // The last word belongs to the ancestor guard, applied to everything both
  // passes found. See [_selfAndAncestors] for what happened without it.
  return candidates.difference(_selfAndAncestors(parentOf));
}

// =============================================================================
// Test running
// =============================================================================

class TestRun {
  TestRun(this.verdict, this.detail, this.elapsed, {this.drainStalled = false});

  final Verdict verdict;
  final String detail;
  final Duration elapsed;

  /// True if the output drains were still open [drainGrace] after the child
  /// exited, i.e. this run's output may be TRUNCATED. Carried through to the
  /// report rather than acted on — see the argument in [runTests].
  final bool drainStalled;
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
  bool drainStalled = false;
  try {
    exitCode = await proc.exitCode.timeout(timeout);

    // THE DRAIN IS BOUNDED. This line used to be an unconditional
    // `await Future.wait([outDone, errDone])` with no ceiling on it, and that
    // is the defect that hung this tool. The `.timeout` above is spent on
    // `exitCode`, so once the direct child has exited there was nothing left
    // covering the wait: if a `flutter_tester` grandchild still held the write
    // end of these pipes, neither future would ever complete and the run
    // stopped here, silently, forever.
    try {
      await Future.wait(<Future<void>>[outDone, errDone]).timeout(drainGrace);
    } on TimeoutException {
      drainStalled = true;
      _progress.drainStalls++;
      final int reaped = _killTree(proc.pid);

      // WHY THIS IS SAFE TO CARRY ON FROM, WHICH IS THE PART THAT MATTERS.
      //
      // Truncated output can only ever move a run TOWARDS `UNRECOGNISED` and
      // therefore towards `Verdict.invalid`. It can never manufacture a free
      // kill, because the killed branch below requires either the literal
      // string `Some tests failed.` in the output or a non-zero exit code, and
      // losing bytes cannot add either of those. `invalid` is excluded from
      // BOTH sides of the score and every invalid mutant is printed by id in
      // the report, so a misfiled run is loud rather than flattering. That is
      // the safe direction to fail in, and it is why this does not throw.
      //
      // THE COST, STATED PLAINLY: a genuine SURVIVOR whose output was
      // truncated here would be misfiled as INVALID, which means a real hole
      // in the test suite could be hidden by this path. That is exactly why
      // the grace is ten seconds rather than one, and why the stall is
      // counted, warned about at the moment it happens, and reported at the
      // end with the mutant ids attached. A silent version of this would be
      // a way of quietly losing findings.
      _emit(
        'WARNING: output drain still open ${drainGrace.inSeconds}s after the '
        'child exited — a grandchild is holding the pipe. Reaped $reaped '
        'pid(s); classifying only the output buffered so far, which can turn '
        'a real SURVIVOR into an INVALID.',
      );
    }
  } on TimeoutException {
    timedOut = true;
    // The whole tree, not just the direct child. `flutter` on Linux is a bash
    // script running a `dart` snapshot that spawns `flutter_tester`; killing
    // the script left both descendants alive and holding this pipe.
    final int reaped = _killTree(proc.pid);

    // Now that the tree is dead the drains CAN be waited on, and they should
    // be: a pending stream subscription is one of the things that keeps a Dart
    // VM resident after everything useful is finished (see the note in
    // `main`). Bounded, because this is the path that exists to unblock a run
    // and it must not become a second way to hang.
    try {
      await Future.wait(<Future<void>>[outDone, errDone]).timeout(drainGrace);
    } on TimeoutException {
      drainStalled = true;
      _progress.drainStalls++;
      _emit(
        'WARNING: pipes still open ${drainGrace.inSeconds}s after killing the '
        'timed-out process tree ($reaped pid(s) signalled).',
      );
    }
  }
  sw.stop();

  final String output = buf.toString();

  if (timedOut) {
    return TestRun(
      Verdict.killedByTimeout,
      'no result within ${timeout.inSeconds}s',
      sw.elapsed,
      drainStalled: drainStalled,
    );
  }

  // Compile failure. Checked before anything else — see the doc comment.
  if (output.contains('Compilation failed for testPath=') ||
      output.contains('Error: The Dart compiler exited unexpectedly') ||
      (output.contains('Failed to load "') && output.contains(': Error: '))) {
    return TestRun(Verdict.invalid, _firstCompilerError(output), sw.elapsed,
        drainStalled: drainStalled);
  }

  if (exitCode == 0 && output.contains('All tests passed!')) {
    return TestRun(Verdict.survived, '', sw.elapsed,
        drainStalled: drainStalled);
  }

  if (output.contains('Some tests failed.') || (exitCode ?? 1) != 0) {
    return TestRun(Verdict.killed, _firstFailure(output), sw.elapsed,
        drainStalled: drainStalled);
  }

  // Neither shape. Refusing to guess is the point: an unrecognised outcome
  // silently filed as a kill is exactly how a mutation score stops meaning
  // anything.
  return TestRun(
    Verdict.invalid,
    drainStalled
        ? 'UNRECOGNISED test output (exit $exitCode; output TRUNCATED by a '
            'stalled drain — this may be a hidden survivor)'
        : 'UNRECOGNISED test output (exit $exitCode)',
    sw.elapsed,
    drainStalled: drainStalled,
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
/// WHY THIS IS SET RATHER THAN RETURNED: Dart ignores a `main` return value
/// entirely. Measured on Dart 3.13.2, BOTH `Future<int> main() async => 1;` and
/// a synchronous `int main() => 1;` exit 0. So `return 1` here would exit 0 and
/// a CI job wired to `--quick` would go green over a survivor. Only assigning
/// `exitCode` (or calling `exit`) sets the status. An earlier version of this
/// comment said the synchronous form was safe; it is not.
Future<void> main(List<String> args) async {
  final int status = await _run(args);

  // `exitCode` is set as well as `exit()` being called, because they answer two
  // different questions: a `Future<int> main` has its return value DISCARDED by
  // the VM, so the assignment is what makes the number reachable at all, and
  // the call below is what makes the process actually reach it.
  exitCode = status;

  // WHY THIS LEAVES EXPLICITLY INSTEAD OF RETURNING AND LETTING THE VM DRAIN.
  //
  // `flutter test` is not one process. It spawns a `flutter_tester` grandchild
  // that inherits the pipes this tool reads, and when a mutant hangs the suite
  // and the timeout fires, killing the child does not always take the
  // grandchild with it. What is left is a pipe nobody will ever close, and a
  // Dart VM will not exit while something is still listening to one. Observed
  // directly: a `--quick --jobs=4` run printed its entire report at 201s and
  // was still resident ten minutes later, having produced no exit code at all.
  //
  // That is the worst possible shape for a CI gate. A wrong answer is at least
  // an answer; a job that hangs until the runner's timeout kills it reports
  // nothing, and the report it already printed scrolls past unread. By this
  // point every verdict is computed, printed and flushed, so there is nothing
  // left for the event loop to do that anyone is waiting for.
  // Drain the serialized queue BEFORE the final flush: `exit` is immediate and
  // does not wait for pending microtasks, so anything still sitting in the
  // queue at this point would simply never be printed.
  await _outIdle();
  await stdout.flush();
  exit(status);
}

Future<int> _run(List<String> args) async {
  final Map<String, String> opts = _parseArgs(args);

  // Started before anything else so that every elapsed figure printed by the
  // heartbeat and by the death report is measured from the same instant, and
  // so that a run killed during generation still reports a real elapsed time
  // rather than zero.
  _progress.wall.start();

  final String repoRoot = opts['root'] ?? Directory.current.path;
  final String flutterCmd = _resolveFlutter(opts['flutter']);
  final Duration timeout = Duration(
    seconds: int.parse(opts['timeout'] ?? '${defaultTimeout.inSeconds}'),
  );
  final bool quick = opts.containsKey('quick');
  final bool listOnly = opts.containsKey('list');
  final bool selftest = opts.containsKey('selftest');
  final Set<String>? only = opts['only']?.split(',').toSet();
  final int heartbeatSeconds =
      int.parse(opts['heartbeat'] ?? '$defaultHeartbeatSeconds');

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

  /// Last words. Print first, restore second, leave third.
  ///
  /// WHY THE EXIT CODE IS 2 AND NOT 1. The contract at the bottom of this
  /// function is that the number means something a reader would act on: 1 says
  /// "the tool worked and found a real hole", 2 says "the tool could not do
  /// its job, so no score it printed is evidence". A run that was killed from
  /// outside at 7 of 50 mutants is squarely the second thing. Returning 1
  /// would send somebody hunting for a survivor that was never measured.
  // Declared before `dieOnSignal` so the signal handler can stop the ticker
  // before it prints, and before the `try` so the `finally` can cancel it on
  // every return path. A live periodic timer is exactly the kind of thing that
  // keeps a Dart VM alive after all the useful work is done, which is the
  // failure this tool has already been bitten by once.
  Timer? heartbeat;

  // A runner that wants a process gone often sends SIGTERM and then SIGHUP.
  // Without this latch both handlers would run and the two death reports would
  // interleave line by line, turning the one piece of evidence this path exists
  // to produce into something nobody can read.
  bool dying = false;
  Future<void> dieOnSignal(String signalName) async {
    if (dying) {
      return;
    }
    dying = true;
    // Silence the ticker first: a heartbeat line interleaved into the death
    // report, or a queued flush landing mid-report, is exactly the noise this
    // report cannot afford.
    heartbeat?.cancel();
    heartbeat = null;
    _printDeathReport(signalName);
    try {
      restoreAll();
      stdout.writeln('lib/game restored.');
    } catch (_) {
      try {
        stdout.writeln('WARNING: could not restore lib/game while dying — '
            'check the working tree before committing.');
      } catch (_) {
        // stdout is gone too. Nothing left to say it with.
      }
    }
    try {
      await stdout.flush();
    } catch (_) {
      // Nothing further to try; we are leaving either way.
    }
    exit(2);
  }

  // SIGTERM and SIGHUP: the two ways a CI runner ends a job it has decided to
  // stop. The observed failure was exit code 143, which is 128 + 15, which is
  // SIGTERM — and the log said nothing else at all. Catching it turns "the
  // step died" into a report naming what was in flight and what the machine
  // looked like at that instant.
  //
  // WHY THIS IS GUARDED BY `!Platform.isWindows` EVEN THOUGH IT DOES NOT HAVE
  // TO BE. Checked against the Dart 3.13.2 SDK source and confirmed by running
  // it: `ProcessSignal.sigterm.watch()` and `sighup.watch()` do NOT throw on
  // Windows — the SDK's own guard permits sighup, sigint and sigterm on every
  // platform. The guard is here for a different and better reason: everything
  // the handler prints that is worth printing (`ps`, /proc/meminfo,
  // /proc/pressure/memory) is POSIX-only, and a Windows SIGTERM is a synthetic
  // console event that this tool is never actually killed by. Registering a
  // handler that could only print a header would be noise pretending to be
  // coverage.
  StreamSubscription<ProcessSignal>? sigterm;
  StreamSubscription<ProcessSignal>? sighup;
  if (!Platform.isWindows) {
    sigterm = ProcessSignal.sigterm
        .watch()
        .listen((_) => unawaited(dieOnSignal('SIGTERM')));
    sighup = ProcessSignal.sighup
        .watch()
        .listen((_) => unawaited(dieOnSignal('SIGHUP')));
  }

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
    _printMachineLine();
    stdout.writeln('');

    // FLUSH THE HEADER EXPLICITLY, and after every line printed below that a
    // reader would use to locate a failure in time.
    //
    // WHY THIS IS NOT SUPERSTITION. GitHub Actions captures a step's stdout
    // through a PIPE, and a pipe is block-buffered rather than line-buffered.
    // A process killed with buffered lines still pending loses them entirely,
    // and lost output is indistinguishable in the log from output that was
    // never produced. The CI failure this was written for showed 26 seconds of
    // silence before a SIGTERM; some of that "silence" may simply be lines
    // that existed and never reached the runner. Flushing costs nothing and
    // rules the explanation in or out instead of leaving it open.
    await stdout.flush();

    if (listOnly) {
      for (final Mutant m in all) {
        stdout.writeln('${m.id.padRight(8)}${m.describe()}');
      }
      return 0;
    }

    // ---- heartbeat -------------------------------------------------------
    // WHY A TIMER AND NOT A PRINT AT THE TOP OF EACH WORKER ITERATION. A
    // per-iteration print can only speak when an iteration ENDS, which is
    // precisely the thing that stops happening when a run wedges. The whole
    // value of this line is that it fires while every worker is busy, so the
    // gaps get covered rather than the moments that were never in doubt.
    if (heartbeatSeconds > 0) {
      heartbeat = Timer.periodic(Duration(seconds: heartbeatSeconds), (Timer _) {
        final String busy = _progress.describeInFlight();
        _emit(
          '[hb] +${_mmss(_progress.wall.elapsed)}  '
          'done ${_progress.done}/${_progress.total}  '
          'rss ${_rssMb()}  procs ${_processCount()}'
          '${busy.isEmpty ? '' : '  inflight: $busy'}',
        );
      });
    }

    if (selftest) {
      // Three controls, so the heartbeat's `done N/total` means something
      // during the self-test too rather than reading `0/0` for its duration.
      _progress.total = 3;
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
    _progress.total = toRun.length;
    Future<void> worker(String root) async {
      // Stable label so the heartbeat can name which worker is stuck, not just
      // that something is.
      final String label = 'w${roots.indexOf(root)}';
      while (true) {
        final int i = nextIndex++;
        if (i >= toRun.length) {
          return;
        }
        final Mutant m = toRun[i];
        _progress.begin(label, m.id);
        final MutantResult r = await _judge(
          flutterCmd,
          root,
          m,
          originalText,
          originalBytes,
          timeout,
        );
        _progress.finish(label);
        results.add(r);
        // See the flush argument at the header: a verdict line that never left
        // the buffer is a verdict nobody can prove was computed. [_emit]
        // rather than a bare writeln+flush because the heartbeat and the other
        // workers are printing at the same time.
        _emit(
          '[${_progress.done.toString().padLeft(4)}/${toRun.length}] '
          '${m.id.padRight(8)}${_verdictLabel(r.verdict).padRight(12)}'
          '${m.describe()}',
        );
        await _outIdle();
      }
    }

    await Future.wait(roots.map(worker));
    wall.stop();

    // The ticker stops HERE, not in the `finally`, and the output queue is
    // drained before anything else prints. Everything from this point on —
    // the sweep, the hash proof, the report — writes with plain
    // `stdout.writeln`, and those writes are only safe once no queued flush
    // can still be in flight. See [_emit] for what happens when they are not.
    heartbeat?.cancel();
    heartbeat = null;
    await _outIdle();

    // ---- orphan sweep ----------------------------------------------------
    // Run here, after the last verdict and BEFORE the sandbox deletes, because
    // a process still holding a handle inside a sandbox is the documented
    // reason those deletes fail on Windows — and, on Linux, the reason the
    // whole tool can outlive its own report.
    if (jobs > 1) {
      _sweepSandboxOrphans();
    } else {
      // Said out loud rather than skipped silently. "No line" and "zero
      // orphans" must not look the same to a reader.
      stdout.writeln('orphan sweep: skipped — only safe with --jobs>1, where '
          'every matchable path is a sandbox this run created');
    }
    await stdout.flush();

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

    // Housekeeping, deliberately incapable of failing the run — see
    // [_removeSandboxes]. Every verdict above is already computed by this
    // point, so an exception escaping from a directory delete would throw away
    // the entire diagnosis over some bytes in the system temp folder.
    final List<String> teardownWarnings = _removeSandboxes(roots, repoRoot);

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
      teardownWarnings: teardownWarnings,
      drainStalls: _progress.drainStalls,
    );

    // THE EXIT CODE REFLECTS THE VERDICTS AND NOTHING ELSE.
    //
    // GitHub decides a step failed by reading this number, so every value it
    // can take has to mean something a reader would act on:
    //
    //   2 — the tool could not do its job, so no score it printed is evidence
    //       (a target file missing, a stale equivalence table, a tree it could
    //       not restore).
    //   1 — the tool worked and found at least one survivor: a real hole.
    //   0 — the tool worked and every mutant it selected was accounted for.
    //
    // `teardownWarnings` is deliberately absent from this decision. A sandbox
    // that could not be deleted says nothing about the code under test, and a
    // gate that goes red over it would train everyone to ignore red.
    if (!restored) {
      return 2;
    }
    final int survivors =
        results.where((MutantResult r) => r.verdict == Verdict.survived).length;
    return survivors == 0 ? 0 : 1;
  } finally {
    // The ticker is cancelled FIRST and unconditionally. A live periodic timer
    // is a pending event-loop task, and a pending event-loop task is one of
    // the things that can keep this VM resident after the report is printed —
    // the exact shape of failure documented in `main`.
    heartbeat?.cancel();
    restoreAll();
    await sigint.cancel();
    await sigterm?.cancel();
    await sighup?.cancel();
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
    // A stall in EITHER tier taints the verdict, so the flag is OR-ed rather
    // than overwritten by the later run.
    run = TestRun(
      full.verdict,
      full.detail,
      run.elapsed + full.elapsed,
      drainStalled: run.drainStalled || full.drainStalled,
    );
  }

  for (final String rel in targetFiles) {
    _writeWithRetry(File('$root/$rel'), originalBytes[rel]!);
  }
  return MutantResult(m, run.verdict, run.elapsed, run.detail,
      drainStalled: run.drainStalled);
}

/// Creates worker sandbox [i]: a minimal copy of the package that `flutter
/// test` can run in, with its own `lib/game/` for this worker to break.
///
/// WHY THE STALE DIRECTORY IS CLEARED RATHER THAN REUSED: the sandbox has to
/// hold exactly the files this run copied into it. Reusing a directory left by
/// an older tree could leave a test file behind that no longer exists here, and
/// every verdict after that would be judged by a suite nobody has.
///
/// WHY FAILING TO CLEAR IT IS NOT FATAL. The clear can fail for the same
/// Windows reason [_removeSandboxes] exists: a `flutter test` process from the
/// previous run — sometimes one that never exited at all — still holds a handle
/// inside it, and `deleteSync` throws. That used to kill the run at startup with
/// exit 255 and no report, which is the same defect as the one at teardown,
/// just moved earlier. So the delete is retried, and if it still will not go, a
/// fresh uniquely-named directory is used instead of the preferred one. A
/// second-choice path costs nothing; a dead run costs the whole diagnosis.
String _makeSandbox(String repoRoot, int i) {
  // Both spellings go through [sandboxMarker] so the orphan sweep's matcher
  // and the directory names it matches on can never drift apart.
  final String preferred = '${Directory.systemTemp.path}/$sandboxMarker$i';
  Directory dir = Directory(preferred);
  if (dir.existsSync() && _deleteDirWithRetry(dir) != null) {
    dir = Directory.systemTemp.createTempSync('$sandboxMarker${i}_');
    _emit('note: could not clear $preferred (something still holds a '
        'handle in it); worker $i will use ${dir.path} instead');
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

/// Deletes the worker sandboxes created by [_makeSandbox]. Returns one warning
/// line per directory that could not be removed. **Never throws.**
///
/// WHY A FAILED DELETE MUST NOT FAIL THE RUN. This runs after every verdict has
/// been computed and before any of them has been shown. On Windows a
/// `flutter test` process that has only just exited can still hold a handle
/// somewhere inside its sandbox for a few milliseconds — an antivirus scanner
/// or the search indexer following the process out does the same — and
/// `deleteSync` then throws `FileSystemException`. Letting that escape killed
/// the whole run with exit 255 and printed no report at all, so a perfectly
/// green codebase produced a red gate and no diagnosis. The verdicts are the
/// product; cleanup is housekeeping, and housekeeping does not get a vote on
/// whether the gate is red.
///
/// WHY LEAVING A STALE DIRECTORY BEHIND IS SAFE, and not a leak that grows.
/// The sandbox path is derived from the worker index, not from a timestamp or
/// a random suffix, so there are at most `--jobs` of them; and [_makeSandbox]
/// clears any pre-existing directory of that name before it copies anything.
/// The next run therefore starts from a clean sandbox whether or not this one
/// managed to tidy up. The worst case is a few tens of megabytes sitting in
/// the system temp folder until the next run, or until the OS clears it.
///
/// That argument only holds because [_makeSandbox] can SURVIVE finding a stale
/// directory it cannot delete — it retries, then falls back to a fresh path.
/// Before that, a lock held past the end of one run made the NEXT run die at
/// startup with exit 255, which would have made "just leave it behind"
/// a way of moving the bug rather than fixing it. The two halves are one fix.
///
/// WHY IT RETRIES FIRST. The lock is usually transient — it belongs to a
/// process that has already exited — so pausing briefly turns most of these
/// into a delay instead of a warning. Same reasoning, and the same shape, as
/// [_writeWithRetry]; only the consequence of giving up differs.
List<String> _removeSandboxes(List<String> roots, String repoRoot) {
  final List<String> warnings = <String>[];
  for (final String root in roots) {
    // `--jobs=1` runs in the repository itself. Never delete that.
    if (root == repoRoot) {
      continue;
    }
    final String? why = _deleteDirWithRetry(Directory(root));
    if (why != null) {
      warnings.add('could not delete temporary sandbox $root — $why');
    }
  }
  return warnings;
}

/// Deletes [dir] and everything under it, retrying briefly. Returns `null` once
/// it is gone, or a one-line description of the last failure if it is not.
/// **Never throws** — both callers have already decided that a directory they
/// could not remove is not worth failing over.
///
/// One second of retries, in 50ms steps. Long enough for a process that has
/// just exited to actually release its handles, short enough that a genuinely
/// stuck directory does not stall the run.
String? _deleteDirWithRetry(Directory dir) {
  Object? last;
  for (int attempt = 0; attempt < 20; attempt++) {
    try {
      if (!dir.existsSync()) {
        return null;
      }
      dir.deleteSync(recursive: true);
      return null;
    } on FileSystemException catch (e) {
      last = e;
      sleepMillis(50);
    }
  }
  // One last look: another process may have released it on the final sleep.
  return dir.existsSync() ? '$last' : null;
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

/// How many mutants `--quick` may run, in total, no matter how big `lib/game/`
/// gets.
///
/// WHY A FIXED BUDGET AND NOT A FIXED FRACTION. The previous rule took
/// `ceil(size / 8)` from every operator family, which sounds stable and is not:
/// it makes the CI subset a fixed FRACTION of a surface that only ever grows.
/// Four files were added to `lib/game/` and the mutation surface went from 410
/// mutants to 1225, so the subset went from ~52 to 154 and the CI step got
/// three times longer — silently, in a commit that was about something else,
/// with the job's 45-minute ceiling unchanged. Anything derived from the size
/// of the code will do that again the next time the code grows.
///
/// A budget cannot. The number below IS the CI cost: 52 mutants is what this
/// gate used to run and what it was timed against, so pinning it here restores
/// that cost and holds it there. When the surface grows the sample gets
/// thinner, which is the honest trade — see [quickSubset] for what that buys
/// and what it gives up.
const int quickBudget = 52;

/// The least any non-empty operator family may contribute, even if its
/// proportional share rounds to less. Two rather than one so a family is
/// sampled at both ends of its range rather than at a single point.
const int quickFamilyFloor = 2;

/// The CI subset, stated precisely because "a subset" that nobody can reproduce
/// is not a gate.
///
/// THE RULE, in three steps, all integer arithmetic:
///
///   1. Every non-empty operator family is given `min(2, size)` places up
///      front. This is the floor, and it is what keeps the subset stratified:
///      no family can be squeezed out by the big ones.
///   2. The rest of [quickBudget] is apportioned between the families in
///      proportion to their size by the HIGHEST-AVERAGES (D'Hondt) method —
///      each remaining place goes to the family with the largest
///      `size / (places + 1)`, compared by cross-multiplication so no floating
///      point is involved. Ties go to the family declared first in [MutOp],
///      which is what makes the outcome reproducible rather than merely
///      deterministic-looking.
///   3. Within a family, sorted by file then source offset, the places are
///      filled at evenly spaced indices with both endpoints included.
///
/// There is no randomness and no clock anywhere in that, so the same commit
/// always yields the same subset and anything CI flags reproduces locally with
/// `--only=<id>`.
///
/// WHY STRATIFIED RATHER THAN "THE FIRST N": every operator family stays
/// represented. A subset that happened to be all constant mutants would go
/// green while the relational operator was completely broken, and a gate that
/// cannot fail for a whole class of defect is not a gate. Step 1 guarantees
/// representation; step 2 keeps the weight roughly proportional to where the
/// mutants actually are.
///
/// WHAT THE BUDGET COSTS. Under the old rule each family gave up an eighth of
/// itself, so a hole anywhere had about a one-in-eight chance of being sampled.
/// Under a fixed budget that odds ratio falls as `lib/game/` grows — at 1225
/// mutants it is roughly one in twenty-four. This gate is therefore a WEAKER
/// smoke test than it was, and deliberately so: the alternative was a gate that
/// grows without bound until it hits the job timeout and reports nothing at
/// all. The full run, `dart run tool/mutate.dart` with no `--quick`, is still
/// the thing that grades the suite, and it is unchanged.
///
/// WHAT IT IS AND IS NOT FOR: it is a smoke test that the tool still applies
/// mutants and the suite still kills them. Its pass rate is NOT the mutation
/// score, and the report says so.
List<Mutant> quickSubset(List<Mutant> all) {
  // Families in [MutOp] declaration order. That fixed order is what every
  // tie-break below leans on, so it is established once, here.
  final List<List<Mutant>> families = <List<Mutant>>[];
  for (final MutOp op in MutOp.values) {
    final List<Mutant> family = all.where((Mutant m) => m.op == op).toList();
    if (family.isNotEmpty) {
      families.add(family);
    }
  }
  if (families.isEmpty) {
    return <Mutant>[];
  }

  final int n = families.length;
  final List<int> places = List<int>.filled(n, 0);

  // Step 1 — the floor.
  int spent = 0;
  for (int i = 0; i < n; i++) {
    places[i] = _min(quickFamilyFloor, families[i].length);
    spent += places[i];
  }

  // Step 2 — apportion what is left, highest averages first.
  int remaining = quickBudget - spent;
  while (remaining > 0) {
    int best = -1;
    for (int i = 0; i < n; i++) {
      if (places[i] >= families[i].length) {
        continue; // this family is already taken whole; it cannot take more
      }
      if (best < 0) {
        best = i;
        continue;
      }
      // families[i].size / (places[i] + 1)  >  families[best].size / (places[best] + 1)
      // cross-multiplied, so this stays exact integer arithmetic.
      final int lhs = families[i].length * (places[best] + 1);
      final int rhs = families[best].length * (places[i] + 1);
      if (lhs > rhs) {
        best = i; // strictly greater, so an exact tie keeps the earlier family
      }
    }
    if (best < 0) {
      break; // every family exhausted: the budget is bigger than the surface
    }
    places[best]++;
    remaining--;
  }

  // Step 3 — fill each family's places at evenly spaced indices.
  final List<Mutant> out = <Mutant>[];
  for (int i = 0; i < n; i++) {
    final List<Mutant> family = families[i];
    final int want = places[i];
    for (int j = 0; j < want; j++) {
      final int idx = want == 1 ? 0 : (j * (family.length - 1)) ~/ (want - 1);
      final Mutant m = family[idx];
      if (!out.contains(m)) {
        out.add(m);
      }
    }
  }
  return out;
}

int _min(int a, int b) => a < b ? a : b;

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
/// THE NEGATIVE CONTROL'S JUDGE, and why it is the file named in
/// [negativeControlTest] rather than some other one.
///
/// A negative control needs a judge that is BLIND TO THIS EDIT and BLIND TO
/// NOTHING ELSE. Both halves matter. If the judge could see the edit, the
/// control fails on working code. If the judge could see nothing at all — an
/// empty test file, a suite of `expect(true, isTrue)` — then SURVIVED is what
/// it would say about everything, and a control that cannot say anything else
/// proves nothing.
///
/// `test/car_geometry_test.dart` satisfies both. It imports the mutated file,
/// so the edit really is written to disk and really is compiled before the
/// verdict is reached; but every assertion in it is about the SHAPE of the
/// car's collision box — widths, aspect ratios, areas — and it never calls
/// `tick` or `flap`. Gravity cannot reach it. Meanwhile a change to
/// `carSpriteAspect` or `carWidth` would fail it immediately, so it is
/// demonstrably capable of going red.
///
/// THIS DRIFTED ONCE ALREADY, WHICH IS THE REASON FOR THE PARAGRAPH ABOVE. The
/// original judge was `test/widget_test.dart`, chosen when that file asserted
/// only that `main.dart` hands Flutter a `GameWidget`. It later grew tests that
/// tap, run the game for 120 frames and check the car is dead — at which point
/// it could see gravity perfectly well, the negative control started reporting
/// KILLED, and `--selftest` failed on a clean tree. Note what did NOT happen:
/// the tool did not quietly keep passing. A broken control that fails loudly is
/// the outcome this whole self-test exists to produce, so if the line below
/// ever starts reporting KILLED again, the fix is to find a judge that is still
/// blind to the edit — never to relax the assertion.
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
    _emit('FATAL: selftest anchor not found: $gravityDecl');
    await _outIdle();
    return false;
  }
  // Checked explicitly, because a missing judge would otherwise show up as
  // `NEGATIVE => KILLED` — a failure that reads like "the control broke" when
  // the real cause is "the file is not there".
  if (!File('$repoRoot/$negativeControlTest').existsSync()) {
    _emit('FATAL: negative control judge not found: '
        '$negativeControlTest');
    await _outIdle();
    return false;
  }

  // `label` is only for the heartbeat and the death report: it is what appears
  // as the in-flight item so a self-test that wedges says WHICH control it
  // wedged on, which is the difference between a bug report and a shrug.
  Future<TestRun> withSource(
    String label,
    String replacement,
    List<String> tests,
  ) async {
    _progress.begin('selftest', label);
    File('$repoRoot/$file')
        .writeAsStringSync(src.replaceFirst(gravityDecl, replacement), flush: true);
    final TestRun r = await runTests(flutterCmd, repoRoot, tests, timeout);
    restoreAll();
    _progress.finish('selftest');
    return r;
  }

  _emit('');
  _emit('=== SELF-TEST: can the tool produce all three verdicts? ===');
  _emit('');

  final TestRun positive =
      await withSource('POSITIVE', gravityBroken, tier1Tests);
  _emit(
    'POSITIVE  gravity 2.2 -> 22.0, judged by tier 1        '
    '=> ${_verdictLabel(positive.verdict)}   (want KILLED)',
  );
  if (positive.detail.isNotEmpty) {
    _emit('          ${positive.detail}');
  }

  final TestRun negative = await withSource(
      'NEGATIVE', gravityBroken, <String>[negativeControlTest]);
  _emit(
    'NEGATIVE  the same edit, judged by the blind test only '
    '=> ${_verdictLabel(negative.verdict)}   (want SURVIVED)',
  );
  _emit('          judge: $negativeControlTest — compiles the mutated '
      'file, cannot observe gravity');
  if (negative.verdict != Verdict.survived && negative.detail.isNotEmpty) {
    _emit('          ${negative.detail}');
  }

  final TestRun invalid =
      await withSource('INVALID', syntaxBroken, tier1Tests);
  _emit(
    'INVALID   `2.2 &&&`, judged by tier 1                  '
    '=> ${_verdictLabel(invalid.verdict)}    (want INVALID)',
  );
  if (invalid.detail.isNotEmpty) {
    _emit('          ${invalid.detail}');
  }

  final bool ok = positive.verdict == Verdict.killed &&
      negative.verdict == Verdict.survived &&
      invalid.verdict == Verdict.invalid;

  _emit('');
  _emit(ok
      ? 'SELF-TEST PASSED — the classifier is capable of all three verdicts, so '
          'a KILLED is a real observation and not a default.'
      : 'SELF-TEST FAILED — do not trust any score this tool prints.');
  await _outIdle();
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
    // State the size of the subset AND the size of the surface it was drawn
    // from, together, on one line. The ratio is the honest description of how
    // much this gate can see, and it is the number that quietly changed the
    // last time `lib/game/` grew.
    final int picked = quickSubset(all).length;
    stdout.writeln('mode: --quick — $picked of ${all.length} mutants, '
        'stratified across all ${MutOp.values.length} operator families '
        '(budget $quickBudget)');
    stdout.writeln('      a smoke test, NOT the mutation score: run without '
        '--quick for that');
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
  required List<String> teardownWarnings,
  required int drainStalls,
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

  // Printed only when it happened, but never suppressed when it did. A stalled
  // drain means at least one verdict on this page rests on output that was
  // cut off, and the direction that truncation pushes a verdict — towards
  // INVALID — is also the direction that HIDES a survivor. This line is the
  // only warning a reader gets that the score below might be missing a hole.
  if (drainStalls > 0) {
    stdout.writeln('  output drains that stalled${drainStalls.toString().padLeft(5)}   '
        'a grandchild held the pipe open; see the warnings above');
    final List<MutantResult> affected =
        results.where((MutantResult r) => r.drainStalled).toList();
    if (affected.isNotEmpty) {
      stdout.writeln('    affected mutants: '
          '${affected.map((MutantResult r) => r.mutant.id).join(', ')}');
      stdout.writeln('    treat any INVALID among these as an unproven '
          'verdict, not as a compile failure');
    }
  }
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

  // ---- teardown ---------------------------------------------------------
  // Printed as a warning and never as a failure. A temporary directory that
  // outlived the run is untidy; it is not a finding about the code, and it does
  // not change the exit code (see the contract in `_run`).
  if (teardownWarnings.isNotEmpty) {
    stdout.writeln('WARNING — cleanup left something behind (${teardownWarnings.length}):');
    for (final String w in teardownWarnings) {
      stdout.writeln('  $w');
    }
    stdout.writeln('  Harmless: the next run clears a sandbox of that name '
        'before reusing it, and takes a fresh path if it still cannot. Does '
        'not affect the exit code.');
    stdout.writeln('');
  }

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
