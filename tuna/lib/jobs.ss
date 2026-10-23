;;; Jobs: slow work on plain data, off the baton (ADR 3). A library
;;; (ADR 12): it uses only the public kernel API.
;;;
;;; A job runs its procedure on its input in a thread with a cleared dynamic
;;; environment, so it cannot reach live editor objects through parameters;
;;; its input and results must be plain data. It may post several results
;;; while it runs, and its return value is its last. Each result comes back
;;; through the loop as a task, which checks the job's validity policy
;;; against the job's target and only then applies the result on the baton.
;;;
;;; Every job belongs to a job group, which a plugin creates from its
;;; context and holds. Within a group, each key runs at most one job at a
;;; time and keeps at most one pending: starting a job while one with the
;;; same key runs makes it the pending job, cancelling the previously
;;; pending one. Results therefore keep arriving while new jobs keep being
;;; started. Deactivating the plugin closes its groups and cancels their
;;; jobs.
;;;
;;; Cancellation is cooperative: a cancelled job's thread runs on until its
;;; procedure returns, and no result of it is applied any more. The
;;; procedure receives a check it should call now and then to stop early;
;;; `job-sleep` waits on the job's thread and wakes as soon as the job is
;;; cancelled.
prelude: :gerbil/core

(import (only-in :gerbil/runtime/hash HashTable)
        (only-in :gerbil/runtime/thread thread-main)
        :std/interface
        :tuna/kernel)
(export (interface-out JobTarget)
        job-group
        new-job-group
        job-group?
        job-group-start!
        job
        job?
        job-cancel!
        job-sleep)

;; What a job's results apply to, such as a text.
(interface JobTarget
  ;; The revision the target's results depend on now.
  (job-revision) => :fixnum
  ;; Whether the target still exists.
  (job-target-alive?) => :boolean
  ;; RESULT, computed when the target was at REVISION, adjusted for the
  ;; target's changes since: (list adjusted-result), or #f to drop it.
  (job-rebase (result : :t) (revision : :fixnum)) => (Maybe :pair))

