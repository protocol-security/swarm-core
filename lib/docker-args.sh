#!/bin/bash
# The swarmfile's docker_args: extra docker run arguments for the
# containers swarm starts (agents, post-process, interactive
# sessions), read as the exact vector docker run gets and checked
# against docker run's option grammar before anything of an engagement
# is prepared.  The check is structural: values are Docker's to check,
# when it runs, except where they would reach what swarm gives
# every container of a target (the TARGET_* variables, the snapshot at
# /target-upstream) or the labels it gives every container (the
# swarm-core. namespace).  Compatible with Bash 3.2.  Functions print
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

# The perl part of _swarm_docker_args_reserved: exit 0 when operand $2
# of kind $1 names no container path at or below /target-upstream, 1
# when it does, 2 when Docker could not parse it as a --mount value, 3
# when it is not UTF-8 (jq only writes UTF-8; utf8::decode is built in,
# where Debian ships Encode outside perl-base).  Kind mount: Docker 29
# trims the whole value (Go's strings.TrimSpace) and refuses white space
# around a key or a value, Docker 24 trims nothing; both read one CSV
# record (Go's encoding/csv: a quote opens a field only at its start,
# "" inside one is a quote, and a trailing CR before the end goes),
# split each field at its first "=" and lowercase the key with Go's
# strings.ToLower (ASCII, and U+0130 to "i": the only other letters
# whose lowercase is ASCII are U+0130 and U+212A, a "k", which no key
# here has).  Both readings must parse, and neither may
# have a target, dst or destination key whose value, cleaned as Go's
# path.Clean does, is /target-upstream or below it; the first reading
# also trims each key and value (Docker 29 refuses those, so this only
# refuses more).  Kind fields (-v, --device): every ":" field; kind
# tmpfs: what comes before the first ":"; each as given and trimmed.
_SWARM_DOCKER_RESERVED='use strict;
use warnings;
my ($kind, $v) = @ARGV;
exit 3 unless utf8::decode($v);
my $ws = q|[\x{9}-\x{D}\x{20}\x{85}\x{A0}\x{1680}\x{2000}-\x{200A}|
    . q|\x{2028}\x{2029}\x{202F}\x{205F}\x{3000}]|;
sub trim {
    my $s = shift;
    $s =~ s/\A$ws+//;
    $s =~ s/$ws+\z//;
    return $s;
}
sub reserved {
    my $p = shift;
    return 0 unless substr($p, 0, 1) eq "/";
    my @out;
    for my $c (split m{/}, $p) {
        next if $c eq "" || $c eq ".";
        if ($c eq "..") { pop @out; next; }
        push @out, $c;
    }
    return @out && $out[0] eq "target-upstream" ? 1 : 0;
}
sub record {
    my $s = shift;
    $s =~ s/\r\z//;
    return undef if $s eq "";
    my ($i, $n, @f) = (0, length $s);
    FIELD: while (1) {
        if ($i >= $n || substr($s, $i, 1) ne "\"") {
            my $j = index($s, ",", $i);
            my $field = $j >= 0 ? substr($s, $i, $j - $i) : substr($s, $i);
            return undef if index($field, "\"") >= 0;
            push @f, $field;
            if ($j >= 0) { $i = $j + 1; next FIELD; }
            return \@f;
        }
        my $field = "";
        $i++;
        while (1) {
            my $q = index($s, "\"", $i);
            return undef if $q < 0;
            $field .= substr($s, $i, $q - $i);
            $i = $q + 1;
            if ($i < $n && substr($s, $i, 1) eq "\"") {
                $field .= "\"";
                $i++;
                next;
            }
            push @f, $field;
            return \@f if $i >= $n;
            return undef if substr($s, $i, 1) ne ",";
            $i++;
            next FIELD;
        }
    }
}
sub mount_check {
    my $value = shift;
    my $hit = 0;
    for my $trimmed (1, 0) {
        my $fields = record($trimmed ? trim($value) : $value);
        return 2 unless defined $fields;
        for my $field (@$fields) {
            my ($k, $val) = split /=/, $field, 2;
            next unless defined $val;
            ($k, $val) = (trim($k), trim($val)) if $trimmed;
            $k =~ tr/A-Z/a-z/;
            $k =~ s/\x{130}/i/g;
            next unless $k eq "target" || $k eq "dst" || $k eq "destination";
            $hit = 1 if reserved($val);
        }
    }
    return $hit;
}
my $rc = 0;
if ($kind eq "mount") {
    $rc = mount_check($v);
} else {
    my @parts = $kind eq "tmpfs" ? ((split /:/, $v, 2)[0] // "")
        : split(/:/, $v, -1);
    for my $p (@parts) {
        $rc = 1 if reserved($p) || reserved(trim($p));
    }
}
exit $rc;'

# Succeed when label operand V (KEY or KEY=VALUE) has a key in the
# engine's namespace: one that starts with "swarm-core.", whatever the
# case of its letters, once any leading spaces and tabs are dropped
# (Docker 29 keeps them in the key; an older one may not).
_swarm_docker_label_reserved() {
    local k="${1%%=*}" ws=$' \t'
    while :; do
        case "$k" in
            ["$ws"]*) k="${k#?}" ;;
            *) break ;;
        esac
    done
    case "$k" in
        [Ss][Ww][Aa][Rr][Mm]-[Cc][Oo][Rr][Ee].*) return 0 ;;
    esac
    return 1
}

