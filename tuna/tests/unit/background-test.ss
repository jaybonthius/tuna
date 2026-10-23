(import (only-in :std/list/list append-map)
        :std/error
        :std/test
        :tuna/kernel
        :tuna/lib/background
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

(def (with-background thunk plugins: (plugins []))
  (set! log [])
  (call-with-fresh-kernel (cons* test-input counting-display-provider plugins)
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
           (check log => '())))))))
