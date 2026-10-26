;;; File names and buffer names (files contract and plugin).
(import :std/test
        :tuna/plugins/files/contract
        (only-in :tuna/plugins/files/plugin file-buffer-names)
        (only-in :tuna/plugins/files/picker human-size age-text))
(export names-test)

(def names-test
  (test-suite "tuna/plugins/files: names"
    (test-case "expand-file-name resolves ~, relative names, . and .."
      (let (home (home-directory))
        (check (expand-file-name "~/notes.txt" "/x/") => (string-append home "/notes.txt"))
        (check (expand-file-name "~" "/x/") => home)
        (check (expand-file-name "a/../b/./c.txt" "/x/y/") => "/x/y/b/c.txt")
        (check (expand-file-name "/etc//hosts" "/x/") => "/etc/hosts")
        (check (expand-file-name "sub/" "/x/") => "/x/sub/")
        (check (expand-file-name ".." "/x/y/") => "/x/")
        (check (expand-file-name "../.." "/x/") => "/")))
    (test-case "abbreviate-file-name writes the home folder as ~"
      (let (home (home-directory))
        (check (abbreviate-file-name (string-append home "/a/b")) => "~/a/b")
        (check (abbreviate-file-name home) => "~")
        (check (abbreviate-file-name (string-append home "x/y")) => (string-append home "x/y"))))
    (test-case "folder and name parts"
      (check (file-name-directory "/a/b/c.txt") => "/a/b/")
      (check (file-name-nondirectory "/a/b/c.txt") => "c.txt")
      (check (file-name-directory "c.txt") => "")
      (check (file-name-as-directory "/a") => "/a/"))
    (test-case "buffers of files with the same name are told apart by their folders"
      (check (file-buffer-names '((a . "/w/docs/notes.txt") (b . "/w/work/notes.txt") (c . "/w/x.txt")))
             => '((a . "notes.txt<docs>") (b . "notes.txt<work>") (c . "x.txt")))
      (check (file-buffer-names '((a . "/p/src/main.c") (b . "/q/src/main.c")))
             => '((a . "main.c<p/src>") (b . "main.c<q/src>")))
      (check (file-buffer-names '((a . "/w/docs/notes.txt"))) => '((a . "notes.txt"))))
    (test-case "sizes and ages for the picker's annotations"
      (check (human-size 512) => "512")
      (check (human-size 1536) => "1.5K")
      (check (human-size (* 34 1024 1024)) => "34M")
      (check (age-text (* 1000 1000000000) 1030.) => "now")
      (check (age-text (* 1000 1000000000) (+ 1000. 7200.)) => "2 h ago"))))
