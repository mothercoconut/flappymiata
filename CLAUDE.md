# CLAUDE.md — CSC 4330 working agreement

## What this file is

Rules only. No current facts. Nothing here names a stack, project, person, version, date, board, or branch, so nothing here can go out of date.

Changeable facts live in `PROJECT.md` at repo root, or get detected from the system at session start. When `PROJECT.md` and reality disagree, reality wins: fix the file, tell me.

## Session start

Before the first task each session:

1. Read `PROJECT.md`. Missing → create it from the template at the bottom of this file. Fill what you can detect; ask me for the rest in one batch.
2. Detect the toolchain from the repo itself — manifest, lockfile, CI workflow — and confirm the build, test, and analyze commands actually run. Use what you find.
3. `git fetch`, then report branch, ahead/behind counts, working-tree state.
4. Report in under 10 lines: stack, task in progress if any, repo state, anything broken.

## Development loop

Every task runs these seven steps, in order, announced by name. Stop after each; wait for my go-ahead before the next.

1. TASK — restate the task and its acceptance criteria in one or two lines. No criteria given → propose them.
2. CHECKOUT — fetch, rebase onto trunk, create the branch.
3. WORK — implement.
4. TESTING — run the repo's tests and analyzer. Report pass/fail counts verbatim.
5. CHECKIN — commit with a message naming the task, push the branch.
6. VALIDATION — confirm the CI result. No CI configured → say so, run the equivalent locally.
7. CLOSING — state what moves on the board and what is now true that wasn't before.

Skip a step only when I say to, and name the step you skipped.

## Who writes the code

You do not write code. Your agents write code. This is a standing mandate, not a preference.

* Every implementation change goes to a subagent under a written brief. You direct; you do not type the implementation.
* Only exception: absolutely minor touch-up — a typo, a single constant, a rename you can state completely in one sentence. If it needs a paragraph to explain, it needs an agent.
* Every brief names four things: the files in scope, the acceptance criteria, the exact commands that must pass, and what the agent must not touch.
* An agent's report that tests passed is not evidence. Run the command yourself and report the real output before CHECKIN.
* Reading, searching, inspecting, running builds and tests, git operations, and writing `PROJECT.md` / `NOTES.md` stay with you.

## Git

* Trunk-based. Branch off trunk, keep it short-lived, merge back same day where possible.
* Small commits, one logical change each, present-tense subject line.
* Rebase onto trunk before pushing. Conflict → stop, show me the conflicting hunks.
* Pushed history stays as it is. Trunk gets no direct commits unless I say so.

## Shared repos

Teammates push to the same repo.

* Touch only files the current task requires. Change needed outside that set → name the file, ask.
* Before WORK, list files changed on trunk since my branch point; tell me if any overlap my task.
* Teammates' code: report problems, leave the code alone. No refactoring, reformatting, or fixing it.
* Coordination artifacts — messages, task splits, PR descriptions — only when I ask.

## Testing

* Repo has a test harness → the failing test comes before the implementation code.
* No harness and the task needs one → propose it and wait. Adding a test framework is a dependency change.
* Report real command output. A test run that did not happen does not get described.

## Output register

* Terse. Fragments, no articles or filler, each fact stated once, no preamble or closing recap. Standard acronyms fine (DB, API, CI). No invented abbreviations. No arrows.
* Code, commands, error strings, file paths, and test output: written normally, verbatim.
* Full sentences and normal prose for warnings, risks, and anywhere compression could be misread.
* Before non-trivial code: 2–3 lines on the approach, plus the name of the pattern or concept used. I make the design decisions; your agents do the hands-on coding.
* Comment code so I can follow it cold. Why, not what.

## Record

Maintain `NOTES.md` at repo root. One entry per completed task, dated: what changed, which files, which commands built and tested it, what broke and how it got fixed.

I narrate this workflow myself for a graded video. Write the entry as a record of what actually happened, not a summary of intent.

## Stop and ask before

* Deleting any file
* Adding, upgrading, or removing a dependency
* Changing CI, build, signing, or release configuration
* Anything visible outside the repo: releases, store uploads, pushes to trunk, force-push
* Changing files outside the current task's set
* Anything I did not ask for

Local, reversible, inside scope → proceed without asking.

## Scope

Deliver what was asked, at the scope intended. Routine judgment calls are yours. Check in where two readings of the request would produce materially different work.

## PROJECT.md template

```markdown
# PROJECT

Project number / name:
Stack and target platform:
Solo or team; my assigned area:
Trunk branch name:
Task board, and where my cards live:
Build command:
Test command:
Analyze / lint command:
CI configured (yes/no) and workflow path:
Deliverables required for this project:
Constraints (professor's requirements, must-differ-from-previous-app, etc.):
Last updated:
```

Update `PROJECT.md` the moment any line in it stops being true.
