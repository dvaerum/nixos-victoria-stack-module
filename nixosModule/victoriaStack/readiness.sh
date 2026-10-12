# Usage: readiness <unit> <deadline-seconds> http|tcp <target>
#
# ExecStartPost probe: ready when the target answers; fails at once when the
# unit's main process is gone, and when the deadline passes. The binaries signal
# readiness neither by sd_notify nor by socket activation (docs/decisions/0015),
# so the probe is the signal and the main process dying is the event that ends it.
unit=$1
deadline=$2
kind=$3
target=$4

# systemd sets $MAINPID for ExecStartPost of a Type=simple unit.
if [ -z "${MAINPID:-}" ]; then
  echo "$unit: MAINPID is not set, cannot tell whether the main process is alive" >&2
  exit 1
fi

while true; do
  # Only ESRCH means gone. Between systemd's fork and its switch to the unit's
  # user the main process still belongs to root, and kill answers EPERM (seen
  # in a real boot: a healthy unit failed on it).
  if ! reason=$(kill -0 "$MAINPID" 2>&1) && [[ $reason == *"No such process"* ]]; then
    echo "$unit: main process exited before becoming ready (MAINPID=$MAINPID)" >&2
    exit 1
  fi

  remaining=$((deadline - SECONDS))
  if [ "$remaining" -le 0 ]; then
    echo "$unit: not ready after ${deadline}s" >&2
    exit 1
  fi
  attempt=$((remaining < 2 ? remaining : 2))

  # wait4x exits 0 when ready and 124 when its --timeout passes without a
  # connection; any other code (usage error) must not be retried until the deadline.
  rc=0
  wait4x "$kind" "$target" --timeout "${attempt}s" --interval 1s --quiet || rc=$?
  case $rc in
  0) exit 0 ;;
  124) ;;
  *)
    echo "$unit: wait4x $kind $target failed with exit code $rc" >&2
    exit "$rc"
    ;;
  esac
done
