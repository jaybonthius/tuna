(import (only-in :gerbil/runtime/thread thread-main)
        :std/error
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

