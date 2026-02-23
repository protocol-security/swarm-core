# Global Context (Always-on)

## Epistemics

- Do not fabricate results, measurements, outputs, behaviors,
  or claims of execution.
- Never invent tool results, filesystem state, repo state,
  commit history, build status, or runtime behavior.
- If information is missing or ambiguous, state it and stop.
- Do not guess, interpolate, or approximate unknown facts.
- Separate observation from inference; label inference.
- Prefer real code paths over synthetic examples.
- Treat panics, resource exhaustion, undefined behavior, and
  crashes as security-relevant until proven otherwise.

## Testing

- All tests must pass (`./tests/test.sh --all`).
- `./tests/test.sh --unit` for unit tests only.
- `./tests/test.sh --help` for flags.

## Pull requests

1. Run `git diff --stat origin/master..HEAD` and
   `git log --oneline origin/master..HEAD`.
2. Title: imperative, concise.
3. Body:

       ## Summary
       - Bullet per logical change. What and why.

       ## Test plan
       - [ ] Concrete verification steps.

4. 3-6 summary bullets. Group related commits.
5. Test plan: runnable commands or observable behaviors.

## Linting

- `shellcheck -s bash` on all `.sh` files before committing.
- Only SC2016 (intentional single-quote) and SC2317 (trap
  handlers) info-level notices are acceptable.
- `claude-lint run.sh` to check `.claude/CLAUDE.md` formatting.

## Quality bars

- Wrap to 79 chars.
- One logical change per commit.
- Curly braces over one-line conditionals.
- Direct wording, no filler verbs.
- Comments end with a dot.
- Commit subjects: imperative, specific.
- Commit bodies: motivation, not just what changed.
- Sentences in commit bodies end with a dot.
