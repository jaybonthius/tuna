;;; Input-loop hooks are the same path for keys, clicks and named calls.
prelude: :gerbil/core
(import :std/test :tuna/kernel :tuna/plugins/commands/contract :tuna/plugins/keys/contract
        :tuna/plugins/commands/plugin :tuna/plugins/keys/plugin
        "../../tuna/tests/support/kernel" "../../plugins/keys/tests/support/keys" "../../plugins/commands/tests/support/toy-commands"
        "../../tuna/tests/support/string-input")
(export command-loop-test)

(def events [])
(def failures 0)
(def (note! (event : :t)) => :void (set! events (append events [event])))
(defclass recording-display () final: #t)
(defmethod {redisplay! recording-display}
  (lambda (self) (note! 'redraw)))

(defplugin (observed-input ctx)
  "Commands, command observers and a display that records redraws."
  provides: [display-service]
  requires: [commands-service input-service]
  (context-provide! ctx display-service (recording-display))
  (defcommand (observed-action) "Record the action between its hooks."
    (note! ['body (this-command)]))
  (keymap-set "x" 'observed-action)
  (keymap-set "<mouse-1>" 'observed-action)
  (context-add-hook! ctx pre-command-hook 'before
                     (lambda () (note! ['pre (this-command)])))
  (context-add-hook! ctx post-command-hook 'after
                     (lambda () (note! ['post (this-command)]))))

(def (check-dispatch (send : :procedure)) => :void
  (call-on-editor-loop (lambda () (set! events [])))
  (send)
  (check (wait-until (lambda ()
                            (let (tail (member '(post observed-action) events))
                              (and tail (memq 'redraw tail))))) => #t)
  (let (observed (call-on-editor-loop (lambda () events)))
    ;; Ignore an idle redraw before the input task starts.
    (let (commands (filter pair? observed))
      (check commands => '((pre observed-action) (body observed-action) (post observed-action))))
    (check (memq 'redraw (member '(post observed-action) observed)) ? pair?)))

(def command-loop-test
  (test-suite "input command-loop hooks"
    (test-case "pre, body, post, then redraw for keys, clicks and call-command"
      (for-each
       (lambda ((provider : plugin))
          (call-with-fresh-kernel [provider keys test-messages observed-input]
            (lambda ()
              (start-editor-loop!)
              (check-dispatch (lambda () (press "x")))
              (check-dispatch (lambda () (click 'view 1)))
              (check-dispatch (lambda () (call-on-editor-loop (lambda () (call-command 'observed-action)))))
              (check (call-on-editor-loop last-command) => 'observed-action))))
        [commands toy-commands]))
    (test-case "a failing hook is removed with a notice; other callbacks and commands still run"
      (call-with-fresh-kernel [commands keys test-messages observed-input]
        (lambda ()
          (defplugin (broken-observer ctx)
            "A bad post-command callback."
            (context-add-hook! ctx post-command-hook 'broken
                               (lambda () (set! failures (fx1+ failures)) (error "broken observer"))))
          (activate-plugin! broken-observer)
          (set! events [])
          (call-command 'observed-action)
          (check events => '((pre observed-action) (body observed-action) (post observed-action)))
          (check failures => 1)
          (check (and (string-contains (current-message) "broken") #t) => #t)
          (message "next")
          (call-command 'observed-action)
          (check (current-message) => "next")
          (check failures => 1))))))
