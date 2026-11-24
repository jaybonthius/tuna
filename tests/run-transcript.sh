#!/bin/sh
set -eu
tuna=${1:?usage: run-transcript.sh TUNA TRANSCRIPT}
transcript=${2:?usage: run-transcript.sh TUNA TRANSCRIPT}
case $tuna in
  /*) ;;
  *) tuna=$PWD/$tuna ;;
esac
folder=$(dirname "$transcript")
tests=$(dirname "$0")
limit=${TEST_TIMEOUT:-60}
dir=$(mktemp -d "${TMPDIR:-/tmp}/tuna-transcript.XXXXXX")
trap 'rm -rf "$dir"' EXIT

mkdir "$dir/home" "$dir/work"
sh "$tests/test-home.sh" "$tuna" "$dir/library" "$dir/home"
if [ -d "$folder/home" ]; then
  cp -R "$folder/home/." "$dir/home/"
fi
# A folder takes a module other folders share, such as the web stand-in,
# by linking to it from its lib/; the link would lead nowhere from the copy.
if [ -d "$folder/home/.config/tuna/lib" ]; then
  cp -RL --remove-destination "$folder/home/.config/tuna/lib/." "$dir/home/.config/tuna/lib/"
fi
if [ -d "$folder/library" ]; then
  cp -R "$folder/library/." "$dir/library/"
fi

# A configuration that a folder's transcripts share tells them apart by
# name, as when only one of them changes a setting.
export TRANSCRIPT="$(basename "$transcript" .transcript)"

# A user's git settings, such as signing or address rewrites, would change
# commits or addresses.
export GIT_CONFIG_NOSYSTEM=1
unset XDG_CONFIG_HOME
export HOME="$dir/home"

# Fixed names and dates keep commit ids the same on every run, so a
# transcript can name them.
if [ -e "$folder/remotes" ]; then
  export GIT_AUTHOR_NAME=Tuna GIT_AUTHOR_EMAIL=tuna@example.org GIT_AUTHOR_DATE='1767225600 +0000'
  export GIT_COMMITTER_NAME=Tuna GIT_COMMITTER_EMAIL=tuna@example.org GIT_COMMITTER_DATE='1767225600 +0000'
  for fixture in "$folder"/remotes/*/*/; do
    fixture=${fixture%/}
    repository=$dir/remotes/${fixture#"$folder"/remotes/}
    mkdir -p "$repository"
    git init -q --bare -b main "$repository"
    for commit in $(ls "$fixture" | grep -E '^[0-9]+(-[a-z0-9-]+)?$' | sort -n); do
      case $commit in
        *-*) branch=${commit#*-} ;;
        *) branch=main ;;
      esac
      if [ -f "$fixture/$commit.message" ]; then
        message=$fixture/$commit.message
      else
        message=$dir/message
        echo "commit $commit" > "$message"
      fi
      rm -f "$dir/index"
      GIT_INDEX_FILE=$dir/index git --git-dir="$repository" --work-tree="$fixture/$commit" add -A .
      # Each line of N.gitlinks puts a submodule at a path: the commit,
      # by number, of a fixture repository made before this one.
      if [ -f "$fixture/$commit.gitlinks" ]; then
        while read -r path source number; do
          linked=$(git --git-dir="$dir/remotes/$source" rev-list --reverse main | sed -n "${number}p")
          GIT_INDEX_FILE=$dir/index git --git-dir="$repository" update-index --add --cacheinfo "160000,$linked,$path"
        done < "$fixture/$commit.gitlinks"
      fi
      tree=$(GIT_INDEX_FILE=$dir/index git --git-dir="$repository" write-tree)
      parent=$(git --git-dir="$repository" rev-parse -q --verify "refs/heads/$branch" ||
               git --git-dir="$repository" rev-parse -q --verify refs/heads/main || true)
      id=$(git --git-dir="$repository" commit-tree "$tree" ${parent:+-p "$parent"} -F "$message")
      git --git-dir="$repository" update-ref "refs/heads/$branch" "$id"
    done
  done
  # Git refuses submodules from local paths unless allowed.
  printf '[url "file://%s/remotes/"]\n\tinsteadOf = https://github.com/\n[protocol "file"]\n\tallow = always\n' \
    "$dir" > "$dir/home/.gitconfig"
