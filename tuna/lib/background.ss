;;; Work off the editor thread (ADR 3; docs/briefs/2026-10-background-work.md).
;;; A library (ADR 12): it uses only the public kernel API.
;;;
;;; `(off-thread proc input)` runs PROC on another thread while the calling
;;; task waits, so the editor goes on with other input, and returns its
;;; answer, or raises its error, back in the task. `(sleep-for seconds)` is
;;; the same kind of wait (Emacs `sleep-for`). Both wait at a yield point,
;;; so `C-g` can quit a command waiting in them (`quit-background-wait!`,
;;; which the input provider calls), and deactivating a command's plugin
;;; quits it, as at a prompt.
;;;
;;; A source (`context-start-source!`) keeps something outside the editor
;;; current, such as /proc: a job reads it every few seconds on its own
;;; thread, compares the reading with the last one there, and posts it only
;;; when it differs, so while nothing changes the editor runs no task.
;;;
;;; Anything handed to another thread is plain data (tuna/lib/plain-data),
;;; checked in test mode; the other thread starts with a cleared dynamic
;;; environment, as jobs do, so it cannot reach live editor objects.
prelude: :gerbil/core

(import (only-in :gerbil/runtime/thread spawn-thread thread-main)
        :tuna/kernel
        :tuna/lib/jobs
        :tuna/lib/plain-data)
(export off-thread
        background-cancelled?
        sleep-for
        background-waiting-tasks
        quit-background-wait!
        context-start-source!)

;;; Cancellation

