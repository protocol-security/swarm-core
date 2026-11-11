# swarm-core

N coding agents in Docker, coordinating through Git. No orchestrator and
no message passing. Formerly `claude-swarm`.

## Prerequisites

Docker, Bash 5, Git, jq, bc, perl, flock, tput, and credentials for a
driver.

## Usage

Put a `swarm.json` in your repository root, then run `launch.sh` there.

    ./launch.sh start --dashboard

- `./launch.sh wait` post-processes and harvests the agents' work.
- `./launch.sh interactive NAME` opens a human-guided session.
- `./launch.sh cleanup` deletes the engagement, keeping recovery refs.

## Drivers

Each agent CLI sits behind a driver, selected per group in `swarm.json`.

- `claude-code` (default)
- `pi`
- `codex-cli`
- `gemini-cli`

## Documentation

[USAGE.md](USAGE.md) covers configuration, commands, authentication, and
the control interface. [CHANGELOG.md](CHANGELOG.md) covers releases.

## License

[AGPL-3.0](LICENSE)
