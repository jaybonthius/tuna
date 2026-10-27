;;; Heavy output with real helpers: a terminal no view shows copies no
;;; rows until one does, a flood copies the rows near the bottom at once
;;; and the older ones once output pauses, and resizing during output
;;; leaves the mirror as the helper has it. Every helper and program a
;;; test starts is stopped by its exact pid.
(import :std/test
        :tuna/kernel
        :tuna/plugins/buffers/contract
        :tuna/plugins/commands/contract
        :tuna/plugins/terminal/contract
        :tuna/plugins/session/contract
        (only-in :tuna/plugins/clients/contract make-client)
        :tuna/plugins/terminal/plugin
        "../../../../tuna/tests/support/kernel"
        "../../../keys/tests/support/keys"
        "../support/recording-page"
        "../support/helpers"
        "../support/terminals")
(export output-test)

;; The titles terminals reported, newest first.
(def titles [])

(defplugin (title-recorder ctx)
  "Records the titles terminals report."
  (context-add-hook! ctx terminal-title-hook 'test (lambda (term title) (set! titles (cons title titles)))))

;; The one browser tab measuring.
(def tab (make-client "test"))

;; Post the tab's measurement of the selected view: COLUMNS x ROWS cells.
(def (post-size! (columns : :fixnum) (rows : :fixnum)) => :void
  (post-to-page-address "size"
                        (string-append "[{\"view\":" (number->string (on-editor (lambda () (view-id (selected-view)))))
                                       ",\"terminal\":\""
                                       (on-editor (lambda () (node-attribute (buffer-root (get-buffer "*terminal*")) 'id)))
                                       "\",\"columns\":" (number->string columns) ",\"rows\":" (number->string rows)
                                       ",\"cellWidth\":9,\"cellHeight\":18}]")
                        client: tab))

;; The terminal's text once it has stopped changing for half a second.
(def (settled-text) => :string
  (let lp ((text (screen-text "*terminal*")) (tries 40))
    (thread-sleep! 0.5)
    (let (now (screen-text "*terminal*"))
      (if (or (equal? now text) (zero? tries)) now (lp now (- tries 1))))))

(def output-test
  (test-suite "tuna/plugins/terminal: heavy output"
    (test-case "a terminal no view shows copies no rows until one does"
      (with-terminals
       (lambda (folder)
         (set! titles [])
         (start-kernel
          (lambda ()
            (start-editor-loop!)
            (on-editor (lambda () (call-command 'terminal)))
            (check (screen-has? "*terminal*" "$ ") => #t)
            (paste "sleep 1; printf '\\033]2;arrived\\007'; echo hidden-output")
            (press "RET")
            (on-editor (lambda () (switch-to-buffer (get-buffer "*scratch*"))))
            ;; The mirror parsed it (its title hook ran), but no row shows it.
            (check (wait-for (lambda () (member "arrived" titles)) 10) => #t)
            (thread-sleep! 0.3)
            (check (and (string-contains (screen-text "*terminal*") "hidden-output") #t) => #f)
            (on-editor (lambda () (switch-to-buffer (get-buffer "*terminal*"))))
            (check (screen-has? "*terminal*" "\nhidden-output\n") => #t))
          [title-recorder]))))

    (test-case "a flood copies the rows near the bottom at once and the older ones once output pauses"
      (with-terminals
       (lambda (folder)
         (start-kernel
          (lambda ()
            (start-editor-loop!)
            (on-editor (lambda () (call-command 'terminal)))
            (check (screen-has? "*terminal*" "$ ") => #t)
            (paste "seq 1 200000")
            (press "RET")
            (check (screen-has? "*terminal*" "\n200000\n") => #t)
            ;; 199000 is a thousand rows up, far above the four screens a
            ;; redraw copies at once.
            (check (screen-has? "*terminal*" "\n199000\n") => #t)
            ;; Every row the scrollback keeps comes to hold its number, in
            ;; order, the oldest last.
            (check (wait-for (lambda ()
                               (let* ((numbers (filter-map string->number
                                                           (string-split (screen-text "*terminal*") #\newline)))
                                      (first (car numbers)))
                                 (and (> (length numbers) 1000)
                                      (equal? numbers (let lp ((n 200000) (out []))
                                                        (if (< n first) out (lp (- n 1) (cons n out))))))))
                             10)
                   => #t))))))

    (test-case "resizing during output leaves the mirror as the helper has it"
      (with-terminals
       (lambda (folder)
         ;; The page first: the plugin adds its page addresses when it turns on.
         (call-with-fresh-kernel
          (append [recording-page] terminal-plugins [test-terminal-settings])
          (lambda ()
            (start-editor-loop!)
            (on-editor (lambda () (call-command 'terminal)))
            (check (screen-has? "*terminal*" "$ ") => #t)
            (paste "i=0; while [ $i -lt 20000 ]; do i=$((i+1)); echo \"line $i of a resize test, long enough to wrap when narrow\"; done; echo resize-''done")
            (press "RET")
            (for-each (lambda (size) (post-size! (car size) (cadr size)) (thread-sleep! 0.1))
                      [[60 20] [100 30] [45 12] [80 24] [70 22] [52 16]])
            (check (screen-has? "*terminal*" "resize-done") => #t)
            (check (on-editor (lambda () (node-attribute (buffer-root (get-buffer "*terminal*")) 'size))) => "52x16")
            (let (before (settled-text))
              ;; Connecting again gets the helper's own screen.
              (on-editor (lambda ()
                           (save-session)
                           (deactivate-plugin! terminals)))
              (on-editor (lambda ()
                           (activate-plugin! terminals)
                           (restore-session)
                           (switch-to-buffer (get-buffer "*terminal*"))))
              (check (screen-has? "*terminal*" "resize-done") => #t)
              ;; The rows they share are the same; how much scrollback
              ;; each keeps can differ, since each prunes whole pages as
              ;; its own pages fill.
              (let* ((after (settled-text))
                     (shorter (if (< (string-length after) (string-length before)) after before))
                     (longer (if (eq? shorter after) before after)))
                (check (> (string-length shorter) 100000) => #t)
                (check (string-suffix? shorter longer) => #t))))))))))
