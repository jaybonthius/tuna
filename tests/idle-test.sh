#!/bin/sh
set -eu
tuna=${1:?usage: idle-test.sh TUNA}
case $tuna in
  /*) ;;
  *) tuna=$PWD/$tuna ;;
esac
dir=$(mktemp -d "${TMPDIR:-/tmp}/tuna-idle-test.XXXXXX")
pid=
trap 'exec 3>&-; [ -n "$pid" ] && wait "$pid"; rm -rf "$dir"' EXIT

sh "$(dirname "$0")/test-home.sh" "$tuna" "$dir/library" "$dir/home"
cat > "$dir/home/.config/tuna/init.ss" <<'EOF'
(import (tuna) (timers))
(import (layout) (echo-area) (status-line))
(timers:run-after 3600 void)
(call-with-output-file (string-append (getenv "HOME") "/pid") (lambda (p) (write (get-process-id) p)))
(import (console))
EOF
mkfifo "$dir/input"
(cd "$dir" && HOME="$dir/home" TUNA_LIBRARY="$dir/library" timeout 60 "$tuna" < "$dir/input" > "$dir/output" 2>&1) &
pid=$!
exec 3> "$dir/input"
sleep 5
tuna_pid=$(cat "$dir/home/pid")
ticks() { awk '{ print $14 + $15 }' "/proc/$1/stat"; }
before=$(ticks "$tuna_pid")
sleep 3
after=$(ticks "$tuna_pid")
used=$((after - before))
# A clock tick is a hundredth of a second; an idle loop takes none.
if [ "$used" -gt 10 ]; then
  echo "$0: FAIL: an idle Tuna used $used ticks in 3 s"
  cat "$dir/output"
  exit 1
fi
echo "$0: ok"
