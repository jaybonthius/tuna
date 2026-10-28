;;; Saved screens: written owner-only and read back, trimmed to a number
;;; of scrollback rows, and shown again under a note with the programs'
;;; modes ended.
(import :std/test
        :gerbil-libghostty/ghostty
        :tuna/lib/unix
        :tuna/plugins/terminal/saved-screen)
(export saved-screen-test)

(def (terminal-with (text : :string)) => :t
  (let (t (make-terminal 80 24))
    (terminal-set-scrollback-max-bytes! t (* 5 1024 1024))
    (terminal-write! t (string->utf8 text))
    t))

(def (lines (count : :fixnum)) => :string
  (call-with-output-string
    (lambda (port) (let lp ((i 1)) (when (<= i count) (display "line " port) (display i port) (display "\r\n" port) (lp (+ i 1)))))))

(def saved-screen-test
  (test-suite "tuna/plugins/terminal: saved screens"
    (test-case "a saved screen is written owner-only and read back"
      (let* ((folder (string-append "/tmp/tuna-saved-screen-test-" (number->string (current-process-id))))
             (path (path-expand "a.screen" folder))
             (bytes (terminal->snapshot-bytes (terminal-with "saved\r\n"))))
        (make-private-directory folder)
        (try
         (write-saved-screen! path bytes)
         (check (fxand (file-info-mode (file-info path)) #o777) => #o600)
         (check (read-saved-screen path) => bytes)
         (check (read-saved-screen (path-expand "missing.screen" folder)) => #f)
         (finally
          (delete-saved-screen! path)
          (delete-directory folder)))))

    (test-case "a saved screen keeps about as many rows of scrollback as asked"
      (let* ((t (terminal-with (lines 5000)))
             (kept (snapshot-bytes->terminal (trimmed-snapshot (terminal->snapshot-bytes t) 200))))
        (check (> (terminal-scrollback-rows t) 4000) => #t)
        (check (<= 200 (terminal-scrollback-rows kept) 1000) => #t)
        (check (and (string-contains (terminal->plain-text kept) "line 5000") #t) => #t)))

    (test-case "a restored screen ends the programs' modes and shows the note below what they left"
      (let* ((t (terminal-with (string-append "before\r\n$ vim\r\n\x1b;[?1049h\x1b;[?1000hvim's screen")))
             (r (restored-terminal (terminal->snapshot-bytes t) 100 30 "NOTE"))
             (text (terminal->plain-text r)))
        (check (terminal-active-screen r) => 'primary)
        (check (terminal-columns r) => 100)
        (check (terminal-mouse-tracking? r) => #f)
        (check (and (string-contains text "before\n$ vim\n NOTE") #t) => #t)
        (check (string-contains text "vim's screen") => #f)))

    (test-case "a screen that cannot be read comes back empty, with the note"
      (check (and (string-contains (terminal->plain-text (restored-terminal (u8vector 1 2 3) 80 24 "NOTE")) "NOTE") #t)
             => #t))))
