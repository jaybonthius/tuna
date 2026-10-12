;;; Jobs: slow work on plain data, off the baton (ADR 3).
;;;
;;; A job runs its procedure on its input in a thread with a cleared dynamic
;;; environment, so it cannot reach live editor objects through parameters;
;;; its input and result must be plain data. Its result comes back through
;;; the loop as a task, which checks the job's validity policy against the
;;; job's target and only then applies the result on the baton.
;;;
;;; Each key runs at most one job at a time and keeps at most one pending:
;;; starting a job while one with the same key runs makes it the pending
;;; job, cancelling the previously pending one. Results therefore keep
;;; arriving while new jobs keep being started.
prelude: :gerbil/core

(import (only-in :gerbil/runtime/hash HashTable)
        (only-in :gerbil/runtime/thread thread-main)
        :std/interface
        ./ids
        ./state
        ./plugins
        ./loop)
(export (interface-out JobTarget)
        start-job
        job?
        job-cancel!
        rebase-spans)

;; What a job's results apply to, such as a text.
(interface JobTarget
  ;; The revision the target's results depend on now.
  (job-revision) => :fixnum
  ;; Whether the target still exists.
  (job-target-alive?) => :boolean
  ;; The target's changes after REVISION, oldest first, or #f if they are
  ;; no longer known.
  (job-changes-since (revision : :fixnum)) => :t)

(defclass job ((key      : :t)
               (input    : :t)
               (run      : :procedure)       ; input -> result, on the job's thread
               (apply    : :procedure)       ; result -> void, on the baton
               (validity : :symbol)          ; exact-revision, target-alive, or rebase
               (target   : :t)               ; JobTarget
               (revision : :fixnum)          ; the target's revision when started
               (owner    :? context)
               (state    : :symbol))         ; pending, running, done, cancelled
  final: #t)

;; The running and pending jobs of one key.
(defclass job-slot ((running :? job)
                    (pending :? job))
  final: #t)

;; A kernel's jobs: key -> slot, and the contexts whose deactivation
;; already cancels their jobs.
(defclass job-registry ((slots  : HashTable)
                        (owners : HashTable))
  final: #t)

(def validity-policies '(exact-revision target-alive rebase))

(def (job-registry!) => job-registry
  (using (k (the-kernel) : kernel)
    (unless k.jobs
      (set! k.jobs (job-registry slots: (make-hash-table) owners: (make-hash-table-eq))))
    (: k.jobs job-registry)))

(def (job-slots) => HashTable
  (using (registry (job-registry!) : job-registry)
    registry.slots))

;; Arrange once per context that deactivating it cancels its jobs.
(def (own-jobs! (ctx : context)) => :void
  (using (registry (job-registry!) : job-registry)
    (unless (hash-get registry.owners ctx)
      (hash-put! registry.owners ctx #t)
      (context-defer! ctx
                      (lambda ()
                        (hash-remove! registry.owners ctx)
                        (hash-for-each
                         (lambda (key (slot : job-slot))
                           (for-each (lambda (j)
                                       (when (and j (eq? (job-owner j) ctx))
                                         (job-cancel! j)))
                                     [slot.running slot.pending]))
                         registry.slots))))))

;; Start a job keyed KEY that applies (RUN INPUT) to TARGET with APPLY,
;; on the baton, if its result is still valid under VALIDITY:
;;   exact-revision  TARGET's revision is unchanged;
;;   target-alive    TARGET still exists;
;;   rebase          TARGET still exists and the result, a list of spans,
;;                   is mapped through TARGET's changes since the job
;;                   started; spans those changes touched are dropped.
;; With CONTEXT, deactivating its plugin cancels the job. Call on the baton.
(def (start-job (key : :t)
                input:    (input    : :t)
                run:      (run      : :procedure)
                apply:    (apply    : :procedure)
                target:   (target   : JobTarget)
                validity: (validity : :symbol := 'exact-revision)
                context:  (ctx      :? context := #f))
  => job
  (unless (memq validity validity-policies)
    (error "Unknown job validity policy" validity))
  (let* ((new (job key: key input: input run: run apply: apply validity: validity
                   target: target revision: (JobTarget-job-revision target) owner: ctx
                   state: 'pending))
         (slots (job-slots))
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
        (run-job! slot new)))
    (when ctx
      (own-jobs! ctx))
    new))

;; Cancel J: it never applies a result. A running job's thread finishes
;; on its own; jobs do not touch editor state, so nothing needs undoing.
(def (job-cancel! (j : job)) => :void
  (unless (eq? j.state 'done)
    (set! j.state 'cancelled)))

;; Run J in a root thread: it inherits no parameters (ADR 3, ADR 9).
(def (run-job! (slot : job-slot) (j : job)) => :void
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
                           (lambda () (post 'job-result (lambda () (finish-job! slot j outcome))))))))
      'tuna-job))))

;; On the baton: start the key's pending job, then apply J's outcome if it
;; is still valid.
(def (finish-job! (slot : job-slot) (j : job) (outcome : :pair)) => :void
  (when (eq? slot.running j)
    (set! slot.running #f)
    (let (next slot.pending)
      (set! slot.pending #f)
      (if (and next (not (eq? (job-state next) 'cancelled)))
        (run-job! slot next)
        (hash-remove! (job-slots) j.key))))
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
            (let (changes (JobTarget-job-changes-since target j.revision))
              (and changes [(rebase-spans result changes)])))))))

;; SPANS moved through CHANGES (oldest first). A span a change touched is
;; dropped: one overlapping a replaced range, or with an insertion strictly
;; inside it. Insertions at a span's edge leave it intact.
(def (rebase-spans (spans : :list) (changes : :list)) => :list
  (filter-map
   (lambda ((s : span))
     (let lp ((rest changes) (start s.start) (end s.end))
       (match rest
         ([] (make-span start end s.value))
         ([c . more]
          (using (c : change)
            (let* ((removed (string-length c.removed))
                   (shift (fx- (string-length c.inserted) removed))
                   (edit-end (fx+ c.start removed)))
              (cond
               ((if (fx= removed 0) (fx<= c.start start) (fx<= edit-end start))
                (lp more (fx+ start shift) (fx+ end shift)))
               ((fx>= c.start end)
                (lp more start end))
               (else #f))))))))
   spans))
