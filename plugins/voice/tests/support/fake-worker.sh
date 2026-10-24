#!/bin/sh
# A stand-in for the speech worker (plugins/voice/worker/worker.ss), so
# tests need no model: tuna-voice-worker MODEL [LANGUAGE]. It writes its
# process id to MODEL.pid, says it is ready, then "recognizes" each line
# of its input as that line's text, and at the end of its input says
# " end." and that it is done. A line "fail" makes it report an error and
# exit 1.
echo $$ > "$1.pid"
echo '{"ready":true}'
while IFS= read -r line; do
  if [ "$line" = fail ]; then
    echo '{"error":"the model broke"}'
    exit 1
  fi
  printf '{"text":" %s","eou":false}\n' "$line"
done
printf '{"text":" end.","eou":false}\n{"done":true}\n'
