#!/bin/bash
set -euo pipefail

# Interactive container entrypoint.  This shares the swarm image and
# environment with autonomous agents, but leaves the human in control.

AGENT_ID="${AGENT_ID:-interactive}"
SWARM_DRIVER="${SWARM_DRIVER:-claude-code}"
SWARM_MODEL="${SWARM_MODEL:-}"
SWARM_SETUP="${SWARM_SETUP:-}"
SWARM_CONTEXT="${SWARM_CONTEXT:-full}"
SWARM_PROMPT="${SWARM_PROMPT:-}"
INJECT_GIT_RULES="${INJECT_GIT_RULES:-true}"
SWARM_INTERACTIVE_BRANCH="${SWARM_INTERACTIVE_BRANCH:?branch is required}"
SWARM_INTERACTIVE_PROFILE="${SWARM_INTERACTIVE_PROFILE:-interactive}"
SWARM_INTERACTIVE_MODE="${SWARM_INTERACTIVE_MODE:-chat}"
SWARM_RUN_CONTEXT="${SWARM_RUN_CONTEXT:-unknown}"
SWARM_CFG_PROMPT="${SWARM_CFG_PROMPT:-${SWARM_PROMPT}}"
SWARM_CFG_SETUP="${SWARM_CFG_SETUP:-${SWARM_SETUP}}"

DRIVER_FILE="/drivers/${SWARM_DRIVER}.sh"
if [ ! -f "$DRIVER_FILE" ]; then
    echo "ERROR: driver not found: ${DRIVER_FILE}" >&2
    exit 1
fi
# shellcheck disable=SC1090,SC1091
source "$DRIVER_FILE"

if ! type -t agent_interactive_run >/dev/null 2>&1; then
    echo "ERROR: driver '${SWARM_DRIVER}' has no interactive mode." >&2
    exit 1
fi

SWARM_MODEL="${SWARM_MODEL:-$(agent_default_model)}"
export SWARM_MODEL
export CLAUDE_MODEL="${SWARM_MODEL}"

GREEN=$'\033[32m'
RED=$'\033[31m'
RST=$'\033[0m'

ilog() {
    printf '%s%s interactive[%s] %s%s\n' \
        "$GREEN" "$(date +%H:%M:%S)" "$SWARM_INTERACTIVE_PROFILE" "$*" "$RST"
}

ilog_err() {
    printf '%s%s interactive[%s] %s%s\n' \
        "$RED" "$(date +%H:%M:%S)" "$SWARM_INTERACTIVE_PROFILE" "$*" "$RST"
}

write_interactive_state() {
    [ -d /workspace/.git ] || return 0
    mkdir -p /workspace/agent_logs

    local dirty=false
    if [ -n "$(git -C /workspace status --porcelain=v1 2>/dev/null)" ]; then
        dirty=true
    fi

    cat > /workspace/agent_logs/interactive_state <<STATE
branch=${SWARM_INTERACTIVE_BRANCH}
profile=${SWARM_INTERACTIVE_PROFILE}
mode=${SWARM_INTERACTIVE_MODE}
dirty=${dirty}
updated=$(date -u +%Y-%m-%dT%H:%M:%SZ)
STATE
}

print_driver_auth_hint() {
    case "$SWARM_DRIVER" in
        claude-code)
            if [ -n "${ANTHROPIC_API_KEY:-}" ] \
                    || [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] \
                    || [ -n "${ANTHROPIC_AUTH_TOKEN:-}" ]; then
                ilog "claude auth env present; verify with: claude auth status"
            else
                ilog_err "claude auth env missing; rerun launch.sh with auth"
            fi
            ;;
    esac
}

push_interactive_branch() {
    [ -d /workspace/.git ] || return 0
    cd /workspace
    write_interactive_state

    if [ -n "$(git status --porcelain=v1 2>/dev/null)" ]; then
        ilog_err "dirty worktree remains in /workspace"
        git status --short 2>/dev/null || true
    fi

    ilog "pushing ${SWARM_INTERACTIVE_BRANCH}"
    git push origin "HEAD:refs/heads/${SWARM_INTERACTIVE_BRANCH}" \
        2>&1 || ilog_err "push failed for ${SWARM_INTERACTIVE_BRANCH}"
}

finish() {
    local rc=$?
    set +e
    push_interactive_branch
    exit "$rc"
}
trap finish EXIT

GIT_USER_NAME="${GIT_USER_NAME:-swarm-agent}"
GIT_USER_EMAIL="${GIT_USER_EMAIL:-agent@swarm.local}"
git config --global user.name "$GIT_USER_NAME"
git config --global user.email "$GIT_USER_EMAIL"
# shellcheck disable=SC1091
source /signing.sh
configure_git_signing

AGENT_CLI_VERSION=$(agent_version)
export AGENT_CLI_VERSION
AGENT_CLI_NAME=$(agent_name)
export AGENT_CLI_NAME

