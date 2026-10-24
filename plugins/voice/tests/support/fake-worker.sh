#!/bin/sh
# A stand-in for the speech worker (plugins/voice/worker/worker.ss), so
# tests need no model: tuna-voice-worker MODEL [LANGUAGE]. It writes its
# process id to MODEL.pid, says it is ready, then "recognizes" each line
# of its input as that line's text, with a leading space unless the line
# starts with punctuation (as the model sends ". It's"), and at the end
# of its input says " end." and that it is done. A line "final:TEXT"
# makes the last text TEXT instead and says nothing. A line "fail" makes
# it report an error and exit 1.
echo $$ > "$1.pid"
echo '{"ready":true}'
final=' end.'
while IFS= read -r line; do
  case "$line" in
    fail)
      echo '{"error":"the model broke"}'
      exit 1;;
    final:*)
      final=${line#final:}
      continue;;
    [.,?!\;:]*) text=$line;;
    *) text=" $line";;
  esac
  printf '{"text":"%s","eou":false}\n' "$text"
done
printf '{"text":"%s","eou":false}\n{"done":true}\n' "$final"
