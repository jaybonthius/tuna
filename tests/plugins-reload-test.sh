#!/bin/sh
# A reload of the plugin manager stops the task that asked for it and
# starts the configuration again, so it runs in a Tuna of its own.
set -eu
tuna=${1:?usage: plugins-reload-test.sh TUNA}
case $tuna in
  /*) ;;
  *) tuna=$PWD/$tuna ;;
esac
dir=$(mktemp -d "${TMPDIR:-/tmp}/tuna-plugins-reload-test.XXXXXX")
trap 'rm -rf "$dir"' EXIT

sh "$(dirname "$0")/test-home.sh" "$tuna" "$dir/library" "$dir/home"
cp "$(dirname "$0")/undo-log/home/.config/tuna/lib/web.sls" "$dir/home/.config/tuna/lib/"
cat > "$dir/home/.config/tuna/init.ss" <<'EOF'
(import (tuna) (plugins) (options) (timers))
(use-plugin buffers)
(use-plugin commands)
(use-plugin files)
(use-plugin modes)
(options:set! files:confirm-exit? #t)
(let* ([home (getenv "HOME")]
       [reads (string-append home "/reads")]
       [n (if (file-exists? reads) (call-with-input-file reads read) 0)])
  (call-with-output-file reads (lambda (p) (write (+ n 1) p)) 'replace)
  (if (= n 0)
      (timers:run-after 0.2 (lambda () (reload-modules! '((plugins)))))
      (timers:run-after 0.2
        (lambda ()
          (call-with-output-file (string-append home "/setting")
            (lambda (p) (write (files:confirm-exit?) p)) 'replace)
          (exit)))))
EOF
(cd "$dir" && HOME="$dir/home" TUNA_LIBRARY="$dir/library" timeout 60 "$tuna" < /dev/null > "$dir/output" 2>&1) || true
reads=$(cat "$dir/home/reads" 2>/dev/null || echo none)
setting=$(cat "$dir/home/setting" 2>/dev/null || echo none)
if [ -s "$dir/output" ] || [ "$reads" != 2 ] || [ "$setting" != "#t" ]; then
  echo "$0: FAIL: configuration read $reads times, setting $setting after the reload"
  cat "$dir/output"
  exit 1
fi
echo "$0: ok"
