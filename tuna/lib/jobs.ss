;;; Jobs: slow work on plain data, off the baton (ADR 3). A library
;;; (ADR 12): it uses only the public kernel API.
;;;
;;; A job runs its procedure on its input in a thread with a cleared dynamic
;;; environment, so it cannot reach live editor objects through parameters;
;;; its input and result must be plain data. Its result comes back through
;;; the loop as a task, which checks the job's validity policy against the
;;; job's target and only then applies the result on the baton.
;;;
;;; Every job belongs to a job group, which a plugin creates from its
;;; context and holds. Within a group, each key runs at most one job at a
;;; time and keeps at most one pending: starting a job while one with the
;;; same key runs makes it the pending job, cancelling the previously
;;; pending one. Results therefore keep arriving while new jobs keep being
;;; started. Deactivating the plugin closes its groups and cancels their
;;; jobs.
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
        job?
        job-cancel!)

;; What a job's results apply to, such as a text.
(interface JobTarget
  ;; The revision the target's results depend on now.
  (job-revision) => :fixnum
  ;; Whether the target still exists.
  (job-target-alive?) => :boolean
  ;; RESULT, computed when the target was at REVISION, adjusted for the
  ;; target's changes since: (list adjusted-result), or #f to drop it.
  (job-rebase (result : :t) (revision : :fixnum)) => (Maybe :pair))

(defclass job ((key      : :t)
               (input    : :t)
               (run      : :procedure)       ; input -> result, on the job's thread
               (apply    : :procedure)       ; result -> void, on the baton
               (validity : :symbol)          ; exact-revision, target-alive, or rebase
               (target   : :t)               ; JobTarget
               (revision : :fixnum)          ; the target's revision when started
               (state    : :symbol))         ; pending, running, done, cancelled
  final: #t)

;; The running and pending jobs of one key.
(defclass job-slot ((running :? job)
                    (pending :? job))
  final: #t)

(def validity-policies '(exact-revision target-alive rebase))

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

;; Start a job of GROUP keyed KEY that applies (RUN INPUT) to TARGET with
;; APPLY, on the baton, if its result is still valid under VALIDITY:
;;   exact-revision  TARGET's revision is unchanged;
;;   target-alive    TARGET still exists;
;;   rebase          TARGET still exists and adjusts the result for its
;;                   changes since the job started (JobTarget job-rebase).
;; Deactivating the group's plugin cancels the job. Raises an error if the
;; group is closed: its plugin was deactivated. Call on the baton.
(def (job-group-start! (group    : job-group)
                       (key      : :t)
                       input:    (input    : :t)
                       run:      (run      : :procedure)
                       apply:    (apply    : :procedure)
                       target:   (target   : JobTarget)
                       validity: (validity : :symbol := 'exact-revision))
  => job
  (when (job-group-closed? group)
    (error "Job group is closed; its plugin was deactivated" key))
  (unless (memq validity validity-policies)
    (error "Unknown job validity policy" validity))
  (let* ((new (job key: key input: input run: run apply: apply validity: validity
                   target: target revision: (JobTarget-job-revision target)
                   state: 'pending))
         (slots (job-group-slots group))
         (slot (or (hash-get slots key)
                   (let (slot (job-slot running: #f pending: #f))
                     (hash-put! slots key slot)
                     slot))))
    (using (slot : job-slot)
      (if slot.running
        (begin
          (let (old slot.pending)
            (when old (set! (job-state old) 'cancelled)))
          (set! slot.pending new))
        (run-job! slots slot new)))
    new))

;; Cancel J: it never applies a result. A running job's thread finishes
;; on its own; jobs do not touch editor state, so nothing needs undoing.
(def (job-cancel! (j : job)) => :void
  (unless (eq? j.state 'done)
    (set! j.state 'cancelled)))

;; Run J in a root thread: it inherits no parameters (ADR 3, ADR 9).
(def (run-job! (slots : HashTable) (slot : job-slot) (j : job)) => :void
  (set! j.state 'running)
  (set! slot.running j)
  (let ((post (result-poster))
        (run j.run)
        (input j.input))
    (thread-start!
     (make-root-thread
      (cut thread-main
           (lambda ()
             (let (outcome (with-catch (lambda (e) (cons #t e))
                                       (lambda () (cons #f (run input)))))
               (with-catch void
                           (lambda ()
                             (post 'job-result (lambda () (finish-job! slots slot j outcome))))))))
      'tuna-job))))

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
    (set! j.state 'done)
    (if (car outcome)
      (message (string-append "Job failed: " (exception-summary (cdr outcome))))
      (let (result (valid-result j (cdr outcome)))
        (when result
          (j.apply (car result)))))))

;; (list RESULT), adjusted for the job's policy, or #f to drop it.
(def (valid-result (j : job) (result : :t)) => (Maybe :pair)
  (let (target (JobTarget j.target))
    (case j.validity
      ((exact-revision)
       (and (fx= (JobTarget-job-revision target) j.revision) [result]))
      ((target-alive)
       (and (JobTarget-job-target-alive? target) [result]))
      ((rebase)
       (and (JobTarget-job-target-alive? target)
            (JobTarget-job-rebase target result j.revision))))))
