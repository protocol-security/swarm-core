#!/bin/bash
# The swarmfile's docker_args: extra docker run arguments for the
# containers launch.sh starts (agents, post-process, interactive
# sessions), read as the exact vector docker run gets and checked
# against docker run's option grammar before anything of an engagement
# is prepared.  The check is structural: values are Docker's to check,
# when it runs.  Compatible with Bash 3.2.  Functions print
# "ERROR: ..." and return 1 on refusal.

# docker run's options, as Docker 24.0.9 or 29.8.2 registers them
# (docker/cli's cli/command/container sources at those tags; the list,
# with its provenance, is tests/fixtures/docker-run-options.txt): those
# that take a value, the boolean ones, then the short forms of each kind.
# Hidden aliases, deprecated and Windows-only options are there because
# Docker parses them.  An option newer than 29.8.2 is refused until this
# table has it.
SWARM_DOCKER_VALUE_OPTS=" add-host annotation attach blkio-weight
 blkio-weight-device cap-add cap-drop cgroup-parent cgroupns cidfile
 cpu-count cpu-percent cpu-period cpu-quota cpu-rt-period cpu-rt-runtime
 cpu-shares cpus cpuset-cpus cpuset-mems detach-keys device
 device-cgroup-rule device-read-bps device-read-iops device-write-bps
 device-write-iops dns dns-opt dns-option dns-search domainname
 entrypoint env env-file expose gpus group-add health-cmd
 health-interval health-retries health-start-interval health-start-period
 health-timeout hostname io-maxbandwidth io-maxiops ip ip6 ipc isolation
 kernel-memory label label-file link link-local-ip log-driver log-opt
 mac-address memory memory-reservation memory-swap memory-swappiness
 mount name net net-alias network network-alias oom-score-adj pid
 pids-limit platform publish pull restart runtime security-opt shm-size
 stop-signal stop-timeout storage-opt sysctl tmpfs ulimit umask user
 userns uts volume volume-driver volumes-from workdir "
SWARM_DOCKER_BOOL_OPTS=" detach disable-content-trust help init
 interactive no-healthcheck oom-kill-disable privileged publish-all quiet
 read-only rm sig-proxy tty use-api-socket "
SWARM_DOCKER_SHORT_VALUE="acehlmpuvw"
SWARM_DOCKER_SHORT_BOOL="diPqt"

# Print "value", "bool" or nothing for long option NAME (no dashes).
# Names are lowercase letters, digits and dashes, which also keeps two
# neighbours in the lists from passing for one name.
_swarm_docker_long_kind() {
    case "$1" in
        ''|*[!abcdefghijklmnopqrstuvwxyz0123456789-]*) return 0 ;;
    esac
    case "$SWARM_DOCKER_VALUE_OPTS" in
        *[[:space:]]"$1"[[:space:]]*) echo value; return 0 ;;
    esac
    case "$SWARM_DOCKER_BOOL_OPTS" in
        *[[:space:]]"$1"[[:space:]]*) echo bool; return 0 ;;
    esac
}

# Print "value", "bool" or nothing for short option letter X.
_swarm_docker_short_kind() {
    case "$1" in
        [a-zA-Z]) ;;
        *) return 0 ;;
    esac
    case "$SWARM_DOCKER_SHORT_VALUE" in
        *"$1"*) echo value; return 0 ;;
    esac
    case "$SWARM_DOCKER_SHORT_BOOL" in
        *"$1"*) echo bool; return 0 ;;
    esac
}

# Fill SWARM_DOCKER_ARGS with exactly the strings of CONFIG's docker_args
# array, read once and checked in that one copy: CONFIG one JSON
# document, docker_args an array whose elements are non-empty strings
# holding no newline and no NUL.  An absent or null docker_args is empty.
swarm_docker_args_read() {
    local config="$1" json bad n i el
    SWARM_DOCKER_ARGS=()
    if ! json=$(jq -c -s 'if length == 1 then .[0].docker_args
            else error("not one JSON document") end' "$config"); then
        echo "ERROR: cannot read docker_args in ${config} (one JSON" \
             "document)." >&2
        return 1
    fi
    [ "$json" != null ] || return 0
    if ! bad=$(jq -r 'if type != "array" then "-1\tis not an array"
            else first(to_entries[] | .key as $k | .value as $v
                | if ($v | type) != "string" then "\($k)\tis not a string"
                  elif $v == "" then "\($k)\tis empty"
                  elif ($v | explode | any(. == 10)) then
                      "\($k)\tholds a newline"
                  elif ($v | explode | any(. == 0)) then "\($k)\tholds a NUL"
                  else empty end) // "" end' <<< "$json"); then
        echo "ERROR: cannot read docker_args in ${config}." >&2
        return 1
    fi
    if [ -n "$bad" ]; then
        case "$bad" in
            -1*) echo "ERROR: docker_args in ${config} is not an array of" \
                      "strings." >&2 ;;
            *) echo "ERROR: docker_args element $(( ${bad%%$'\t'*} + 1 ))" \
                    "in ${config} ${bad#*$'\t'}: each element is one" \
                    "docker run argument." >&2 ;;
        esac
        return 1
    fi
    n=$(jq 'length' <<< "$json") || return 1
    case "$n" in
        ''|*[!0123456789]*)
            echo "ERROR: cannot read docker_args in ${config}." >&2
            return 1 ;;
    esac
    i=0
    while [ "$i" -lt "$n" ]; do
        el=$(jq -r --argjson i "$i" '.[$i]' <<< "$json") || return 1
        SWARM_DOCKER_ARGS+=("$el")
        i=$((i + 1))
    done
}

