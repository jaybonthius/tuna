;;; The quit key quits a command waiting in off-thread or sleep-for
;;; (keys plugin, tuna/lib/background): which waiting command it quits.
prelude: :gerbil/core
(import :std/test
        :tuna/kernel
        :tuna/lib/background
        :tuna/plugins/clients/contract
        :tuna/plugins/commands/contract
        :tuna/plugins/keys/contract
        :tuna/plugins/commands/plugin
        :tuna/plugins/keys/plugin
        "../../../../tuna/tests/support/kernel"
        "../../../../tuna/tests/support/string-input"
        "../support/keys")
(export keyboard-quit-test)

;; The ids of the clients whose waiting commands ended, newest first.
(def ended [])

(defplugin (waiting-commands ctx)
  "C-c w: wait ten seconds in sleep-for."
  requires: [commands-service input-service]
  (define-command ctx (wait-here) "Wait ten seconds, noting the client when the wait ends."
    (let (c (current-client))
      (unwind-protect
        (sleep-for 10)
        (set! ended (cons (if c (client-id c) 'none) ended)))))
  (keymap-set ctx "C-c w" 'wait-here))

(def a (make-client "a"))
(def b (make-client "b"))

(def (settle) (call-on-editor-loop void))

(def (waiting-count) (length (call-on-editor-loop background-waiting-tasks)))

(def (with-keys thunk)
  (set! ended [])
  (call-with-fresh-kernel [commands keys test-messages waiting-commands]
    (lambda ()
      (start-editor-loop!)
      (thunk))))

(def (start-wait! client)
  (press "C-c" client: client)
  (press "w" client: client)
  (settle))

(def keyboard-quit-test
  (test-suite "tuna/plugins/keys: C-g and commands waiting in the background"
    (test-case "C-g quits the waiting command started from the same client"
      (with-keys
       (lambda ()
         (start-wait! a)
         (check (waiting-count) => 1)
         (press "C-g" client: a)
         (settle)
         (check ended => '("a"))
         (check (current-message) => "Quit"))))

    (test-case "with none of its own waiting, C-g quits another client's"
      (with-keys
       (lambda ()
         (start-wait! a)
         (press "C-g" client: b)
         (settle)
         (check ended => '("a")))))

    (test-case "C-g prefers its own client's waiting command, the most recent first"
      (with-keys
       (lambda ()
         (start-wait! a)
         (start-wait! b)
         (start-wait! a)
         (check (waiting-count) => 3)
         (press "C-g" client: b)
         (settle)
         (check ended => '("b"))
         (press "C-g" client: b)
         (settle)
         (check ended => '("a" "b"))
         (check (waiting-count) => 1))))

    (test-case "a C-g that cancels a pending prefix quits nothing else"
      (with-keys
       (lambda ()
         (start-wait! a)
         (press "C-c" client: a)
         (press "C-g" client: a)
         (settle)
         (check ended => '())
         (press "C-g" client: a)
         (settle)
         (check ended => '("a")))))

    (test-case "another client's C-g leaves this client's pending prefix alone"
      (with-keys
       (lambda ()
         (start-wait! b)
         (press "C-c" client: a)
         (press "C-g" client: b)
         (press "w" client: a)
         (settle)
         (check ended => '("b"))
         (check (waiting-count) => 1))))

    (test-case "C-g leaves alone a task that is not a command"
      (with-keys
       (lambda ()
         (let (t (spawn-task! 'timer-like (lambda () (sleep-for 10) (set! ended (cons 'timer ended)))))
           (settle)
           (check (waiting-count) => 1)
           (press "C-g" client: a)
           (settle)
           (check (waiting-count) => 1)
           (cancel-task! t)
           (settle)
           (check (waiting-count) => 0)
           (check ended => '())))))))