;; Only the baton changes STATE, under LOCK, because the job's thread reads
;; it through its cancellation check. LATEST and LATEST? are shared with
;; the job's thread too, under LOCK.
(defclass job ((key      : :t)
               (input    : :t)
               (run      : :procedure)       ; input, cancelled?, post! -> result, on the job's thread
               (apply    : :procedure)       ; result -> void, on the baton
               (validity : :symbol)          ; exact-revision, target-alive, or rebase
               (target   : :t)               ; JobTarget, or #f
               (revision : :fixnum)          ; the target's revision when started
               (coalesce : :symbol)          ; queue or latest
               (state    : :symbol)          ; pending, running, done, cancelled
               (thread   :? :thread)         ; its thread, once running
               (latest   : :t)               ; coalesce latest: the newest post not yet applied
               (latest?  : :boolean)         ; whether there is one, with its task queued
               (lock     : :mutex))
  final: #t)

(def (change-job-state! (j : job) (state : :symbol)) => :void
  (do-with-lock j.lock (set! j.state state)))

;; Whether J was cancelled. Callable from any thread.
(def (job-cancelled? (j : job)) => :boolean
  (do-with-lock j.lock (eq? j.state 'cancelled)))

;; The running and pending jobs of one key.
(defclass job-slot ((running :? job)
                    (pending :? job))
  final: #t)

(def validity-policies '(exact-revision target-alive rebase))
(def coalescing-policies '(queue latest))

;; One plugin's jobs: key -> job-slot. Confined to the baton, like the
;; plugin's other state.
(defclass job-group ((slots   : HashTable)
                     (closed? : :boolean))
  final: #t)

;; A job group of CTX's plugin. Deactivating the plugin closes the group
;; and cancels its jobs; a closed group refuses new jobs.
(def (new-job-group (ctx : context)) => job-group
  (using (group (job-group slots: (make-hash-table) closed?: #f) : job-group)
    (context-defer! ctx
                    (lambda ()
                      (set! group.closed? #t)
                      (hash-for-each
                       (lambda (key (slot : job-slot))
                         (for-each (lambda (j) (when j (job-cancel! j)))
                                   [slot.running slot.pending]))
                       group.slots)
                      (hash-clear! group.slots)))
    group))

;; Start a job of GROUP keyed KEY that applies the results of (RUN INPUT
;; CANCELLED? POST!) to TARGET with APPLY, on the baton, each if it is still
;; valid under VALIDITY. CANCELLED? is a procedure of no arguments,
;; callable from the job's thread, that returns true once the job is
;; cancelled; RUN should call it now and then and return early when it
;; does. POST! is a procedure of one result, callable from the job's
;; thread, that sends a result before the one RUN returns. COALESCE says
;; which posts apply: queue, every one in order; latest, only the newest
;; not yet applied, so a slow editor costs one task, not a backlog. Without
;; TARGET, every result applies until the job is cancelled, and VALIDITY
;; is not consulted. Validity policies:
;;   exact-revision  TARGET's revision is unchanged;
;;   target-alive    TARGET still exists;
;;   rebase          TARGET still exists and adjusts the result for its
;;                   changes since the job started (JobTarget job-rebase).
;; A running job of the same key keeps running, so results keep arriving,
;; unless it is exact-revision and TARGET has changed since it started:
;; then its result can no longer apply, and it is cancelled. A plugin that
;; wants every older job stopped calls job-cancel! on the one it holds.
;; Deactivating the group's plugin cancels the job. Raises an error if the
;; group is closed: its plugin was deactivated. Call on the baton.
(def (job-group-start! (group    : job-group)
                       (key      : :t)
                       input:    (input    : :t)
                       run:      (run      : :procedure)
                       apply:    (apply    : :procedure)
                       target:   (target   :? JobTarget := #f)
                       validity: (validity : :symbol := 'exact-revision)
                       coalesce: (coalesce : :symbol := 'queue))
  => job
  (when (job-group-closed? group)
    (error "Job group is closed; its plugin was deactivated" key))
  (unless (memq validity validity-policies)
    (error "Unknown job validity policy" validity))
  (unless (memq coalesce coalescing-policies)
    (error "Unknown job coalescing policy" coalesce))
  (let* ((new (job key: key input: input run: run apply: apply validity: validity
                   target: target revision: (if target (JobTarget-job-revision target) 0)
                   coalesce: coalesce state: 'pending thread: #f latest: #f latest?: #f
                   lock: (make-mutex 'tuna-job)))
         (slots (job-group-slots group))
         (slot (or (hash-get slots key)
                   (let (slot (job-slot running: #f pending: #f))
                     (hash-put! slots key slot)
                     slot))))
    (using (slot : job-slot)
      (if slot.running
        (using (running slot.running : job)
          (let (old slot.pending)
            (when old (change-job-state! old 'cancelled)))
          (when (and (eq? running.validity 'exact-revision)
                     (not (fx= running.revision (job-revision new))))
            (job-cancel! running))
          (set! slot.pending new))
        (run-job! slots slot new)))
    new))

;; Cancel J: it applies no result any more, its cancellation check returns
;; true from now on, and its job-sleep returns. A running job's thread
;; finishes on its own; jobs do not touch editor state, so nothing needs
;; undoing. Call on the baton.
(def (job-cancel! (j : job)) => :void
  (unless (eq? j.state 'done)
    (change-job-state! j 'cancelled)
    (let (thread j.thread)
      (when thread
        (thread-send thread 'cancel)))))

;; On a job's thread: wait SECONDS and return #t, or return #f as soon as
;; (CANCELLED?), the job's cancellation check, is true. Cancelling the job
;; wakes it.
(def (job-sleep (seconds : :real) (cancelled? : :procedure)) => :boolean
  (let (deadline (+ (time->seconds (current-time)) seconds))
    (let lp ()
      (and (not (cancelled?))
           (let (left (- deadline (time->seconds (current-time))))
             (or (<= left 0)
                 (begin
                   (thread-receive left #f)
                   (lp))))))))

;; Run J in a root thread: it inherits no parameters (ADR 3, ADR 9).
(def (run-job! (slots : HashTable) (slot : job-slot) (j : job)) => :void
  (change-job-state! j 'running)
  (set! slot.running j)
  (let* ((post (result-poster))
         (run j.run)
         (input j.input)
         (cancelled? (lambda () (job-cancelled? j)))
         (post! (lambda (result) (post-result! j post result))))
    (set! j.thread
      (thread-start!
       (make-root-thread
        (cut thread-main
             (lambda ()
               (let (outcome (with-catch (lambda (e) (cons #t e))
                                         (lambda () (cons #f (run input cancelled? post!)))))
                 (with-catch void
                             (lambda ()
                               (post 'job-result (lambda () (finish-job! slots slot j outcome))))))))
        'tuna-job)))))

;; On J's thread: send RESULT to be applied on the baton through POST, the
;; loop's result poster, unless J is cancelled. With coalesce latest, it
;; replaces the newest unapplied post instead of queuing another task.
(def (post-result! (j : job) (post : :procedure) (result : :t)) => :void
  (unless (job-cancelled? j)
    (with-catch
     void                               ; the loop has stopped
     (lambda ()
       (if (eq? j.coalesce 'queue)
         (post 'job-result (lambda () (apply-result! j result)))
         (when (do-with-lock j.lock
                 (let (queue? (not j.latest?))
                   (set! j.latest result)
                   (set! j.latest? #t)
                   queue?))
           (post 'job-result (lambda () (apply-latest! j)))))))))

;; On the baton: apply J's newest unapplied post.
(def (apply-latest! (j : job)) => :void
  (apply-result! j (do-with-lock j.lock
                     (let (result j.latest)
                       (set! j.latest #f)
                       (set! j.latest? #f)
                       result))))

;; On the baton: apply RESULT if J is not cancelled and RESULT is still
;; valid.
(def (apply-result! (j : job) (result : :t)) => :void
  (unless (eq? j.state 'cancelled)
    (let (valid (valid-result j result))
      (when valid
        (j.apply (car valid))))))

;; On the baton: start the key's pending job, then apply J's outcome if it
;; is still valid.
(def (finish-job! (slots : HashTable) (slot : job-slot) (j : job) (outcome : :pair)) => :void
  (when (eq? slot.running j)
    (set! slot.running #f)
    (let (next slot.pending)
      (set! slot.pending #f)
      (if (and next (not (eq? (job-state next) 'cancelled)))
        (run-job! slots slot next)
        (hash-remove! slots j.key))))
  (unless (eq? j.state 'cancelled)
    (change-job-state! j 'done)
    (if (car outcome)
      (message (string-append "Job failed: " (exception-summary (cdr outcome))))
      (apply-result! j (cdr outcome)))))

;; (list RESULT), adjusted for the job's policy, or #f to drop it.
(def (valid-result (j : job) (result : :t)) => (Maybe :pair)
  (if (not j.target)
    [result]
    (let (target (JobTarget j.target))
      (case j.validity
        ((exact-revision)
         (and (fx= (JobTarget-job-revision target) j.revision) [result]))
        ((target-alive)
         (and (JobTarget-job-target-alive? target) [result]))
        ((rebase)
         (and (JobTarget-job-target-alive? target)
              (JobTarget-job-rebase target result j.revision)))))))
