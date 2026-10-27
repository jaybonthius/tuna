;;; Programs talking to Tuna (stage 4), with real helpers: a shell's
;;; OSC 133 marks, notifications, progress, program status, full resets
;;; and unknown sequences run the contract's hooks; prompt navigation
;;; moves between the marked prompts; a failing redraw is reported and
;;; output goes on. Every helper and program a test starts is stopped by
;;; its exact pid.
(import :std/test
        :tuna/kernel
        :tuna/plugins/buffers/contract
        :tuna/plugins/commands/contract
        :tuna/plugins/settings/contract
        :tuna/plugins/terminal/contract
        :tuna/plugins/editing/plugin
        :tuna/plugins/terminal/plugin
        "../../../../tuna/tests/support/kernel"
        "../../../../tuna/tests/support/string-input"
        "../../../keys/tests/support/keys"
        "../support/helpers"
        "../support/terminals")
(export programs-test)

;; What the hooks ran with, newest first.
(def seen [])

(def (note! (entry : :list)) => :void
  (set! seen (cons entry seen)))

(defplugin (program-hook-recorder ctx)
  "Records what the stage 4 terminal hooks run with."
  requires: [settings-service]
  (context-add-hook! ctx terminal-prompt-hook 'test (lambda (term kind) (note! ['prompt kind])))
  (context-add-hook! ctx terminal-command-start-hook 'test (lambda (term command) (note! ['start command])))
  (context-add-hook! ctx terminal-command-finish-hook 'test
                     (lambda (term code seconds) (note! ['finish code (and (real? seconds) (>= seconds 0.2))])))
  (context-add-hook! ctx terminal-notification-hook 'test (lambda (term title body) (note! ['notify title body])))
  (context-add-hook! ctx terminal-progress-hook 'test (lambda (term state percent) (note! ['progress state percent])))
  (context-add-hook! ctx terminal-program-status-hook 'test
                     (lambda (term report)
                       (note! ['status (program-status-report-id report) (program-status-report-state report)
                               (program-status-report-progress report) (program-status-report-app report)
                               (program-status-report-title report)])))
  (context-add-hook! ctx terminal-program-status-clear-hook 'test (lambda (term id) (note! ['clear id])))
  (context-add-hook! ctx terminal-reset-hook 'test (lambda (term) (note! ['reset])))
  (context-add-hook! ctx terminal-unknown-sequence-hook 'test
                     (lambda (term kind number content truncated? terminator)
                       (note! ['unknown kind number content truncated? terminator])))
  (context-add-hook! ctx terminal-input-hook 'test (lambda (term) (note! ['input])))
  (set! recorder-context ctx))

;; The recorder's context, to change settings with during a test.
(def recorder-context #f)

;; Start a terminal running sh with the recorder, messages and editing,
;; and call THUNK once its prompt is there.
(def (with-recorded-shell (thunk : :procedure)) => :t
  (with-terminals
   (lambda (folder)
     (set! seen [])
     (call-with-fresh-kernel
      (append [test-messages] terminal-plugins [test-terminal-settings editing program-hook-recorder])
      (lambda ()
        (start-editor-loop!)
        (on-editor (lambda () (call-command 'terminal)))
        (check (screen-has? "*terminal*" "$ ") => #t)
        (thunk))))))

(def (run! (command : :string)) => :void
  (paste command)
  (press "RET"))

(def (seen? (entry : :list)) => :boolean
  (wait-for (lambda () (and (member entry seen) #t)) 10))

;; The text of copy mode's line from point on.
(def (text-at-point) => :string
  (on-editor (lambda ()
               (let* ((text (text-string (current-text)))
                      (from (fx1- (point)))
                      (end (or (string-index text #\newline from) (string-length text))))
                 (substring text from end)))))

(def programs-test
  (test-suite "tuna/plugins/terminal: programs talking to Tuna"
    (test-case "a shell's OSC 133 marks run the prompt, command and finish hooks; typing runs the input hook"
      (with-recorded-shell
       (lambda ()
         (run! "printf '\\033]133;A\\007\\033]133;C;cmdline_url=ls%%20-l\\007'; sleep 0.3; printf '\\033]133;D;3\\007'")
         (check (seen? '(prompt primary)) => #t)
         (check (seen? '(start "ls -l")) => #t)
         (check (seen? '(finish 3 #t)) => #t)
         (check (seen? '(input)) => #t)
         ;; A D with no C before it has no duration.
         (run! "printf '\\033]133;D\\007'")
         (check (seen? '(finish #f #f)) => #t))))

    (test-case "notifications, progress, program status, a full reset and unknown sequences run their hooks"
      (with-recorded-shell
       (lambda ()
         (run! "printf '\\033]9;hello\\007\\033]777;notify;Title;Body\\007\\033]9;4;1;40\\007'")
         (check (seen? '(notify "" "hello")) => #t)
         (check (seen? '(notify "Title" "Body")) => #t)
         (check (seen? '(progress set 40)) => #t)
         (run! "printf '\\033]7501;state=working:progress=30:app=demo:title=aGk=\\033\\\\'")
         (check (seen? '(status "" working 30 "demo" "hi")) => #t)
         (run! "printf '\\033]7501;state=done:id=a/b\\007\\033]7501;state=clear:id=a\\007'")
         (check (seen? '(status "a/b" done #f #f #f)) => #t)
         (check (seen? '(clear "a")) => #t)
         (run! "printf '\\033]7777;some;thing\\007'")
         (check (seen? '(unknown osc 7777 "7777;some;thing" #f bel)) => #t)
         (set! seen [])
         (run! "printf '\\033c'")
         (check (seen? '(reset)) => #t)
         ;; libghostty clears every record on a full reset, before the reset.
         (check (and (member '(clear "") seen) #t) => #t))))

    (test-case "prompt navigation enters copy mode and moves to where the marked prompts' input starts"
      (with-recorded-shell
       (lambda ()
         (run! (string-append "clear; printf '\\033]133;A\\007one> \\033]133;B\\007first\\n\\033]133;C\\007out1\\n"
                              ;; This prompt starts with an empty line, as starship's does.
                              "\\033]133;D;0\\007\\033]133;A\\007\\ntwo> \\033]133;B\\007second\\n\\033]133;C\\007out2\\n"
                              "\\033]133;D;0\\007'"))
         (check (screen-has? "*terminal*" "out2") => #t)
         (type! "C-c" "M-p")
         (check (wait-for (lambda () (string-prefix? "second" (text-at-point)))) => #t)
         (type! "C-c" "M-p")
         (check (wait-for (lambda () (string-prefix? "first" (text-at-point)))) => #t)
         (type! "C-c" "M-p")
         (check (wait-for (lambda () (equal? (current-message) "No previous prompt"))) => #t)
         (check (text-at-point) ? (cut string-prefix? "first" <>))
         (type! "C-c" "M-n")
         (check (wait-for (lambda () (string-prefix? "second" (text-at-point)))) => #t))))

    (test-case "a failing redraw is reported once in the echo area, and output goes on"
      (with-recorded-shell
       (lambda ()
         ;; A setting the redraw cannot use breaks the handling of output.
         (on-editor (lambda () (context-set-setting! recorder-context terminal-immediate-redraw-interval 'broken)))
         (run! "echo one")
         (check (wait-for (lambda () (string-prefix? "Terminal *terminal*: output failed:" (current-message))) 10) => #t)
         (on-editor (lambda () (context-set-setting! recorder-context terminal-immediate-redraw-interval 0.05)))
         (run! "echo two")
         (check (screen-has? "*terminal*" "two") => #t))))))
