;;; A terminal's rows as HTML: runs of styled cells, the cursor, and what a
;;; program reports.
(import :std/test
        :tuna/plugins/terminal/screen
        (only-in :tuna/plugins/terminal/plugin parse-directory-report terminal-process-environment)
        (only-in :gerbil-libghostty/ghostty make-terminal terminal-write! terminal-copy-rows))
(export screen-test)

;; Row N of a terminal that was written BYTES, as runs.
(def (runs-after (bytes : :string) (n : :fixnum))
  (let (term (make-terminal 20 4))
    (terminal-write! term (string->utf8 bytes))
    (row-runs (vector-ref (terminal-copy-rows term n (+ n 1)) 0))))

(def screen-test
  (test-suite "tuna/plugins/terminal: rows"
    (test-case "styled runs become classes; exact colours pass through as properties"
      (check (runs-after "plain \x1b;[1;31mred\x1b;[0m" 0)
             => (vector (vector 0 6 "plain " "" #f) (vector 6 3 "red" "terminal-fg-1 terminal-bold" #f)))
      (check (vector-ref (runs-after "\x1b;[38;2;1;2;3;4mx" 0) 0)
             => (vector 0 1 "x" "terminal-fg-rgb terminal-underline-single" "--terminal-run-foreground:#010203")))

    (test-case "a row draws its runs, the gaps between them, and the cursor"
      (let (runs (vector (vector 0 2 "ab" "" #f) (vector 4 2 "cd" "terminal-bold" #f)))
        (check (row-sxml runs #f) => '("ab" "  " (span (@ (class "terminal-run terminal-bold")) "cd")))
        (check (row-sxml runs (vector 1 'block #f))
               => '((span "a" (span (@ (class "terminal-cursor terminal-cursor-block")) "b")) "  "
                    (span (@ (class "terminal-run terminal-bold")) "cd")))
        (check (row-sxml runs (vector 8 'bar #t))
               => '("ab" "  " (span (@ (class "terminal-run terminal-bold")) "cd") "  "
                    (span (@ (class "terminal-cursor terminal-cursor-bar terminal-cursor-blink")) " ")))))

    (test-case "a folder report names a local folder"
      (check (parse-directory-report "file://myhost/home/me/a%20b" "myhost") => "/home/me/a b")
      (check (parse-directory-report "kitty-shell-cwd://myhost/home/me/a%20b" "myhost") => "/home/me/a%20b")
      (check (parse-directory-report "file:///tmp" "myhost") => "/tmp")
      (check (parse-directory-report "file://other/tmp" "myhost") => #f)
      (check (parse-directory-report "/srv" "myhost") => "/srv")
      (check (parse-directory-report "ssh://x/y" "myhost") => #f))

    (test-case "the program's environment: the setting first, then TERM, then Tuna's own"
      (check (terminal-process-environment ["LANG=fr_FR.UTF-8" "SECRET"] "xterm-256color" "/nowhere" "/home/me"
                                           ["LANG=C" "SECRET=x" "TERM=dumb" "PATH=/bin"])
             => ["LANG=fr_FR.UTF-8" "INSIDE_TUNA=terminal" "TERM=xterm-256color" "COLORTERM=truecolor"
                 "PWD=/home/me" "PATH=/bin"])
      ;; Without the compiled terminfo, xterm-ghostty falls back as ghostel does.
      (check (and (member "TERM=xterm-256color"
                          (terminal-process-environment [] "xterm-ghostty" "/nowhere" "/" []))
                  #t)
             => #t))))
