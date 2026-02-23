# Global Context (Always-on)

Only this layer is always-on. Agents, skills, and references are
elective.

## Epistemics

- Do not fabricate results, measurements, outputs, behaviors, or claims of
  execution.
- Never invent or infer tool results, filesystem state, repository state,
  commit history, build status, runtime behavior, or system configuration.
- If required information is missing, unknown, ambiguous, or cannot be
  verified directly from provided context, state this explicitly and stop.
- Do not guess, interpolate, “fill in”, or approximate unknown facts.
- Separate direct observation from inference and label inference explicitly.
- Prefer real, production code paths over synthetic or hypothetical examples.
- Treat panics, resource exhaustion, undefined behavior, and crashes as
  security-relevant until proven otherwise.

## Testing

- All tests must pass (`./test.sh --all`).
- `./test.sh --unit` runs unit tests only (no Docker/API key).
- `./test.sh --help` shows available flags.
- Integration matrix covers effort levels (`low`, `medium`, `high`)
  via env var and per-agent config.

## Pull requests

When asked to prepare a PR title and body:

1. Run `git diff --stat origin/master..HEAD` and
   `git log --oneline origin/master..HEAD` to understand scope.
2. Title: imperative, concise, covers the main themes
   (e.g., "Add effort level support, cache column, and test
   improvements").
3. Body format:

```
## Summary
- Bullet per logical change. Focus on what and why, not
  per-file diffs. Wrap to 79 chars.

## Test plan
- [ ] Checklist of concrete verification steps.
```

4. Keep summary bullets to 3-6. Group related commits into
   one bullet rather than listing every commit.
5. Test plan items should be runnable commands or observable
   behaviors, not vague ("passes" not "looks good").

## Quality bars (non-procedural)

- Wrap commit bodies, docs, and examples to 79 chars.
- Prefer one logical change per commit.
- When possible, use curly braces; avoid one-line conditionals or loops.
- Avoid vague filler verbs; prefer direct, concrete wording.
- Comments must end with a dot.
- Commit subjects: imperative, specific (e.g., "Add fuzz target for X").
- Commit bodies: explain motivation/impact, not just what changed.
- Sentences in commit bodies must end with a dot.
