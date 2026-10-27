;;; The terminal plugin's input modes and what programs and the mouse do,
;;; with real helpers: copy mode, line mode, OSC 52, the status line, the
;;; mouse (to the program, or selecting for copy mode) and links. The page
;;; script's posts go through a stand-in page service. Every helper and
;;; program a test starts is stopped by its exact pid.
(import :std/test
        :tuna/kernel
        :tuna/plugins/buffers/contract
        :tuna/plugins/commands/contract
        :tuna/plugins/settings/contract
        (only-in :tuna/plugins/editing/contract current-kill region-active? region-beginning region-end)
        (only-in :tuna/plugins/renderer/contract status-line-text)
        :tuna/plugins/editing/plugin
        :tuna/plugins/terminal/plugin
        "../../../../tuna/tests/support/kernel"
        "../../../keys/tests/support/keys"
        "../support/helpers"
        "../support/terminals"
        "../support/recording-page")
(export modes-test)

(defplugin (copying-programs ctx)
  "Lets terminal programs copy (OSC 52)."
  requires: [settings-service]
  (context-set-setting! ctx terminal-enable-osc52 #t))

;; The terminal root's attribute NAME.
(def (root-attribute (name : :symbol)) => :t
  (on-editor (lambda () (node-attribute (buffer-root (get-buffer "*terminal*")) name))))

(def (in-copy-mode?) => :boolean
  (on-editor (lambda ()
               (let (children (node-children (buffer-root (get-buffer "*terminal*"))))
                 (and (pair? children) (text-node? (car children)))))))

(def (focused-text) => :string
  (on-editor (lambda () (text-string (current-text)))))

(def (status) => :string
  (on-editor (lambda () (status-line-text (selected-view) #f))))

(def (kill-ring-head) => (Maybe :string)
  (on-editor (lambda () (with-catch (lambda (e) #f) (lambda () (current-kill 0))))))

(def (rows-runs) => :list
  (on-editor (lambda ()
               (apply append
                      (map (lambda (block)
                             (filter-map (lambda (row) (node-attribute row 'runs)) (node-children block)))
                           (filter (lambda (n) (eq? (node-kind n) 'terminal-rows))
                                   (node-children (buffer-root (get-buffer "*terminal*")))))))))

;; Start a terminal running sh in a fresh kernel with editing and the
;; stand-in page, and call THUNK once its prompt is there.
(def (with-shell (thunk : :procedure) (more : :list := [])) => :t
  (with-terminals
   (lambda (folder)
     ;; The page first: the plugin adds its page addresses when it turns on.
     (call-with-fresh-kernel
      (append [recording-page] terminal-plugins [test-terminal-settings editing] more)
      (lambda ()
        (start-editor-loop!)
        (on-editor (lambda () (call-command 'terminal)))
        (check (screen-has? "*terminal*" "$ ") => #t)
        (thunk))))))

(def (run! (command : :string)) => :void
  (paste command)
  (press "RET"))

(def modes-test
  (test-suite "tuna/plugins/terminal: modes, the mouse, the clipboard and links"
    (test-case "copy mode freezes the rows as a text to move and copy in; output goes on underneath"
      (with-shell
       (lambda ()
         (run! "printf 'one\\ntwo\\n'; sleep 3; echo later")
         (check (screen-has? "*terminal*" "two") => #t)
         (type! "C-c" "C-t")
         (check (wait-for in-copy-mode?) => #t)
         (check (on-editor (lambda () (buffer-local-value buffer-read-only (get-buffer "*terminal*")))) => #t)
         (check (and (string-contains (status) ":Copy") #t) => #t)
         (let* ((text (focused-text))
                (one (or (string-contains text "one\ntwo") 0)))
           (check (and (string-contains text "one\ntwo") (not (string-contains text "\nlater")) #t) => #t)
           (on-editor (lambda () (goto-char (+ one 1))))
           (press "C-SPC")
           (on-editor (lambda () (goto-char (+ one 4))))
           (press "M-w")
           (check (wait-for (lambda () (not (in-copy-mode?)))) => #t)
           (check (kill-ring-head) => "one")
           (check (screen-has? "*terminal*" "later") => #t)))))

    (test-case "with fast exit, a key that types leaves copy mode and reaches the program"
      (with-shell
       (lambda ()
         (type! "C-c" "C-t")
         (check (wait-for in-copy-mode?) => #t)
         (press "x")
         (check (wait-for (lambda () (not (in-copy-mode?)))) => #t)
         (check (screen-has? "*terminal*" "$ x") => #t)
         (check (on-editor (lambda () (buffer-local-value buffer-read-only (get-buffer "*terminal*")))) => #f))))

    (test-case "setting the mark in semi-char mode enters copy mode with the region from the cursor"
      (with-shell
       (lambda ()
         (press "C-SPC")
         (check (wait-for in-copy-mode?) => #t)
         (check (on-editor region-active?) => #t))))

    (test-case "line mode edits a line locally and sends it on RET; M-p brings it back"
      (with-shell
       (lambda ()
         (type! "C-c" "C-l")
         (check (wait-for (lambda () (string-contains (status) ":Line"))) ? values)
         (type! "e" "c" "h" "o" "SPC" "h" "i")
         (check (wait-for (lambda () (equal? (focused-text) "echo hi"))) => #t)
         (press "RET")
         (check (screen-has? "*terminal*" "\nhi\n") => #t)
         (check (focused-text) => "")
         (press "M-p")
         (check (wait-for (lambda () (equal? (focused-text) "echo hi"))) => #t)
         ;; Leaving hands the line to the program as typed.
         (type! "C-c" "C-j")
         (check (wait-for (lambda () (not (string-contains (status) ":Line")))) => #t)
         (check (screen-has? "*terminal*" "$ echo hi") => #t))))

    (test-case "a program copies to the kill ring (OSC 52) only when allowed"
      (with-shell
       (lambda ()
         (run! "printf '\\033]52;c;bm8=\\007'; echo sent1")
         (check (screen-has? "*terminal*" "\nsent1") => #t)
         (check (kill-ring-head) => #f)))
      (with-shell
       (lambda ()
         (run! "printf '\\033]52;c;aGk=\\007'")
         (check (wait-for (lambda () (equal? (kill-ring-head) "hi"))) => #t))
       [copying-programs]))

    (test-case "the status line shows the program's title"
      (with-shell
       (lambda ()
         (run! "printf '\\033]2;work\\007'")
         (check (wait-for (lambda () (string-contains (status) "*terminal* (work)"))) ? values))))

    (test-case "a program that asks for the mouse gets it, encoded as it asked"
      (with-shell
       (lambda ()
         (run! "printf '\\033[?1000h\\033[?1006h'; cat -v")
         (check (wait-for (lambda () (equal? (root-attribute 'mouse) "program"))) => #t)
         (post-to-page-address "mouse"
                               (string-append "{\"terminal\":\"" (root-attribute 'id)
                                              "\",\"view\":" (number->string (on-editor (lambda () (view-id (selected-view))))) ",\"kind\":\"press\",\"button\":\"left\",\"count\":1,"
                                              "\"buttons\":1,\"row\":0,\"column\":4.5,\"y\":0.5}"))
         (check (screen-has? "*terminal*" "^[[<0;5;1M") => #t))))

    (test-case "a drag over the rows enters copy mode with the region dragged over"
      (with-shell
       (lambda ()
         (check (root-attribute 'mouse) => "select")
         (post-to-page-address "select"
                               (string-append "{\"terminal\":\"" (root-attribute 'id)
                                              "\",\"view\":" (number->string (on-editor (lambda () (view-id (selected-view))))) ",\"start\":{\"row\":0,\"index\":0},"
                                              "\"end\":{\"row\":0,\"index\":1},\"clicks\":1,\"wasSelected\":false}"))
         (check (wait-for in-copy-mode?) => #t)
         (check (on-editor (lambda () (list (region-active?) (region-beginning) (region-end)))) => [#t 1 2]))))

    (test-case "URLs in the output are links; a click opens one in a new browser tab"
      (with-shell
       (lambda ()
         (forget-page-instructions!)
         (run! "echo see https://example.com/x.")
         (check (wait-for (lambda ()
                            (ormap (lambda (runs)
                                     (ormap (lambda (run) (equal? (vector-ref run 5) "https://example.com/x"))
                                            (vector->list runs)))
                                   (rows-runs))))
                => #t)
         (post-to-page-address "link"
                               (string-append "{\"terminal\":\"" (root-attribute 'id)
                                              "\",\"uri\":\"https://example.com/x\"}"))
         (check (wait-for (lambda () (member ["terminalOpen" "https://example.com/x"] (page-instructions)))) ? values))))))
