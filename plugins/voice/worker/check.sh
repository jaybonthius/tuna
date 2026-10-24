#!/usr/bin/env bash
# Pipe recorded speech through the speech worker in 100 ms chunks, either at
# real-time pace (as a microphone would send it) or at full speed, and time
# every line the worker writes.
#
# Usage: check.sh WORKER MODEL SPEECH.f32 paced|full [LANGUAGE]
# SPEECH.f32 is raw float32 little-endian mono 16 kHz audio. Audio starts
# once the worker reports {"ready":true}. Each line is printed with the time
# since the worker started and the seconds of audio sent so far.
set -euo pipefail

[[ $# == 4 || $# == 5 ]] || { echo 'Usage: check.sh WORKER MODEL SPEECH.f32 paced|full [LANGUAGE]' >&2; exit 2; }
worker=$1 model=$2 speech=$3 pace=$4
[[ $pace == paced || $pace == full ]] || { echo "check.sh: pace must be paced or full, not $pace" >&2; exit 2; }
arguments=("$model")
[[ $# == 5 ]] && arguments+=("$5")

chunk_bytes=6400 # 100 ms: 1600 samples of 4 bytes
bytes_per_second=64000
speech_bytes=$(stat -c %s "$speech")
chunks=$(( (speech_bytes + chunk_bytes - 1) / chunk_bytes ))

microseconds() { echo "${EPOCHREALTIME/./}"; }
seconds() {
  local sign='' value=$1
  (( value < 0 )) && sign=- value=$(( -value ))
  printf '%s%d.%03d' "$sign" $(( value / 1000000 )) $(( value % 1000000 / 1000 ))
}

directory=$(mktemp -d)
worker_pid='' feeder_pid=''
cleanup() {
  [[ -n $feeder_pid ]] && kill "$feeder_pid" 2>/dev/null
  [[ -n $worker_pid ]] && kill "$worker_pid" 2>/dev/null
  rm -rf "$directory"
}
trap cleanup EXIT
mkfifo "$directory/audio" "$directory/lines"

start=$(microseconds)
"$worker" "${arguments[@]}" <"$directory/audio" >"$directory/lines" 2>"$directory/stderr" &
worker_pid=$!
exec {to_worker}>"$directory/audio" {from_worker}<"$directory/lines"

feed() {
  local index due now
  for (( index = 0; index < chunks; index++ )); do
    if [[ $pace == paced ]]; then
      due=$(( feed_start + index * 100000 ))
      now=$(microseconds)
      (( due > now )) && sleep "$(printf '%d.%06d' $(( (due - now) / 1000000 )) $(( (due - now) % 1000000 )))"
    fi
    dd if="$speech" bs=$chunk_bytes skip="$index" count=1 status=none
  done
  microseconds >"$directory/sent"
}

feed_start=''
last_text=''
text=''
echo "$(basename "$model"), $pace, $(seconds $(( speech_bytes * 1000000 / bytes_per_second )))s of audio"
while IFS= read -r -t 300 -u "$from_worker" line; do
  now=$(microseconds)
  if [[ -n $feed_start ]]; then
    sent=$(( (now - feed_start) * bytes_per_second / 1000000 ))
    [[ $pace == full || $sent -gt $speech_bytes ]] && sent=$speech_bytes
    [[ -f $directory/sent ]] && sent=$speech_bytes
    printf '%7ss  audio %6ss  %s\n' "$(seconds $(( now - start )))" "$(seconds $(( sent * 1000000 / bytes_per_second )))" "$line"
  else
    printf '%7ss  %s\n' "$(seconds $(( now - start )))" "$line"
  fi
  case $line in
    '{"ready":true}')
      ready=$now
      feed_start=$(microseconds)
      feed >&"$to_worker" &
      feeder_pid=$!
      exec {to_worker}>&-
      ;;
    '{"text":'*)
      last_text=$now
      text+=$(sed -E 's/^\{"text":"(.*)","eou":(true|false)\}$/\1/' <<<"$line")
      ;;
    '{"done":true}')
      done_at=$now
      break
      ;;
    '{"error":'*)
      cat "$directory/stderr" >&2
      exit 1
      ;;
  esac
done
[[ -n ${done_at-} ]] || { echo 'check.sh: the worker stopped without {"done":true}' >&2; cat "$directory/stderr" >&2; exit 1; }
wait "$feeder_pid"
feeder_pid=''
status=0
wait "$worker_pid" || status=$?
worker_pid=''
sent_at=$(cat "$directory/sent")

echo "text:          $text"
echo "load:          $(seconds $(( ready - start )))s (start to ready)"
echo "audio sent in: $(seconds $(( sent_at - feed_start )))s"
if [[ -n $last_text ]]; then
  echo "last text:     $(seconds $(( last_text - sent_at )))s after the last audio was sent (negative: before)"
else
  echo "last text:     none"
fi
echo "done:          $(seconds $(( done_at - sent_at )))s after the last audio was sent"
echo "recognition:   $(seconds $(( done_at - feed_start )))s (first audio sent to done)"
echo "total:         $(seconds $(( done_at - start )))s; worker exit status $status"
exit "$status"