# Refuse element POS (1-based) of docker_args, A, when option NAME (its
# long name) with operand V would reach what swarm gives every
# container of a target: one of the five variables (an env name is what
# comes before the first "=", exactly), every variable of a file
# (--env-file) or every mount of another container (--volumes-from), or
# a mount at or below /target-upstream (_SWARM_DOCKER_RESERVED).  The
# place and the names are reserved whether or not the engagement has a
# target.  Labels in the engine's namespace (swarm-core.) are reserved
# too, and with them every label of a file (--label-file): the engine
# sets them, and callers find its containers by them.
_swarm_docker_args_reserved() {
    local pos="$1" a="$2" name="$3" v="$4" kind rc=0
    case "$name" in
        label)
            if _swarm_docker_label_reserved "$v"; then
                _swarm_docker_args_refuse "$pos" "$a" "sets a label in" \
                    "the engine's namespace (swarm-core.), which only" \
                    "swarm sets"
                return 1
            fi
            return 0 ;;
        label-file)
            _swarm_docker_args_refuse "$pos" "$a" "reads labels from a" \
                "file, which could set the engine's (swarm-core.); give" \
                "each one with --label"
            return 1 ;;
        env)
            case "${v%%=*}" in
                TARGET_REPO|TARGET_REV|TARGET_REV_BASE|TARGET_REV_BASE_REPO\
                |SWARM_TARGET_MIRROR)
                    _swarm_docker_args_refuse "$pos" "$a" "sets ${v%%=*}:" \
                        "swarm sets it from the engagement's target" \
                        "(TARGET_REPO, TARGET_REV, TARGET_REV_BASE and" \
                        "TARGET_REV_BASE_REPO go in the host environment)"
                    return 1 ;;
            esac
            return 0 ;;
        env-file)
            _swarm_docker_args_refuse "$pos" "$a" "reads variables from a" \
                "file, which could set the target's; give each one with -e" \
                "(TARGET_* go in the host environment)"
            return 1 ;;
        volumes-from)
            _swarm_docker_args_refuse "$pos" "$a" "takes every mount of" \
                "another container, which could put one at" \
                "/target-upstream; give the mounts themselves"
            return 1 ;;
        mount) kind=mount ;;
        volume|device) kind=fields ;;
        tmpfs) kind=tmpfs ;;
        *) return 0 ;;
    esac
    perl -e "$_SWARM_DOCKER_RESERVED" -- "$kind" "$v" || rc=$?
    case "$rc" in
        0) return 0 ;;
        1)
            _swarm_docker_args_refuse "$pos" "$a" "puts something at or" \
                "below /target-upstream, the place of the target's" \
                "snapshot" ;;
        2)
            _swarm_docker_args_refuse "$pos" "$a" "has a value Docker" \
                "cannot read as one CSV record (a quote may only enclose a" \
                "whole field)" ;;
        3)
            _swarm_docker_args_refuse "$pos" "$a" "has a value that is" \
                "not UTF-8 text" ;;
        *)
            _swarm_docker_args_refuse "$pos" "$a" "cannot be checked" \
                "(perl ended with status ${rc})" ;;
    esac
    return 1
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
# short options such as `-it` (give `-i` and `-t` apart).  Each operand,
# attached or not, then goes through _swarm_docker_args_reserved; `-x=V`
# gives V, as pflag reads it, and `-x=` gives "=".
swarm_docker_args_check() {
    local n="${#SWARM_DOCKER_ARGS[@]}" i=0 a name kind x rest pos v
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
                    *=*)
                        _swarm_docker_args_reserved "$pos" "$a" "$name" \
                            "${a#*=}" || return 1 ;;
                    *)
                        if [ "$kind" = value ]; then
                            if [ $((i + 1)) -ge "$n" ]; then
                                _swarm_docker_args_refuse "$pos" "$a" \
                                    "takes a value, and nothing follows it"
                                return 1
                            fi
                            i=$((i + 1))
                            _swarm_docker_args_reserved "$pos" "$a" "$name" \
                                "${SWARM_DOCKER_ARGS[$i]}" || return 1
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
                case "$x" in
                    e) name="env" ;;
                    l) name="label" ;;
                    v) name="volume" ;;
                    *) name="" ;;
                esac
                if [ -z "$rest" ]; then
                    if [ "$kind" = value ]; then
                        if [ $((i + 1)) -ge "$n" ]; then
                            _swarm_docker_args_refuse "$pos" "$a" \
                                "takes a value, and nothing follows it"
                            return 1
                        fi
                        i=$((i + 1))
                        _swarm_docker_args_reserved "$pos" "$a" "$name" \
                            "${SWARM_DOCKER_ARGS[$i]}" || return 1
                    fi
                elif [ "$rest" = "=" ] && [ "$kind" = bool ]; then
                    _swarm_docker_args_refuse "$pos" "$a" \
                        "gives a boolean option no value after '='"
                    return 1
                elif [ "$kind" = bool ] && [ "${rest#=}" = "$rest" ]; then
                    _swarm_docker_args_refuse "$pos" "$a" \
                        "groups short options: give each one apart"
                    return 1
                elif [ "$kind" = value ]; then
                    v="$rest"
                    case "$rest" in
                        =?*) v="${rest#=}" ;;
                    esac
                    _swarm_docker_args_reserved "$pos" "$a" "$name" "$v" \
                        || return 1
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
