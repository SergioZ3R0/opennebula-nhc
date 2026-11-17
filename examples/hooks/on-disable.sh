#!/bin/sh
# SPDX-FileCopyrightText: 2026 SergioZ3R0
# SPDX-License-Identifier: Apache-2.0
#
# Example one-nhc on_disable hook.
#
# It is a DRY RUN by default: it only prints the migration commands. Set
# NHC_EVACUATE=1 and NHC_EVACUATE_TARGET=<host-id> to enable the real
# `onevm migrate` lines after validating storage and capacity.
#
# The controller runs hooks only in `act` mode and only when it applied the
# disable action. It passes:
#   NHC_MESSAGE, NHC_HOST, NHC_HOST_ID, NHC_STATUS,
#   NHC_ACTION, NHC_APPLIED, NHC_TIME, NHC_SAMPLE
#
# Install it as /usr/local/bin/one-nhc-on-disable (or point the hook at this
# file) and make it executable. Do not enable evacuation on local datastores
# unless you have verified that live migration is supported.

set -eu

log() {
  echo "[one-nhc on-disable] $*"
}

log "action=${NHC_ACTION:-?} host=${NHC_HOST:-?} id=${NHC_HOST_ID:-?} status=${NHC_STATUS:-?}"

if [ "${NHC_EVACUATE:-0}" != "1" ]; then
  log "evacuation disabled (set NHC_EVACUATE=1 to enable)"
  exit 0
fi

: "${NHC_EVACUATE_TARGET:?set NHC_EVACUATE_TARGET to the target host id}"

vms=$(onevm list --csv --no-header --filter "HOST=${NHC_HOST_ID}" \
  | cut -d, -f1 | sed '/^$/d')

if [ -z "${vms}" ]; then
  log "no VMs found on host ${NHC_HOST_ID}"
  exit 0
fi

for vm in ${vms}; do
  log "would migrate VM ${vm} to host ${NHC_EVACUATE_TARGET}"
  # Uncomment after validating storage, CPU compatibility and capacity:
  # onevm migrate --live "${vm}" "${NHC_EVACUATE_TARGET}"
done
