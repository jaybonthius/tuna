(import (only-in :std/list/list append-map)
        :std/error
        :std/sync/completion
        :std/test
        :tuna/kernel
        :tuna/lib/background
        (only-in :tuna/lib/jobs job-cancel!)
        "../support/kernel"
        "../support/string-input")
(export background-test)

(def log [])
(def (note! item) (set! log (cons item log)))

(def redisplays 0)

(defstruct counting-display ()
  final: #t)

(defmethod {redisplay! counting-display}
  (lambda (self) (set! redisplays (fx1+ redisplays))))

(defplugin (counting-display-provider ctx)
  "Counts redisplays."
  provides: [display-service]
  (context-provide! ctx display-service (make-counting-display)))

;; A plugin whose context the tests own tasks with; set when it activates.
(def owner-context #f)

(defplugin (task-owner ctx)
  "Lends its context to the tests."
  (set! owner-context ctx))

(def tasks-started 0)

(defplugin (task-counter ctx)
  "Counts the tasks started."
  (context-add-hook! ctx task-started-hook 'count (lambda (id name) (set! tasks-started (+ tasks-started 1)))))

(def (with-background thunk plugins: (plugins []))
  (set! log [])
  (call-with-fresh-kernel (cons* test-input counting-display-provider task-counter plugins)
    (lambda ()
      (start-editor-loop!)
      (thunk))))

(def (on-baton thunk) (call-on-editor-loop thunk))

;; Wait for every earlier item and task, then read the last message.
(def (settled-message) (on-baton current-message))

(def (error-message thunk)
  (with-catch (lambda (e) (if (Error? e) (Error-message e) e)) thunk))

(defclass opaque ((x : :t)) final: #t)

(def (now) (time->seconds (current-time)))

;; Every live thread of this process.
(def (all-threads)
  (let* ((root (let up ((g (thread-thread-group (current-thread))))
                 (let (parent (thread-group-parent g))
                   (if parent (up parent) g)))))
    (let walk ((g root))
      (append (thread-group->thread-list g)
              (append-map walk (thread-group->thread-group-list g))))))

(def (threads-named name)
  (filter (lambda (t) (eq? (thread-name t) name)) (all-threads)))

;; What test sources read, and whether their reads fail.
(def source-value #f)
(def source-fails? #f)

;; A source of the task-owner plugin, every 20 ms, reading source-value
;; and noting what it applies.
(def (start-test-source! name)
  (context-start-source! owner-context name every: 0.02
                         read: (lambda (input previous)
                                 (when source-fails? (error "boom"))
                                 source-value)
                         apply: note!))

;; Set by a worker once it started, and once it saw its cancellation.
(def worker-started? #f)
(def sleeper-id #f)                     ; the id of the task named sleeper
(def worker-saw-cancel? #f)

;; Wait until cancelled, for up to ten seconds; returns 'late.
(def (wait-for-cancel input)
  (set! worker-started? #t)
  (let lp ((n 0))
    (cond
     ((background-cancelled?) (set! worker-saw-cancel? #t) 'late)
     ((< n 1000) (thread-sleep! 0.01) (lp (fx1+ n)))
     (else 'late))))

(def background-test
  (test-suite "tuna/lib/background"
    (test-case "off-thread returns the procedure's value in the calling task"
      (with-background
       (lambda ()
         (check (on-baton (lambda () (off-thread (lambda (x) (* x 2)) 21))) => 42)
         (check (on-baton (lambda () (off-thread (lambda (x) (background-cancelled?)) #f))) => #f))))

    (test-case "off-thread raises the procedure's error in the calling task"
      (with-background
       (lambda ()
         (check (error-message (lambda () (on-baton (lambda () (off-thread (lambda (x) (error "boom")) 1)))))
                => "boom"))))

    (test-case "the editor runs other tasks while a task waits in off-thread"
      (with-background
       (lambda ()
         (spawn-task! 'slow (lambda () (note! (off-thread (lambda (x) (thread-sleep! 0.3) x) 'slow))))
         (on-baton (lambda () (note! 'other)))
         (check (wait-until (lambda () (memq 'slow log))) ? values)
         (check (reverse log) => '(other slow)))))

    (test-case "cancelling a waiting task ends its wait: the worker sees it, and its value is dropped"
      (set! worker-started? #f)
      (set! worker-saw-cancel? #f)
      (with-background
       (lambda ()
         (let (t (spawn-task! 'waiter (lambda () (note! (off-thread wait-for-cancel #f)))))
           (check (wait-until (lambda () worker-started?)) => #t)
           (cancel-task! t)
           (check (settled-message) => "Quit")
           (check (wait-until (lambda () worker-saw-cancel?)) => #t)
           (thread-sleep! 0.05)
           (settled-message)
           (check log => '())))))

    (test-case "a timeout raises an error and cancels the worker"
      (set! worker-saw-cancel? #f)
      (with-background
       (lambda ()
         (check (error-message (lambda () (on-baton (lambda () (off-thread wait-for-cancel #f timeout: 0.05)))))
                => "off-thread timed out after .05 seconds")
         (check (wait-until (lambda () worker-saw-cancel?)) => #t))))

    (test-case "in test mode, input and value must be plain data"
      (with-background
       (lambda ()
         (check (error-message (lambda () (on-baton (lambda () (off-thread values (opaque x: 1))))))
                => "off-thread input must be plain data")
         (check (error-message (lambda () (on-baton (lambda () (off-thread (lambda (x) (opaque x: x)) 1)))))
                => "off-thread result must be plain data")
         (check (on-baton (lambda () (off-thread values [1 "two" #(three)]))) => [1 "two" #(three)]))))

    (test-case "only a task can wait in off-thread or sleep-for"
      (with-background
       (lambda ()
         (check (error-message (lambda () (off-thread values 1))) => "Only a task can wait")
         (check (error-message (lambda () (sleep-for 0.01))) => "Only a task can wait"))))

    (test-case "deactivating the plugin that owns a waiting task quits it"
      (set! worker-started? #f)
      (set! worker-saw-cancel? #f)
      (with-background
       (lambda ()
         (spawn-task! 'owned (lambda ()
                               (call-with-task-owner owner-context
                                 (lambda () (note! (off-thread wait-for-cancel #f))))))
         (check (wait-until (lambda () worker-started?)) => #t)
         (on-baton (lambda () (deactivate-plugin! task-owner)))
         (check (settled-message) => "Quit")
         (check (wait-until (lambda () worker-saw-cancel?)) => #t)
         (check log => '()))
       plugins: [task-owner]))

    (test-case "sleep-for waits, freeing the editor; a cancelled sleep leaves no thread"
      (with-background
       (lambda ()
         (let (start (now))
           (check (on-baton (lambda () (sleep-for 0.05) 'woke)) => 'woke)
           (check (>= (- (now) start) 0.05) => #t))
         (check (on-baton (lambda () (sleep-for 0) 'at-once)) => 'at-once)
         (let (t (spawn-task! 'sleeper (lambda () (set! sleeper-id (current-task-id)) (sleep-for 10) (note! 'woke))))
           (on-baton (lambda () (note! 'other)))
           (check (length (threads-named 'tuna-sleep)) => 1)
           (check (on-baton background-waiting-tasks) => [sleeper-id])
           (cancel-task! t)
           (check (settled-message) => "Quit")
           (check (wait-until (lambda () (null? (threads-named 'tuna-sleep)))) => #t)
           (check (on-baton background-waiting-tasks) => [])
           (check log => '(other))))))

    (test-case "quit-background-wait! quits a waiting task by its id"
      (with-background
       (lambda ()
         (let (t (spawn-task! 'sleeper (lambda () (set! sleeper-id (current-task-id)) (sleep-for 10) (note! 'woke))))
           (check (wait-until (lambda () (pair? (on-baton background-waiting-tasks)))) => #t)
           (check (on-baton (lambda () (quit-background-wait! sleeper-id))) => #t)
           (check (settled-message) => "Quit")
           (check (on-baton (lambda () (quit-background-wait! sleeper-id))) => #f)
           (check log => '())))))

    (test-case "a source whose readings do not change runs no task and redraws nothing"
      (set! source-value 'a)
      (with-background
       (lambda ()
         (on-baton (lambda () (start-test-source! 'steady)))
         (check (wait-until (lambda () (pair? log))) => #t)
         (on-baton void)
         (set! tasks-started 0)
         (set! redisplays 0)
         (thread-sleep! 0.5)
         (check tasks-started => 0)
         (check redisplays => 0)
         (check log => '(a))
         ;; One change: one task applies it.
         (set! source-value 'b)
         (check (wait-until (lambda () (equal? log '(b a)))) => #t)
         (thread-sleep! 0.1)
         (check tasks-started => 1)
         (check log => '(b a)))
       plugins: [task-owner]))

    (test-case "a source's read receives its previous reading; compare decides what is posted"
      (set! source-value 'shown)
      (with-background
       (lambda ()
         ;; The reading is (shown . reads so far); only the shown part is compared.
         (on-baton (lambda ()
                     (context-start-source! owner-context 'counting every: 0.01
                                            read: (lambda (input previous)
                                                    (cons source-value (if previous (+ (cdr previous) 1) 1)))
                                            compare: (lambda (a b) (eq? (car a) (car b)))
                                            apply: note!)))
         (check (wait-until (lambda () (pair? log))) => #t)
         (check log => '((shown . 1)))
         (thread-sleep! 0.1)
         (check (length log) => 1)
         (set! source-value 'changed)
         (check (wait-until (lambda () (= (length log) 2))) => #t)
         (check (car (car log)) => 'changed)
         (check (> (cdr (car log)) 5) => #t))
       plugins: [task-owner]))

    (test-case "a failing read is reported once and the source goes on"
      (set! source-value 'fine)
      (set! source-fails? #f)
      (with-background
       (lambda ()
         (on-baton (lambda () (start-test-source! 'flaky)))
         (check (wait-until (lambda () (pair? log))) => #t)
         (on-baton void)
         (set! source-fails? #t)
         (check (wait-until (lambda () (equal? (on-baton current-message) "Source flaky failed: boom"))) => #t)
         ;; Reported once: the failing reads that follow post nothing.
         (on-baton void)
         (set! tasks-started 0)
         (thread-sleep! 0.2)
         (check tasks-started => 0)
         ;; Recovery posts the next reading, even an unchanged one.
         (set! source-fails? #f)
         (check (wait-until (lambda () (equal? log '(fine fine)))) => #t))
       plugins: [task-owner]))

    (test-case "a non-plain reading counts as a failure in test mode"
      (with-background
       (lambda ()
         (on-baton (lambda ()
                     (context-start-source! owner-context 'opaque every: 0.01
                                            read: (lambda (input previous) (opaque x: 1))
                                            apply: note!)))
         (check (wait-until (lambda () (equal? (on-baton current-message)
                                               "Source opaque failed: A source's reading must be plain data")))
                => #t)
         (check log => '()))
       plugins: [task-owner]))

    (test-case "deactivating a source's plugin stops it and drops a reading not yet applied"
      (set! source-value 'first)
      (with-background
       (lambda ()
         (let (gate (make-completion))
           (on-baton (lambda ()
                       (context-start-source! owner-context 'gated every: 0.01
                                              read: (lambda (input previous)
                                                      (when previous (completion-wait! gate))
                                                      source-value)
                                              apply: note!)))
           (check (wait-until (lambda () (pair? log))) => #t)
           (set! source-value 'second)
           (on-baton (lambda () (deactivate-plugin! task-owner)))
           (completion-post! gate #t)
           (check (wait-until (lambda () (null? (threads-named 'tuna-job)))) => #t)
           (on-baton void)
           (check log => '(first))))
       plugins: [task-owner]))

    (test-case "job-cancel! on a source's job stops it"
      (set! source-value 'a)
      (set! source-fails? #f)
      (with-background
       (lambda ()
         (let (j (on-baton (lambda () (start-test-source! 'cancelled))))
           (check (wait-until (lambda () (pair? log))) => #t)
           (on-baton (lambda () (job-cancel! j)))
           (check (wait-until (lambda () (null? (threads-named 'tuna-job)))) => #t)
           (set! source-value 'b)
           (thread-sleep! 0.05)
           (check log => '(a))))
       plugins: [task-owner]))))
