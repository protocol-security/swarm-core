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

       ## Changes
       - Per-file summary: what changed and why.

       ## Test plan
       - [ ] Concrete verification steps.

4. 3-6 summary bullets. Group related commits.
5. Test plan: runnable commands or observable behaviors.

## Linting

- `shellcheck -s bash` on all `.sh` files before committing.
- Only SC2016 (intentional single-quote) and SC2317 (trap
  handlers) info-level notices are acceptable.

## Documentation

- Every feature change must update relevant `.md` files
  (README.md, USAGE.md, CLAUDE.md).
- Update CHANGELOG.md with a new entry under the current
  version when adding features, fixes, or notable changes.
- Check thoroughly: add new fields to tables, update
  examples, add test cases to matrices, remove stale
  references.

## Releases

- Version-bump commit subject: `Bump x.y.z -- <summary>`.
  Use two ASCII hyphens, no colon, no em dash.  Do not use
  `Release x.y.z:` or `Ship x.y.z:`.
- Version-bump commits touch only `VERSION` and
  `CHANGELOG.md`.  Code lives in its own preceding commit.
- After every merge to master that changes VERSION,
  immediately create an annotated tag on the merge commit:
  `git tag -a v$VERSION $MERGE_COMMIT -m "v$VERSION — summary"`.
- Verify: `git tag -l "v$(cat VERSION)"`.  If the tag is
  missing, create it before doing anything else.
- Always prompt the user to push: `git push origin --tags`.
- Never skip tagging.  A version bump without a tag is
  incomplete.

## Quality bars

- Wrap to 79 chars.
- One logical change per commit.
- Curly braces over one-line conditionals.
- Direct wording, no filler verbs.
- Comments end with a dot.
- Commit subjects: imperative, specific.  Max 72 chars,
  start with uppercase, no trailing period, no
  `fixup!`/`squash!` prefixes (enforced by CI).
- Commit bodies: motivation, not just what changed.
- Sentences in commit bodies end with a dot.

<!-- CANARY: 114c1e52b479dc2795c42b655f73a15fd26d747d -->