# Refuse element POS (1-based) of docker_args, A, for REASON (the rest
# of the arguments).
_swarm_docker_args_refuse() {
    local pos="$1" a="$2"
    shift 2
    echo "ERROR: docker_args element ${pos} ($(printf '%q' "$a")) $*." >&2
    return 1
}

# Check SWARM_DOCKER_ARGS against docker run's options: where an option
# is expected, `--name=value` or `--name` with a known name, `-x=V`, `-x`
# or `-xV` with a known letter; an option that takes a value and has none
# attached takes the next element, whatever it holds, as its operand.
# Refused: an unknown option, `--help` (in any spelling: no part of a
# swarm's containers), `--`, `-` alone or anything else that is no option
# (a positional argument ends docker run's options before the engine's
# own), an option taking a value with nothing after it, `-x=` for a
# boolean x (Docker reads the "=" as another option), and a group of
# short options such as `-it` (give `-i` and `-t` apart).
swarm_docker_args_check() {
    local n="${#SWARM_DOCKER_ARGS[@]}" i=0 a name kind x rest pos
    while [ "$i" -lt "$n" ]; do
        a="${SWARM_DOCKER_ARGS[$i]}"
        pos=$((i + 1))
        case "$a" in
            --)
                _swarm_docker_args_refuse "$pos" "$a" \
                    "is '--', which would end docker run's options"
                return 1 ;;
            --*)
                name="${a#--}"
                name="${name%%=*}"
                kind=""
                [ -z "$name" ] || kind=$(_swarm_docker_long_kind "$name")
                if [ -z "$kind" ]; then
                    _swarm_docker_args_refuse "$pos" "$a" \
                        "is no docker run option this engine knows"
                    return 1
                fi
                if [ "$name" = help ]; then
                    _swarm_docker_args_refuse "$pos" "$a" \
                        "asks for docker run's help, not a container"
                    return 1
                fi
                case "$a" in
                    *=*) ;;
                    *)
                        if [ "$kind" = value ]; then
                            if [ $((i + 1)) -ge "$n" ]; then
                                _swarm_docker_args_refuse "$pos" "$a" \
                                    "takes a value, and nothing follows it"
                                return 1
                            fi
                            i=$((i + 1))
                        fi ;;
                esac ;;
            -?*)
                x="${a:1:1}"
                rest="${a:2}"
                kind=$(_swarm_docker_short_kind "$x")
                if [ -z "$kind" ]; then
                    _swarm_docker_args_refuse "$pos" "$a" \
                        "is no docker run option this engine knows"
                    return 1
                fi
                if [ -z "$rest" ]; then
                    if [ "$kind" = value ]; then
                        if [ $((i + 1)) -ge "$n" ]; then
                            _swarm_docker_args_refuse "$pos" "$a" \
                                "takes a value, and nothing follows it"
                            return 1
                        fi
                        i=$((i + 1))
                    fi
                elif [ "$rest" = "=" ] && [ "$kind" = bool ]; then
                    _swarm_docker_args_refuse "$pos" "$a" \
                        "gives a boolean option no value after '='"
                    return 1
                elif [ "$kind" = bool ] && [ "${rest#=}" = "$rest" ]; then
                    _swarm_docker_args_refuse "$pos" "$a" \
                        "groups short options: give each one apart"
                    return 1
                fi ;;
            *)
                _swarm_docker_args_refuse "$pos" "$a" \
                    "is no option where docker run expects one (a" \
                    "positional argument would end its options before the" \
                    "engine's own)"
                return 1 ;;
        esac
        i=$((i + 1))
    done
}