if [ ! -d /workspace/.git ]; then
    ilog "cloning upstream"
    git clone -q /upstream /workspace
    cd /workspace
    git fetch --no-recurse-submodules origin 2>&1 || true

    if git rev-parse --verify --quiet \
            "origin/${SWARM_INTERACTIVE_BRANCH}" >/dev/null; then
        git checkout -q -B "$SWARM_INTERACTIVE_BRANCH" \
            "origin/${SWARM_INTERACTIVE_BRANCH}"
    else
        git checkout -q -B "$SWARM_INTERACTIVE_BRANCH" origin/agent-work
    fi

    if [ -f .gitmodules ]; then
        git config --file .gitmodules --get-regexp \
            'submodule\..*\.path' | while read -r key path; do
            name="${key#submodule.}"
            name="${name%.path}"
            if [ -d "/mirrors/${name}" ]; then
                git config "submodule.${name}.url" "/mirrors/${name}"
                git submodule update --init -q -- "$path"
            fi
        done
    fi

    if [ -d .claude ]; then
        case "$SWARM_CONTEXT" in
            none)
                ilog "context=none: removing .claude/"
                rm -rf .claude
                ;;
            slim)
                ilog "context=slim: keeping only .claude/CLAUDE.md"
                find .claude -mindepth 1 -maxdepth 1 \
                    ! -name CLAUDE.md -exec rm -rf {} +
                ;;
        esac
    fi

    if [ "$SWARM_CONTEXT" != "full" ]; then
        cat > .git/hooks/_strip_context <<CTXHOOK
#!/bin/bash
case "$SWARM_CONTEXT" in
    none) rm -rf .claude 2>/dev/null ;;
    slim) [ -d .claude ] && find .claude -mindepth 1 -maxdepth 1 ! -name CLAUDE.md -exec rm -rf {} + 2>/dev/null ;;
esac
CTXHOOK
        chmod +x .git/hooks/_strip_context
        for _hook in post-merge post-checkout; do
            printf '#!/bin/bash\n.git/hooks/_strip_context\n' \
                > ".git/hooks/$_hook"
            chmod +x ".git/hooks/$_hook"
        done
    fi

    if [ -n "$SWARM_SETUP" ] && [ -f "$SWARM_SETUP" ]; then
        ilog "running setup ${SWARM_SETUP}"
        sudo -E bash "$SWARM_SETUP"
        sudo chown -R "$(id -u):$(id -g)" /workspace
    fi

    agent_settings /workspace

    SWARM_VERSION=$(cat /swarm-version 2>/dev/null || echo "unknown")
    export SWARM_VERSION
    mkdir -p .git/hooks
    cat > .git/hooks/prepare-commit-msg <<'HOOK'
#!/bin/bash
if ! grep -q '^Model:' "$1"; then
    printf '\nModel: %s\nTools: swarm %s, %s %s\n' \
        "$SWARM_MODEL" "$SWARM_VERSION" "$AGENT_CLI_NAME" "$AGENT_CLI_VERSION" >> "$1"
    printf '> Run: %s\n' "$SWARM_RUN_CONTEXT" >> "$1"
    cfg="$SWARM_CFG_PROMPT"
    [ -n "$SWARM_CFG_SETUP" ] && cfg="${cfg}, ${SWARM_CFG_SETUP}"
    printf '> Cfg: %s\n' "$cfg" >> "$1"
    ctx_label="$SWARM_CONTEXT"
    [ "$ctx_label" = "none" ] && ctx_label="bare"
    [ "$SWARM_CONTEXT" != "full" ] && \
        printf '> Ctx: %s\n' "$ctx_label" >> "$1" || true
fi
HOOK
    chmod +x .git/hooks/prepare-commit-msg

    cat > .git/hooks/pre-commit <<'HOOK'
#!/bin/bash
git reset -q HEAD -- agent_logs/ .claude/settings.local.json 2>/dev/null || true
changed_subs=$(git diff --cached --diff-filter=M --name-only | while read -r path; do
    if git ls-tree HEAD -- "$path" 2>/dev/null | grep -q '^160000 '; then
        echo "$path"
    fi
done)
if [ -n "$changed_subs" ]; then
    echo "$changed_subs" | while read -r sub; do
        git reset -q HEAD -- "$sub" 2>/dev/null || true
    done
fi
HOOK
    chmod +x .git/hooks/pre-commit

    ilog "setup complete"
fi

cd /workspace
write_interactive_state

APPEND_FILE=""
if [ "$INJECT_GIT_RULES" = "true" ] && [ -f /agent-system-prompt.md ]; then
    APPEND_FILE="/agent-system-prompt.md"
fi

if [ -n "$SWARM_PROMPT" ]; then
    if [ -f "$SWARM_PROMPT" ]; then
        ilog "profile prompt: ${SWARM_PROMPT}"
    else
        ilog_err "prompt file not found: ${SWARM_PROMPT}"
    fi
else
    ilog "promptless profile"
fi

ilog "branch: ${SWARM_INTERACTIVE_BRANCH}"
case "$SWARM_INTERACTIVE_MODE" in
    shell)
        print_driver_auth_hint
        ilog "opening shell"
        bash -l
        ;;
    chat)
        print_driver_auth_hint
        ilog "starting ${AGENT_CLI_NAME}"
        agent_interactive_run "$SWARM_MODEL" "$SWARM_PROMPT" "$APPEND_FILE"
        ;;
    *)
        echo "ERROR: unknown interactive mode: ${SWARM_INTERACTIVE_MODE}" >&2
        exit 1
        ;;
esac
