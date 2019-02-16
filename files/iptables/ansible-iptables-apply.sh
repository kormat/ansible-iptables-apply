#!/bin/bash

# Copyright 2019 Stephen Shirley, Anapaya Systems
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# Tries to apply iptables rules safely in an automated fashion (e.g. from
# ansible). It should be run from a tmpdir.
#
# The script backs up the existing rules, applies the new rules, and
# spawns a background failsafe subshell (if the rules applied without error).
#
# The parent script then returns, and the failsafe subshell waits for a file named
# 'ok' to be created in the current dir. If it does not appear within
# $FAILSAFE_TIMEOUT seconds, it reverts to the original rules.

set -uo pipefail

# How long to wait for confirmation
: ${FAILSAFE_TIMEOUT:=10}

log() {
    echo "=======($(date -uIs))> $@"
}

usage() {
    echo "Usage: $(basename $0) {4|6} NEW_RULES"
}

check_params() {
    case "$ipver" in
        4) ipsave=iptables-save iprestore=iptables-restore;;
        6) ipsave=ip6tables-save iprestore=ip6tables-restore;;
        *) echo "ERROR: ip version must be either 4 or 6"; return 2;;
    esac
    [ -r "$newrules" ] || { log "ERROR: $newrules is not readable"; return 3; }
    $iprestore --test "$newrules" || { log "ERROR: testing $newrules failed"; return 4; }
    [ -w . ] || { log "ERROR: current directory is not writeable"; return 5; }
    [ -z "$(ls .)" ] || { log "ERROR: current directory is not empty"; return 6; }
}

apply_init() {
    $ipsave > "$origrules" || { log "ERROR: backing up existing rules failed"; return 2; }
    $iprestore --test "$origrules" || { log "ERROR: Testing existing rules failed"; return 3; }

    $iprestore "$newrules"
    ret=$?
    if [ $ret -ne 0 ]; then
        log "ERROR: applying new rules failed (rc: $ret)"
        return $ret
    fi
    log "New rules applied"
}

apply_failsafe() {
    log "Waiting for confirmation new connections can be made... "
    for i in $(seq $FAILSAFE_TIMEOUT); do
        [ -e ok ] && { log "Confirmation received"; return 0; }
        sleep 1
    done

    log "No confirmation received after $FAILSAFE_TIMEOUT seconds, reverting to original iptables rules"
    if $iprestore "$origrules"; then
        log "Successfully rolled back"
        return 255
    fi
    log "ERROR: rollback failed"
    return 2
}

if [ $# -ne 2 ]; then
    usage
    exit 1
fi

ipver="$1"; shift
newrules="$1"; shift
origrules="rules.v${ipver}.orig"

check_params || exit
# Ignore SIGHUP when connection closes - this prevents SIGHUP being sent to the
# failsafe subshell. Doing this now before any dangerous changes are made.
trap '' HUP
# Save existing rules, and apply new rules
apply_init || exit
# Flush the conntracking table, so that any changes to the mangle/nat table are
# enforced. Throw away the return code, just in case set -e gets used at some
# point - it's vital that the failsafe runs regardless.
conntrack -F || :
# Run failsafe in background, to revert to previous rules in case of failure.
(
    apply_failsafe
    # Use a .tmp file and then mv to prevent a tiny race-condition where a
    # reader could see an empty .rc file.
    echo $? > failsafe.rc.tmp
    mv failsafe.rc.tmp failsafe.rc
) &> log &
