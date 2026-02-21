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

## Quality bars (non-procedural)

- Wrap commit bodies, docs, and examples to 79 chars.
- Prefer one logical change per commit.
- When possible, use curly braces; avoid one-line conditionals or loops.
- Avoid vague filler verbs; prefer direct, concrete wording.
- Comments must end with a dot.
- Commit subjects: imperative, specific (e.g., "Add fuzz target for X").
- Commit bodies: explain motivation/impact, not just what changed.
- Sentences in commit bodies must end with a dot.
