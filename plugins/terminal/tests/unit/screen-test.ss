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
             => (vector (vector 0 6 "plain " "" #f #f) (vector 6 3 "red" "terminal-fg-1 terminal-bold" #f #f)))
      (check (vector-ref (runs-after "\x1b;[38;2;1;2;3;4mx" 0) 0)
             => (vector 0 1 "x" "terminal-fg-rgb terminal-underline-single" "--terminal-run-foreground:#010203" #f))
      ;; An OSC 8 link stays with its run.
      (check (vector-ref (runs-after "\x1b;]8;;https://example.com\x1b;\\link\x1b;]8;;\x1b;\\" 0) 0)
             => (vector 0 4 "link" "" #f "https://example.com")))

    (test-case "a row draws its runs, the gaps between them, and the cursor"
      (let (runs (vector (vector 0 2 "ab" "" #f) (vector 4 2 "cd" "terminal-bold" #f)))
        (check (row-sxml runs #f) => '("ab" "  " (span (@ (class "terminal-run terminal-bold")) "cd")))
        (check (row-sxml runs (vector 1 'block #f))
               => '((span "a" (span (@ (class "terminal-cell terminal-cell-1 terminal-cursor terminal-cursor-block")) "b"))
                    "  " (span (@ (class "terminal-run terminal-bold")) "cd")))
        (check (row-sxml runs (vector 8 'bar #t))
               => '("ab" "  " (span (@ (class "terminal-run terminal-bold")) "cd") "  "
                    (span (@ (class "terminal-cell terminal-cell-1 terminal-cursor terminal-cursor-bar terminal-cursor-blink"))
                          " ")))))

    ;; btop's columns drifted: braille and box drawing come from a fallback
    ;; font with other widths unless each such cell is sized on the grid.
    (test-case "every grapheme outside ASCII is a cell as wide as libghostty says"
      (let* ((term (make-terminal 20 4))
             (row (begin (terminal-write! term (string->utf8 "a\x28ff;\x4e2d;e\x301;\x2502;z\r\n"))
                         (vector-ref (terminal-copy-rows term 0 1) 0))))
        (check (row-sxml (row-runs row) #f)
               => '((span "a"
                          (span (@ (class "terminal-cell terminal-cell-1")) "\x28ff;")
                          (span (@ (class "terminal-cell terminal-cell-2")) "\x4e2d;")
                          (span (@ (class "terminal-cell terminal-cell-1")) "e\x301;")
                          (span (@ (class "terminal-cell terminal-cell-1")) "\x2502;")
                          "z"))))
      (check (row-sxml (vector (vector 0 3 "\x4e2d;x" "terminal-bold" #f)) (vector 0 'block #f))
             => '((span (@ (class "terminal-run terminal-bold"))
                        (span (@ (class "terminal-cell terminal-cell-2 terminal-cursor terminal-cursor-block")) "\x4e2d;")
                        "x"))))

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
