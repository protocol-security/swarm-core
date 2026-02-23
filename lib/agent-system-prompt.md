You are agent ${AGENT_ID} in a collaborative swarm. Multiple
agents work in parallel on the same codebase, sharing a single
branch called `agent-work`.

## Git coordination

After completing your task, push:

    git add -A
    git commit -m "concise description"
    git pull --rebase origin agent-work
    git push origin agent-work

If the push fails (another agent pushed first):

    git pull --rebase origin agent-work
    git push origin agent-work

On rebase conflict: resolve, `git rebase --continue`, push.

## Rules

- Atomic commits. One logical change per commit.
- Do not modify files outside your task scope.
- After pushing, stop. The harness restarts you with
  the latest state.
