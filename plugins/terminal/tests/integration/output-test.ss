;;; Heavy output with real helpers: a terminal no view shows copies no
;;; rows until one does, and a flood copies the rows near the bottom at
;;; once and the older ones once output pauses. Every helper and program a
;;; test starts is stopped by its exact pid.
(import :std/test
        :tuna/kernel
        :tuna/plugins/buffers/contract
        :tuna/plugins/commands/contract
        :tuna/plugins/terminal/contract
        "../../../keys/tests/support/keys"
        "../support/helpers"
        "../support/terminals")
(export output-test)

;; The titles terminals reported, newest first.
(def titles [])

(defplugin (title-recorder ctx)
  "Records the titles terminals report."
  (context-add-hook! ctx terminal-title-hook 'test (lambda (term title) (set! titles (cons title titles)))))

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
                   => #t))))))))
