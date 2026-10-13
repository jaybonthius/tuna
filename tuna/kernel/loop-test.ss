(import (only-in :gerbil/runtime/thread thread-main)
        :std/error
        :std/interface
        :std/test
        :tuna/kernel
        (only-in :tuna/kernel/hooks hook-callback-names)
        "../test-support/kernel"
        "../test-support/string-input")
(export loop-test)

(def log [])
(def (note! item) (set! log (cons item log)))

(def started? #f)
(def cleaned-up? #f)
(def released? #f)
(def redisplays 0)
(def waiting #f)          ; the suspension of the `wait` task
(def saw-pending? #f)

(defstruct counting-display ()
  final: #t)

(defmethod {redisplay! counting-display}
  (lambda (self) (set! redisplays (fx1+ redisplays))))

(defplugin (test-display ctx)
  "Counts redisplays."
  (context-provide! ctx display-service (make-counting-display)))

;; The tasks input items resolve to, each (name . thunk).
(def test-tasks
  [(cons 'note-a (lambda () (note! 'a)))
   (cons 'note-b (lambda () (note! 'b)))
   (cons 'note-quit (lambda () (note! 'quit)))
   (cons 'fail (lambda () (error "deliberate failure")))
   (cons 'block                         ; wait for the test to release it
         (lambda ()
           (set! started? #t)
           (let lp () (unless released? (thread-sleep! 0.01) (lp)))))
   (cons 'cooperative-loop              ; loop, checking for quit
         (lambda ()
           (set! started? #t)
           (let lp () (check-quit) (lp))))
   (cons 'stubborn-loop                 ; loop without checking for quit
         (lambda ()
           (set! started? #t)
           (dynamic-wind void (lambda () (let lp () (lp))) (lambda () (set! cleaned-up? #t)))))
   (cons 'inhibited-loop                ; loop without checking, with quit inhibited
         (lambda ()
           (set! started? #t)
           (with-inhibit-quit (let lp () (lp)))))
   (cons 'wait                          ; wait to be resumed, then note the value
         (lambda () (note! [(suspend (lambda (s) (set! waiting s)))])))
   (cons 'discard                       ; note whether input is pending, then discard it
         (lambda ()
           (set! saw-pending? (input-pending?))
           (discard-input)))])

(def (task-named name) (assq name test-tasks))

(for-each (lambda (key) (hash-put! test-bindings key (task-named (string->symbol key))))
          ["note-a" "note-b" "fail" "block" "cooperative-loop" "stubborn-loop" "inhibited-loop"
           "wait" "discard"])

(defplugin (idle ctx)
  "Registers nothing.")

;; Notes each task start, with whether the task is then the running one,
;; and each task end, with the running task's name, which is #f by then.
(defplugin (task-watcher ctx)
  "Notes task starts and ends."
  (context-add-hook! ctx task-started-hook 'note-started
                     (lambda (id name) (note! ['started name (eq? (current-task-name) name)])))
  (context-add-hook! ctx task-finished-hook 'note-finished
                     (lambda (id name how) (note! ['finished name how (current-task-name)]))))

(defplugin (broken-task-watcher ctx)
  "Adds task callbacks that fail."
  (context-add-hook! ctx task-started-hook 'broken (lambda (id name) (error "broken start")))
  (context-add-hook! ctx task-finished-hook 'broken (lambda (id name how) (error "broken end"))))

(defplugin (meddling-task-watcher ctx)
  "Tries to activate a plugin when a task starts."
  (context-add-hook! ctx task-started-hook 'meddle (lambda (id name) (activate-plugin! idle))))

(def quitting-hook (new-hook 'quitting))

;; Quits from a hook callback, and from a lifecycle callback when idle
;; activates.
(defplugin (quitting-hook-user ctx)
  "Adds hook callbacks that quit."
  (context-add-hook! ctx quitting-hook 'quit-now (lambda () (note! 'quitting) (signal-quit)))
  (context-add-hook! ctx plugin-activated-hook 'quit-on-idle
                     (lambda (p) (when (eq? p idle) (note! 'activated) (signal-quit)))))

;; Runs quitting-hook when deactivated, then notes that its undo finished.
(defplugin (hook-running-owner ctx)
  "Runs quitting-hook from an undo."
  (context-defer! ctx (lambda () (run-hook quitting-hook) (note! 'undo-finished))))

(interface Dummy
  (dummy-op) => :void)

(defstruct dummy ()
  final: #t)

(defmethod {dummy-op dummy}
  (lambda (self) (void)))

(def dummy-service
  (new-service 'dummy is-Dummy? tier: 'live doc: "Does nothing."))

(defplugin (dummy-provider ctx)
  "Provides the dummy service."
  (context-provide! ctx dummy-service (make-dummy)))

(defplugin (dummy-user ctx)
  "Requires the dummy service."
  requires: [dummy-service]
  (void))

(defplugin (lifecycle-recorder ctx)
  "Notes plugin activations and service changes."
  (context-add-hook! ctx plugin-activated-hook 'note-activated
                     (lambda (p) (note! ['activated (plugin-name p)])))
  (context-add-hook! ctx service-changed-hook 'note-changed
                     (lambda (svc old new) (note! ['changed (service-name svc)]))))

(defplugin (provider-quitter ctx)
  "Quits when dummy-provider activates."
  (context-add-hook! ctx plugin-activated-hook 'quit-on-provider
                     (lambda (p) (when (eq? p dummy-provider) (signal-quit)))))

;; Activates until the test releases it, checking for quit.
(defplugin (slow-activation ctx)
  "Activates slowly."
  (set! started? #t)
  (let lp () (unless released? (check-quit) (thread-sleep! 0.01) (lp))))

(defstruct failing-display ()
  final: #t)

(defmethod {redisplay! failing-display}
  (lambda (self) (error "display broke")))

(defplugin (failing-display-plugin ctx)
  "Provides a display that always fails."
  (context-provide! ctx display-service (make-failing-display)))

;; Start a fresh loop with the test tasks and PLUGINS, run THUNK, and stop.
(def (with-loop thunk quit-grace: (quit-grace 0.5) plugins: (plugins []))
  (set! log [])
  (set! started? #f)
  (set! cleaned-up? #f)
  (set! released? #f)
  (set! waiting #f)
  (call-with-fresh-kernel (cons* test-input-plugin test-display plugins)
    (lambda ()
      (start-editor-loop! quit-grace: quit-grace)
      (thunk))))

;; Submit the input item ITEM, usually a plain string, which the test Input
;; provider resolves.
(def (press item) ((input-submitter) item))

;; Wait for every earlier item and its task, then read the last message.
(def (settled-message) (call-on-editor-loop current-message))

(def (elapsed thunk)
  (let (start (time->seconds (current-time)))
    (thunk)
    (- (time->seconds (current-time)) start)))

(def loop-test
  (test-suite "tuna/kernel/loop"
    (test-case "queued input items resolve in order, one task at a time"
      (with-loop
       (lambda ()
         (for-each press ["note-a" "note-b" "unbound" "note-a"])
         (settled-message)
         (check (reverse log) => '(a b a)))))

    (test-case "an input submitter captured before the loop starts works from a thread without the kernel"
      (set! log [])
      (call-with-fresh-kernel [test-input-plugin test-display]
        (lambda ()
          (let (submit (input-submitter))
            (start-editor-loop!)
            ;; A root thread starts with an empty dynamic environment, as
            ;; a transport's request threads may.
            (thread-join!
             (thread-start!
              (make-root-thread (cut thread-main (lambda () (submit "note-a")))
                                'outside-the-kernel)))
            (settled-message)
            (check log => '(a))))))

    (test-case "a failing task is reported and the loop continues"
      (with-loop
       (lambda ()
         (press "fail")
         (check (settled-message) => "deliberate failure")
         (press "note-a")
         (settled-message)
         (check log => '(a)))))

    (test-case "a resolve! result that is not a task is reported and the loop continues"
      (with-loop
       (lambda ()
         (hash-put! test-bindings "malformed" 'not-a-pair)
         (try
          (press "malformed")
          (check (string-empty? (settled-message)) => #f)
          (press "note-a")
          (settled-message)
          (check log => '(a))
          (finally (hash-remove! test-bindings "malformed"))))))

    (test-case "redisplay waits until queued input is processed"
      (with-loop
       (lambda ()
         (press "block")
         (check (wait-until (lambda () started?)) => #t)
         (let (before redisplays)
           (for-each press ["note-a" "note-b" "note-a" "note-b" "note-a"])
           (set! released? #t)
           (settled-message)
           ;; Six tasks ran (block, five notes) plus the settling call.
           (check (<= (- redisplays before) 3) ? values)))))

    (test-case "an interrupt arrival stops a cooperative task without forcing"
      (with-loop
       (lambda ()
         (press "cooperative-loop")
         (check (wait-until (lambda () started?)) => #t)
         (let (seconds (elapsed (lambda () (press "quit") (check (settled-message) => "Quit"))))
           (check (< seconds 5) ? values))
         (press "note-a")
         (settled-message)
         (check log => '(a)))
       quit-grace: 10.))

    (test-case "an interrupt with no task running is queued and resolved as input"
      (with-loop
       (lambda ()
         (hash-put! test-bindings "quit" (task-named 'note-quit))
         (try
          (press "quit")
          (press "note-a")
          (settled-message)
          (check (reverse log) => '(quit a))
          (finally (hash-remove! test-bindings "quit"))))))

    (test-case "input items of any shape are queued and resolved untouched"
      (with-loop
       (lambda ()
         (hash-put! test-bindings '(note a) (task-named 'note-a))
         (hash-put! test-bindings #f (task-named 'note-b))
         (try
          (press '(note a))
          (press #f)
          (settled-message)
          (check (reverse log) => '(a b))
          (finally
           (hash-remove! test-bindings '(note a))
           (hash-remove! test-bindings #f))))))

    (test-case "a task that ignores quit is interrupted after the grace period"
      (with-loop
       (lambda ()
         (press "stubborn-loop")
         (check (wait-until (lambda () started?)) => #t)
         (press "quit")
         (check (settled-message) => "Quit (forced: plugin or library state may be inconsistent)")
         (check cleaned-up? => #t)
         (press "note-b")
         (settled-message)
         (check log => '(b)))
       quit-grace: 0.2))

    (test-case "a second quit interrupts at once"
      (with-loop
       (lambda ()
         (press "stubborn-loop")
         (check (wait-until (lambda () started?)) => #t)
         (let (seconds (elapsed (lambda ()
                                  (press "quit")
                                  (press "quit")
                                  (check (settled-message)
                                         => "Quit (forced: plugin or library state may be inconsistent)"))))
           (check (< seconds 5) ? values))
         (check cleaned-up? => #t))
       quit-grace: 30.))

    (test-case "a waiting task returns the baton, and resumes before queued input"
      (with-loop
       (lambda ()
         (press "wait")
         (press "note-a")
         (settled-message)
         (check log => '(a))
         (check (current-task-name) => #f)
         (call-on-editor-loop
          (lambda ()
            (press "note-b")
            (resume! waiting 'answer)))
         (settled-message)
         (check (reverse log) => '(a (answer) b)))))

    (test-case "a waiting task resumed with quit unwinds and reports Quit"
      (with-loop
       (lambda ()
         (press "wait")
         (settled-message)
         (call-on-editor-loop (lambda () (resume-quit! waiting)))
         (check (settled-message) => "Quit")
         (check log => '()))))

    (test-case "stopping the loop quits waiting tasks"
      (with-loop
       (lambda ()
         (press "wait")
         (settled-message)
         (stop-editor-loop!)
         (check (editor-loop-running?) => #f))))

    (test-case "input-pending? sees queued input; discard-input drops only input"
      (with-loop
       (lambda ()
         (set! saw-pending? #f)
         (press "block")
         (check (wait-until (lambda () started?)) => #t)
         (press "discard")
         (spawn-task! 'queued-task (lambda () (note! 'task)))
         (press "note-a")
         ((result-poster) 'job-result (lambda () (note! 'result)))
         (press "note-b")
         (set! released? #t)
         (check (wait-until (lambda () (and (memq 'task log) (memq 'result log) #t))) => #t)
         (settled-message)
         (check saw-pending? => #t)
         (check (memq 'a log) => #f)
         (check (memq 'b log) => #f))))

    (test-case "input-pending? ignores queued tasks and job results"
      (with-loop
       (lambda ()
         (set! saw-pending? #t)
         (press "block")
         (check (wait-until (lambda () started?)) => #t)
         (press "discard")
         (spawn-task! 'queued-task (lambda () (note! 'task)))
         ((result-poster) 'job-result (lambda () (note! 'result)))
         (set! released? #t)
         (check (wait-until (lambda () (and (memq 'task log) (memq 'result log) #t))) => #t)
         (check saw-pending? => #f))))

    (test-case "inhibit-quit holds off two interrupts; the third overrides it"
      (with-loop
       (lambda ()
         (press "inhibited-loop")
         (check (wait-until (lambda () started?)) => #t)
         (press "quit")
         (press "quit")
         (thread-sleep! 0.3)
         ;; Read without queuing behind the running task.
         (check (current-task-name) => 'inhibited-loop)
         (press "quit")
         (check (settled-message)
                => "Quit (forced: plugin or library state may be inconsistent)"))
       quit-grace: 0.1))

    (test-case "task hooks announce each start and how each task finished, once"
      (with-loop
       (lambda ()
         (press "note-a")
         (press "fail")
         ;; Read and clear the log on the baton, so the reading task's own
         ;; end lands in the cleared log.
         (check (call-on-editor-loop (lambda () (let (seen (reverse log)) (set! log []) seen)))
                => [['started 'note-a #t] 'a ['finished 'note-a 'returned #f]
                    ['started 'fail #t] ['finished 'fail 'raised #f]
                    ['started 'call #t]])
         (press "block")
         (check (wait-until (lambda () started?)) => #t)
         (cancel-task! (spawn-task! 'never-runs (lambda () (note! 'ran))))
         (set! released? #t)
         (settled-message)
         (set! started? #f)
         (press "cooperative-loop")
         (check (wait-until (lambda () started?)) => #t)
         (press "quit")
         (check (settled-message) => "Quit")
         (check (call-on-editor-loop (lambda () (reverse log)))
                => [['finished 'call 'returned #f]
                    ['started 'block #t]
                    ['finished 'block 'returned #f]
                    ['started 'call #t] ['finished 'call 'returned #f]
                    ['started 'cooperative-loop #t] ['finished 'cooperative-loop 'quit #f]
                    ['started 'call #t] ['finished 'call 'returned #f]
                    ['started 'call #t]]))
       plugins: [task-watcher]))

    (test-case "stopping the loop announces its waiting tasks as quit"
      (with-loop
       (lambda ()
         (press "wait")
         (settled-message)
         (stop-editor-loop!)
         (check (member ['finished 'wait 'quit #f] log) ? values))
       plugins: [task-watcher]))

    (test-case "failing task callbacks are removed; the task and the loop carry on"
      (with-loop
       (lambda ()
         (press "note-a")
         (check (string-prefix? "Hook task-finished callback broken (from broken-task-watcher)"
                                (settled-message))
                => #t)
         (check log => '(a))
         (check (call-on-editor-loop
                 (lambda () [(hook-callback-names task-started-hook)
                             (hook-callback-names task-finished-hook)]))
                => [[] []])
         (press "note-b")
         (settled-message)
         (check log => '(b a)))
       plugins: [broken-task-watcher]))

    (test-case "a quit in a hook callback unwinds the task and keeps the callback"
      (with-loop
       (lambda ()
         (spawn-task! 'run-quitting-hook (lambda () (run-hook quitting-hook) (note! 'after)))
         (check (settled-message) => "Quit")
         (check log => '(quitting))
         (check (call-on-editor-loop (lambda () (hook-callback-names quitting-hook)))
                => '(quit-now)))
       plugins: [quitting-hook-user]))

    (test-case "a quit in a lifecycle callback on a task thread unwinds the task"
      (with-loop
       (lambda ()
         (spawn-task! 'activate-idle (lambda () (activate-plugin! idle) (note! 'after)))
         (check (settled-message) => "Quit")
         (check log => '(activated))
         (check (call-on-editor-loop
                 (lambda () [(plugin-active? idle) (hook-callback-names plugin-activated-hook)]))
                => [#t '(quit-on-idle)]))
       plugins: [quitting-hook-user]))

    (test-case "a quit in a lifecycle callback is held until every event is announced"
      (with-loop
       (lambda ()
         (set! log [])
         (spawn-task! 'activate-provider
                      (lambda () (activate-plugin! dummy-provider) (note! 'after)))
         (check (settled-message) => "Quit")
         ;; The quitter's callback runs first; the recorder still sees every
         ;; event, including the dependent activated by the same operation.
         (check (reverse log) => [['changed 'dummy] ['activated 'dummy-provider]
                                  ['activated 'dummy-user]])
         (check (call-on-editor-loop
                 (lambda () [(plugin-active? dummy-user) (hook-callback-names plugin-activated-hook)]))
                => [#t '(quit-on-provider note-activated)]))
       plugins: [provider-quitter lifecycle-recorder dummy-user]))

    (test-case "a quit in a hook run by an undo lets the deactivation finish, then unwinds"
      (with-loop
       (lambda ()
         (set! log [])
         (spawn-task! 'deactivate-owner
                      (lambda () (deactivate-plugin! hook-running-owner) (note! 'after)))
         (check (settled-message) => "Quit")
         (check (reverse log) => '(quitting undo-finished))
         (check (call-on-editor-loop
                 (lambda () [(plugin-active? hook-running-owner) (hook-callback-names quitting-hook)]))
                => [#f '(quit-now)]))
       plugins: [quitting-hook-user hook-running-owner]))

    (test-case "two interrupts during a plugin operation wait until it has finished"
      (with-loop
       (lambda ()
         (spawn-task! 'activate-slowly
                      (lambda () (activate-plugin! slow-activation) (note! 'after)))
         (check (wait-until (lambda () started?)) => #t)
         (press "quit")
         (press "quit")
         (thread-sleep! 0.3)
         (check (current-task-name) => 'activate-slowly)
         (set! released? #t)
         (check (settled-message) => "Quit")
         (check log => '())
         (check (call-on-editor-loop (lambda () (plugin-active? slow-activation))) => #t))
       quit-grace: 0.1))

    (test-case "a third interrupt quits a plugin activation, which is rolled back"
      (with-loop
       (lambda ()
         (spawn-task! 'activate-slowly
                      (lambda () (activate-plugin! slow-activation) (note! 'after)))
         (check (wait-until (lambda () started?)) => #t)
         (press "quit")
         (press "quit")
         (press "quit")
         (check (settled-message) => "Quit (forced: plugin or library state may be inconsistent)")
         (check log => '())
         (check (call-on-editor-loop (lambda () (plugin-active? slow-activation))) => #f))
       quit-grace: 10.))

    (test-case "outside a task, a quit held by a plugin operation is dropped"
      (set! log [])
      (call-with-fresh-kernel [test-input-plugin quitting-hook-user]
        (lambda ()
          (activate-plugin! idle)
          (check log => '(activated))
          (check (plugin-active? idle) => #t)
          (check (hook-callback-names plugin-activated-hook) => '(quit-on-idle))
          (check (current-message) => ""))))

    (test-case "outside a task, a quit in a hook callback counts as a failure"
      (set! log [])
      (call-with-fresh-kernel [test-input-plugin quitting-hook-user]
        (lambda ()
          (run-hook quitting-hook)
          (check log => '(quitting))
          (check (hook-callback-names quitting-hook) => '())
          (check (string-prefix? "Hook quitting callback quit-now (from quitting-hook-user) failed"
                                 (current-message))
                 => #t))))

    (test-case "a failing redisplay is reported on stderr, not stdout"
      (let* ((out (open-output-string))
             (err (open-output-string))
             ;; The loop thread inherits these ports. Checks run outside
             ;; them, since a verbose test run writes to stdout.
             (reported?
              (parameterize ((current-output-port out)
                             (current-error-port err))
                (call-with-fresh-kernel [test-input-plugin failing-display-plugin]
                  (lambda ()
                    (start-editor-loop!)
                    (wait-until (lambda () (string-prefix? "Redisplay failed: display broke\n"
                                                           (get-output-string err)))))))))
        (check reported? => #t)
        (check (get-output-string out) => "")))

    (test-case "task callbacks must not activate plugins"
      (with-loop
       (lambda ()
         (press "note-a")
         (check (string-contains (settled-message)
                                 "Lifecycle hook callbacks must not activate or deactivate plugins")
                ? values)
         (check log => '(a))
         (check (call-on-editor-loop (lambda () (plugin-active? idle))) => #f))
       plugins: [meddling-task-watcher]))))

