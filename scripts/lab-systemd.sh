#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 SergioZ3R0
# SPDX-License-Identifier: Apache-2.0
#
# Run the real one-nhc systemd units against an opennebula-lab frontend.
#
# This creates a disposable sidecar container that:
#   - uses the same image as the lab frontend,
#   - shares the frontend network namespace (so it talks to the real oned),
#   - reads the frontend one_auth volume read-only,
#   - runs systemd as PID 1,
#   - installs one-nhc and its units, and starts the controller timer.
#
# It does not modify the lab's docker-compose.yml or the frontend entrypoint.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_DIR=$(cd "$SCRIPT_DIR/.." && pwd)

LAB_FE_CONTAINER=${LAB_FE_CONTAINER:-one-lab-frontend}
SYSTEMD_CONTAINER=${SYSTEMD_CONTAINER:-one-nhc-systemd}
ONE_NHC_CONFIG=${ONE_NHC_CONFIG:-$REPO_DIR/etc/one-nhc.conf}

usage() {
  cat <<EOF
Usage: $(basename "$0") <command>

Commands:
  up       create the systemd sidecar and start the one-nhc timer
  status   show the timer, service, journal and state
  logs     follow the controller journal
  shell    open a shell in the sidecar
  down     remove the sidecar

Environment:
  LAB_FE_CONTAINER   frontend container (default: one-lab-frontend)
  SYSTEMD_CONTAINER  sidecar container  (default: one-nhc-systemd)
  ONE_NHC_CONFIG     config to install  (default: $REPO_DIR/etc/one-nhc.conf)
EOF
}

die() {
  echo "error: $*" >&2
  exit 1
}

require_lab() {
  docker inspect "$LAB_FE_CONTAINER" >/dev/null 2>&1 ||
    die "container '$LAB_FE_CONTAINER' not found; start the lab first"
  [ "$(docker inspect -f '{{.State.Running}}' "$LAB_FE_CONTAINER")" = "true" ] ||
    die "container '$LAB_FE_CONTAINER' is not running"
}

require_sidecar() {
  docker inspect "$SYSTEMD_CONTAINER" >/dev/null 2>&1 ||
    die "container '$SYSTEMD_CONTAINER' not found; run '$(basename "$0") up' first"
  [ "$(docker inspect -f '{{.State.Running}}' "$SYSTEMD_CONTAINER")" = "true" ] ||
    die "container '$SYSTEMD_CONTAINER' is not running"
}

write_prepare_script() {
  local path=$1

  cat > "$path" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

REPO=/opt/opennebula-nhc
CONFIG=/opt/one-nhc.conf

# This sidecar shares the network with the frontend and is ephemeral: mask
# units that would conflict or cannot work without a real kernel.
for unit in \
  ssh.service ssh.socket sshd.service sshd.socket \
  apt-daily.timer apt-daily-upgrade.timer \
  fstrim.timer dpkg-db-backup.timer \
  systemd-modules-load.service; do
  ln -sf /dev/null "/etc/systemd/system/$unit"
done

install -d /usr/local/lib/one-nhc /etc/one-nhc /etc/systemd/system
rm -rf /usr/local/lib/one-nhc/lib /usr/local/lib/one-nhc/checks.d
cp -r "$REPO/lib" "$REPO/checks.d" /usr/local/lib/one-nhc/
install -m 0755 "$REPO/bin/one-nhc" /usr/local/bin/one-nhc
install -m 0644 "$CONFIG" /etc/one-nhc/one-nhc.conf
install -m 0644 "$REPO/systemd/one-nhc-controller.service" /etc/systemd/system/
install -m 0644 "$REPO/systemd/one-nhc-controller.timer" /etc/systemd/system/

# The frontend volume is mounted read-only: make the auth path explicit.
install -d /etc/systemd/system/one-nhc-controller.service.d
printf '%s\n' \
  '[Service]' \
  'Environment=ONE_AUTH=/var/lib/one/.one/one_auth' \
  > /etc/systemd/system/one-nhc-controller.service.d/lab.conf

# Enable the timer before systemd starts (systemctl enable needs a running
# systemd, so create the wants symlink directly).
install -d /etc/systemd/system/timers.target.wants
ln -sf /etc/systemd/system/one-nhc-controller.timer \
  /etc/systemd/system/timers.target.wants/one-nhc-controller.timer

exec /lib/systemd/systemd
EOF
}

