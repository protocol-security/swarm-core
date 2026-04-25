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

## Commit messages

Prefer short, plain commit subjects.

Guidelines:

- Start with an uppercase imperative verb.
- Keep the subject concise.
- Do not end the subject with a period.
- Avoid semantic prefixes unless they are already used
  nearby.
- Squash `fixup!`, `squash!`, and `wip` commits before
  opening or merging a PR.

Good examples:

- Add Codex driver
- Fix swarm timeout handling
- Split driver configuration

Avoid:

- add codex driver
- Fix swarm timeout handling.
- fixup! Add Codex driver
- wip driver changes

This isn't pedantry: commit subjects flow into CHANGELOG
entries and the annotated message of each release tag, so a
clean subject saves everyone a moment of "wait, what does
this say?" months later.  Don't agonize over any single
subject though -- aim for something a teammate can skim and
you're there.

## Pull requests

Before requesting review:

- Rebase onto latest `master` -- please don't merge `master`
  into your branch.  We keep `master` linear with one merge
  commit per PR so `git log --oneline --graph` stays
  readable for everyone (the shape is "straight line, jump
  out into a feature, jump back, straight line").  Feature
  branches catch up by rebasing so their own history also
  stays a straight line for reviewers.
- Keep PRs focused and reviewable -- it's much easier to
  give a thorough review on a tight PR than a sprawling one.
- Prefer draft PRs for large or exploratory changes so
  collaborators can chime in early without it reading as a
  finished proposal.

Drafting the PR:

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
- Commit bodies: motivation, not just what changed.
- Sentences in commit bodies end with a dot.
- CI rejects `fixup!`, `squash!`, and `wip` subjects, and
  fails the PR if the branch is behind `master`.  Subject
  style otherwise (capitalization, length, trailing period)
  is guidance, not enforcement -- see "Commit messages".

<!-- CANARY: 114c1e52b479dc2795c42b655f73a15fd26d747d -->