fi

# A marker form follows each entry, so each entry's output is compared
# under that entry. Without the flush, a marker could reach the output
# before what the entry printed.
marker=$(printf '\036')
awk -v m="$marker" '
  function mark() { printf "(begin (fresh-line) (display \"%s\") (newline) (flush-output-port))\n", m }
  BEGIN { mark() }
  /^;/ { next }
  /^> / { if (entry) mark(); print substr($0, 3); continuing = 1; entry = 1; next }
  continuing && /^[ \t]/ { print; next }
  { continuing = 0 }
  END { if (entry) mark() }
' "$transcript" > "$dir/input"

# The working folder is empty, so nothing beside the test is found by a
# relative path. Tuna runs under the timeout, not the runner, so a hang
# still shows what Tuna printed before it.
status=0
(cd "$dir/work" && TUNA_LIBRARY="$dir/library" timeout -k 10 "$limit" "$tuna" < "$dir/input" > "$dir/actual" 2>&1) || status=$?

# Each run has a fresh home folder, so a transcript writes its path as
# $HOME, and the remotes' as remotes; not as ~, which Tuna itself writes
# for the home folder. A test's server listens on a port the system
# chose, so a transcript writes it as PORT.
sed -E -e "s|$dir/home|\$HOME|g" -e "s|$dir/remotes|remotes|g" \
  -e 's/(127\.0\.0\.1:| port )[0-9]+/\1PORT/g' "$dir/actual" > "$dir/shown"

# Output before the first entry and at exit has no entry of its own: it
# is block 0, and any block after the last entry's.
awk -v m="$marker" -v shown="$dir/shown" '
  { line[NR] = $0 }
  END {
    blocks = 0
    while ((getline l < shown) > 0) {
      if (l == m) { blocks++; continue }
      block[blocks] = block[blocks] l "\n"
    }
    entries = 0
    for (i = 1; i <= NR; i++) {
      if (line[i] ~ /^;/) { kind[i] = "comment"; entry[i] = entries; continue }
      if (line[i] ~ /^> /) { entries++; continuing = 1; kind[i] = "input" }
      else if (continuing && line[i] ~ /^[ \t]/) kind[i] = "input"
      else { continuing = 0; kind[i] = "expected" }
      entry[i] = entries
      if (kind[i] == "input") last_input[entries] = i
      else if (!(entries in first_expected)) first_expected[entries] = i
    }
    for (e = 0; e <= entries; e++)
      if (e in first_expected) at[first_expected[e]] = e
      else if (e > 0) after[last_input[e]] = e
    for (i = 1; i <= NR; i++) {
      if (i in at) printf "%s", block[at[i]]
      if (line[i] ~ /^> / && entry[i] == 1 && !(0 in first_expected)) printf "%s", block[0]
      if (kind[i] != "expected") print line[i]
      if (i in after) printf "%s", block[after[i]]
    }
    if (entries == 0 && !(0 in first_expected)) printf "%s", block[0]
    for (e = entries + 1; e <= blocks; e++) printf "%s", block[e]
  }
' "$transcript" > "$dir/transcript"

# A failure keeps its actual transcript, so an intended change is a copy.
kept=${ACTUAL_TRANSCRIPTS:-$(cd "$(dirname "$tuna")/.." && pwd)/actual}/${transcript#/}
rm -f "$kept"
if [ "$status" -ne 0 ] || ! cmp -s "$transcript" "$dir/transcript"; then
  diff -u --label "$transcript" --label actual "$transcript" "$dir/transcript" || true
  mkdir -p "$(dirname "$kept")"
  cp "$dir/transcript" "$kept"
  case $status in
    0) echo "$transcript: FAIL" ;;
    124) echo "$transcript: FAIL: timed out after $limit s" ;;
    *) echo "$transcript: FAIL: exit status $status" ;;
  esac
  echo "actual transcript: $kept"
  exit 1
fi
echo "$transcript: ok"