;; Set once, by the thread that stopped waiting; read by the worker.
(defclass cancel-flag ((cancelled? : :boolean)
                       (lock       : :mutex))
  final: #t)

(def (new-cancel-flag) => cancel-flag
  (cancel-flag cancelled?: #f lock: (make-mutex 'tuna-background)))

(def (cancel! (flag : cancel-flag)) => :void
  (do-with-lock flag.lock (set! flag.cancelled? #t)))

(def (flag-cancelled? (flag : cancel-flag)) => :boolean
  (do-with-lock flag.lock flag.cancelled?))

;; The check background-cancelled? calls on this thread, or #f.
(def current-cancelled-check (make-parameter #f))

;; Whether the work running on this thread should stop: its off-thread
;; caller stopped waiting (quit, cancelled, timed out), or its source
;; stopped. #f on any other thread.
(def (background-cancelled?) => :boolean
  (let (check (current-cancelled-check))
    (and check (check) #t)))

;;; Waits

;; The tasks waiting in off-thread or sleep-for, newest first, each
;; (task-id . suspension). Confined to the baton; an entry lives only
;; while its task waits, and a stopping loop resumes its waiting tasks.
(def waits [])

;; Wait in the calling task until the suspension ARM receives is resumed,
;; and return its value; ARM runs on the baton. CLEANUP runs however the
;; wait ends.
(def (call-with-wait (arm : :procedure) (cleanup : :procedure)) => :t
  (let (entry #f)
    (unwind-protect
      (suspend (lambda (s)
                 (set! entry (cons (current-task-id) s))
                 (set! waits (cons entry waits))
                 (arm s)))
      (when entry
        (set! waits (remq entry waits)))
      (cleanup))))

;; The ids of the tasks waiting in off-thread or sleep-for, the most
;; recent wait first. Call on the baton.
(def (background-waiting-tasks) => :list
  (map car waits))

;; Quit the wait of the task TASK-ID in off-thread or sleep-for: the task
;; resumes by raising quit. #f when it is not waiting there. Call on the
;; baton.
(def (quit-background-wait! (task-id : :fixnum)) => :boolean
  (let (entry (assv task-id waits))
    (and entry
         (begin
           (resume-quit! (cdr entry))
           #t))))

;;; off-thread

;; Run (PROC INPUT) on a new thread with a cleared dynamic environment and
;; return its value, or raise what it raised, in the calling task, which
;; waits meanwhile while the editor runs other input. Call from a task.
;; INPUT and the value must be plain data. Inside PROC,
;; (background-cancelled?) turns true once the caller stops waiting; PROC
;; runs on until it returns, and its value is then dropped. With TIMEOUT,
;; a wait longer than TIMEOUT seconds raises an error instead.
(def (off-thread (proc : :procedure) (input : :t) timeout: (timeout :? :real := #f)) => :t
  (check-plain-data! "off-thread input" input)
  (let* ((flag (new-cancel-flag))
         (timer #f)
         (outcome (:- (call-with-wait
                       (lambda (s)
                         (start-worker! proc input flag s)
                         (when timeout
                           (set! timer (start-timeout! s timeout))))
                       (lambda ()
                         (cancel! flag)
                         (when timer
                           (thread-send timer 'cancel))))
                      :pair)))
    (if (car outcome)
      (raise (cdr outcome))
      (cdr outcome))))

;; Run (PROC INPUT) in a root thread and resume S with (raised? . value).
(def (start-worker! (proc : :procedure) (input : :t) (flag : cancel-flag) (s : :t)) => :void
  (thread-start!
   (make-root-thread
    (cut thread-main
         (lambda ()
           (parameterize ((current-cancelled-check (lambda () (flag-cancelled? flag))))
             (resume! s (with-catch (lambda (e) (cons #t e))
                                    (lambda ()
                                      (let (result (proc input))
                                        (check-plain-data! "off-thread result" result)
                                        (cons #f result))))))))
    'tuna-off-thread)))

;; A thread that resumes S with a timeout error after SECONDS, unless sent
;; a message first.
(def (start-timeout! (s : :t) (seconds : :real)) => :thread
  (spawn-thread
   (lambda ()
     (unless (thread-receive seconds #f)
       (resume! s (cons #t (timeout-error seconds)))))
   'tuna-off-thread-timeout))

(def (timeout-error (seconds : :real)) => :t
  (with-catch values
              (lambda ()
                (error (string-append "off-thread timed out after "
                                      (number->string seconds) " seconds")))))

;;; sleep-for

;; Wait SECONDS in the calling task while the editor runs other input
;; (Emacs `sleep-for`). Call from a task. SECONDS <= 0 only checks for
;; quit. A quit while waiting leaves no thread behind.
(def (sleep-for (seconds : :real)) => :void
  (if (<= seconds 0)
    (check-quit)
    (let (relay #f)
      (call-with-wait
       (lambda (s)
         (set! relay (spawn-thread
                      (lambda ()
                        (unless (thread-receive seconds #f)
                          (resume! s (void))))
                      'tuna-sleep)))
       (lambda ()
         (when relay
           (thread-send relay 'cancel))))
      (void))))

;;; Sources

;; Start a source of CTX's plugin named NAME and return its job. On the
;; job's thread it reads (READ INPUT PREVIOUS) now and then every EVERY
;; seconds, PREVIOUS being the last reading (#f the first time), so a
;; reading can carry what the next one needs, such as counters. A reading
;; that is not (COMPARE LAST READING) to the last one is posted, and
;; (APPLY READING) runs on the baton with quit inhibited; when readings
;; keep comparing equal, the editor does nothing. Only the newest posted
;; reading not yet applied is applied. INPUT and readings are plain data.
;; READ or COMPARE raising does not stop the source: the first failure
;; after a reading is shown as a message, and the next reading is posted
;; whatever it is. Deactivating CTX's plugin, or job-cancel! on the job,
;; stops it and drops what it posted but did not apply. Call on the baton.
(def (context-start-source! (ctx : context) (name : :symbol)
                            every:   (every   : :real)
                            read:    (read    : :procedure)
                            apply:   (apply   : :procedure)
                            input:   (input   : :t := #f)
                            compare: (compare : :procedure := equal?))
  => job
  (check-plain-data! "A source's input" input)
  (job-group-start! (new-job-group ctx) name
                    input: input
                    coalesce: 'latest
                    run: (lambda (input cancelled? post!)
                           (run-source read compare every input cancelled? post!))
                    apply: (lambda (posted) (apply-source-post name apply posted))))

;; On the source's job thread: read, compare, post, sleep, until cancelled.
;; What it posts is (reading . READING) or (failed . SUMMARY).
(def (run-source (read : :procedure) (compare : :procedure) (every : :real) (input : :t)
                 (cancelled? : :procedure) (post! : :procedure))
  => :void
  (parameterize ((current-cancelled-check cancelled?))
    (let lp ((last #f) (post-next? #t) (failing? #f))
      (unless (cancelled?)
        (let* ((raised #f)
               (reading (with-catch (lambda (e) (set! raised e) #f)
                                    (lambda ()
                                      (let (reading (read input last))
                                        (check-plain-data! "A source's reading" reading)
                                        reading))))
               (same? (and (not raised) (not post-next?)
                           (with-catch (lambda (e) (set! raised e) #f)
                                       (lambda () (compare last reading))))))
          (if raised
            (begin
              (unless failing?
                (post! (cons 'failed (exception-summary raised))))
              (when (job-sleep every cancelled?)
                (lp last #t #t)))
            (begin
              (unless same?
                (post! (cons 'reading reading)))
              (when (job-sleep every cancelled?)
                (lp reading #f #f)))))))))

;; On the baton: apply a source's reading, or report its failure.
(def (apply-source-post (name : :symbol) (apply : :procedure) (posted : :pair)) => :void
  (if (eq? (car posted) 'failed)
    (message (string-append "Source " (symbol->string name) " failed: " (cdr posted)))
    (with-inhibit-quit (apply (cdr posted)))))