wait_systemd() {
  local state

  for _ in $(seq 1 30); do
    state=$(docker exec "$SYSTEMD_CONTAINER" systemctl is-system-running 2>/dev/null || true)
    case "$state" in
      running | degraded) return 0 ;;
    esac
    sleep 1
  done

  docker logs "$SYSTEMD_CONTAINER" >&2 || true
  die "systemd did not become ready in '$SYSTEMD_CONTAINER'"
}

cmd_up() {
  require_lab

  local image config_path prepare
  image=$(docker inspect -f '{{.Config.Image}}' "$LAB_FE_CONTAINER")
  config_path=$(cd "$(dirname "$ONE_NHC_CONFIG")" && pwd)/$(basename "$ONE_NHC_CONFIG")
  [ -f "$config_path" ] || die "config not found: $config_path"

  prepare=$(mktemp "${TMPDIR:-/tmp}/one-nhc-systemd.XXXXXX.sh")
  write_prepare_script "$prepare"
  trap 'rm -f "$prepare"' EXIT

  docker rm -f "$SYSTEMD_CONTAINER" >/dev/null 2>&1 || true

  docker run -d \
    --name "$SYSTEMD_CONTAINER" \
    --privileged \
    --cgroupns=host \
    -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
    --tmpfs /run \
    --tmpfs /run/lock \
    --network "container:$LAB_FE_CONTAINER" \
    --volumes-from "$LAB_FE_CONTAINER:ro" \
    --no-healthcheck \
    -v "$REPO_DIR:/opt/opennebula-nhc:ro" \
    -v "$config_path:/opt/one-nhc.conf:ro" \
    -v "$prepare:/tmp/one-nhc-systemd-prepare.sh:ro" \
    --entrypoint /bin/bash \
    "$image" /tmp/one-nhc-systemd-prepare.sh >/dev/null

  rm -f "$prepare"
  trap - EXIT

  wait_systemd

  docker exec "$SYSTEMD_CONTAINER" systemctl enable --now one-nhc-controller.timer >/dev/null
  # Run once now: the timer's first OnBootSec tick may be up to 2 minutes away.
  docker exec "$SYSTEMD_CONTAINER" systemctl start one-nhc-controller.service || true

  echo "one-nhc systemd sidecar is up: $SYSTEMD_CONTAINER"
  echo "Image:  $image"
  echo "Config: $config_path"
  echo
  cmd_status
  echo
  echo "Next timer run:"
  docker exec "$SYSTEMD_CONTAINER" \
    systemctl list-timers one-nhc-controller.timer --no-pager | sed -n '1,3p'
}

cmd_status() {
  require_sidecar

  docker exec "$SYSTEMD_CONTAINER" systemctl status one-nhc-controller.timer --no-pager || true
  echo
  docker exec "$SYSTEMD_CONTAINER" systemctl status one-nhc-controller.service --no-pager || true
  echo
  docker exec "$SYSTEMD_CONTAINER" journalctl -u one-nhc-controller.service -n 10 --no-pager || true
  echo
  docker exec "$SYSTEMD_CONTAINER" sh -c \
    'ls -la /var/lib/one-nhc 2>/dev/null; echo; cat /var/lib/one-nhc/state.json 2>/dev/null' || true
}

cmd_logs() {
  require_sidecar
  docker exec "$SYSTEMD_CONTAINER" journalctl -u one-nhc-controller.service -f
}

cmd_shell() {
  require_sidecar
  docker exec -it "$SYSTEMD_CONTAINER" bash
}

cmd_down() {
  docker rm -f "$SYSTEMD_CONTAINER" >/dev/null 2>&1 || true
  echo "removed $SYSTEMD_CONTAINER"
}

case "${1:-}" in
  up) cmd_up ;;
  status) cmd_status ;;
  logs) cmd_logs ;;
  shell) cmd_shell ;;
  down) cmd_down ;;
  -h | --help | help) usage ;;
  "")
    usage
    exit 1
    ;;
  *)
    usage
    exit 1
    ;;
esac
