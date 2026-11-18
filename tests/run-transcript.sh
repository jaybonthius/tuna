#!/bin/sh
set -eu
tuna=${1:?usage: run-transcript.sh TUNA TRANSCRIPT}
transcript=${2:?usage: run-transcript.sh TUNA TRANSCRIPT}
case $tuna in
  /*) ;;
  *) tuna=$PWD/$tuna ;;
esac
folder=$(dirname "$transcript")
dir=$(mktemp -d "${TMPDIR:-/tmp}/tuna-transcript.XXXXXX")
trap 'rm -rf "$dir"' EXIT

mkdir "$dir/home" "$dir/work" "$dir/library"
if [ -d "$folder/home" ]; then
  cp -R "$folder/home/." "$dir/home/"
fi
# Tuna's own library is the one built beside the executable, since some
# of its plugins build native code, and the test's.
sh "$(dirname "$0")/../boot/copy-library.sh" "$(dirname "$tuna")/plugins" "$dir/library"
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

: > "$dir/input"
: > "$dir/expected"
awk -v input="$dir/input" -v expected="$dir/expected" '
  /^;/ { next }
  /^> / { print substr($0, 3) > input; continuing = 1; next }
  continuing && /^[ \t]/ { print > input; next }
  { continuing = 0; print > expected }
' "$transcript"

# The working folder is empty, so nothing beside the test is found by a
# relative path.
status=0
(cd "$dir/work" && TUNA_LIBRARY="$dir/library" "$tuna" < "$dir/input" > "$dir/actual" 2>&1) || status=$?

# Each run has a fresh home folder, so a transcript writes its path as ~,
# and the remotes' as remotes. A test's server listens on a port the
# system chose, so a transcript writes it as PORT.
sed -E -e "s|$dir/home|~|g" -e "s|$dir/remotes|remotes|g" \
  -e 's/(127\.0\.0\.1:| port )[0-9]+/\1PORT/g' "$dir/actual" > "$dir/shown"

if [ "$status" -ne 0 ]; then
  echo "$transcript: FAIL: exit status $status"
  cat "$dir/shown"
  exit 1
fi
if ! diff -u --label expected --label actual "$dir/expected" "$dir/shown"; then
  echo "$transcript: FAIL"
  exit 1
fi
echo "$transcript: ok"
