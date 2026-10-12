(import (only-in :gerbil/runtime/hash HashTable)
        :std/error
        :std/interface
        :std/sync/completion
        :std/test
        :tuna/kernel)
(export jobs-test)

(include "test-fixtures.ss")

;; A job target the tests change by hand: CHANGES are change records,
;; oldest first; FORGOTTEN? makes the journal unavailable.
(defclass fake-target ((revision   : :fixnum)
                       (alive?     : :boolean)
                       (changes    : :list)
                       (forgotten? : :boolean))
  final: #t)

(implement JobTarget fake-target
  (job-revision (lambda (self) self.revision))
  (job-target-alive? (lambda (self) self.alive?))
  (job-changes-since (lambda (self revision)
                       (and (not self.forgotten?)
                            (filter (lambda (c) (> (change-revision c) revision)) self.changes)))))

(def (new-target) (fake-target revision: 0 alive?: #t changes: [] forgotten?: #f))

;; Record an edit of the fake target: at START, REMOVED replaced by INSERTED.
(def (edit! target start removed inserted)
  (let (revision (fx1+ (fake-target-revision target)))
    (set! (fake-target-revision target) revision)
    (set! (fake-target-changes target)
      (append (fake-target-changes target) [(make-change revision start removed inserted)]))))

(def applied [])

(def (with-jobs thunk)
  (call-with-test-kernel
   (lambda ()
     (set! applied [])
     (activate-plugin! test-input-plugin)
     (start-editor-loop!)
     (thunk))))

;; Start a job on the baton whose run waits for GATE and returns its input.
(def (start-gated-job! key input gate target validity: (validity 'exact-revision) context: (ctx #f))
  (call-on-editor-loop
   (lambda ()
     (start-job key input: input target: target validity: validity context: ctx
                run: (lambda (input) (completion-wait! gate) input)
                apply: (lambda (result) (set! applied (cons result applied)))))))

(def (on-baton thunk) (call-on-editor-loop thunk))

;; Wait until N results were applied, then a little longer for strays.
(def (applied-after n)
  (wait-until (lambda () (>= (length applied) n)))
  (on-baton void)
  (reverse applied))

(def setting (make-parameter 'outside))

(def spans-of (lambda (spans) (map (lambda (s) [(span-start s) (span-end s)]) spans)))

(def owner-gate (make-completion))

(defplugin (job-owner ctx)
  "Starts a job that it owns."
  (start-job 'owned input: 'owned target: (new-target) context: ctx
             run: (lambda (input) (completion-wait! owner-gate) input)
             apply: (lambda (result) (set! applied (cons result applied)))))

(def jobs-test
  (test-suite "tuna/kernel/jobs"
    (test-case "a job runs with a cleared dynamic environment and applies on the baton"
      (with-jobs
       (lambda ()
         (on-baton
          (lambda ()
            (parameterize ((setting 'inside))
              (start-job 'probe input: 'input target: (new-target)
                         run: (lambda (input) [input (setting) (running-task)])
                         apply: (lambda (result)
                                  (set! applied [(append result [(and (running-task) #t)])]))))))
         (check (applied-after 1) => '((input outside #f #t))))))

    (test-case "a newer job with the same key replaces the pending one; the running one finishes"
      (with-jobs
       (lambda ()
         (let ((gate (make-completion))
               (target (new-target)))
           (for-each (lambda (n) (start-gated-job! 'same n gate target)) [1 2 3])
           (start-gated-job! 'other 4 gate target)
           (completion-post! gate #t)
           (check (list-sort < (applied-after 3)) => [1 3 4])))))

    (test-case "exact-revision drops a result once the target changed"
      (with-jobs
       (lambda ()
         (let ((gate (make-completion))
               (target (new-target)))
           (start-gated-job! 'stale 'stale gate target)
           (on-baton (lambda () (edit! target 1 "" "x")))
           (start-gated-job! 'fresh 'fresh gate target)
           (completion-post! gate #t)
           (check (applied-after 1) => '(fresh))))))

    (test-case "target-alive applies after changes but not once the target is gone"
      (with-jobs
       (lambda ()
         (let ((gate (make-completion))
               (alive (new-target))
               (gone (new-target)))
           (start-gated-job! 'alive 'alive gate alive validity: 'target-alive)
           (start-gated-job! 'gone 'gone gate gone validity: 'target-alive)
           (on-baton (lambda ()
                       (edit! alive 1 "" "x")
                       (set! (fake-target-alive? gone) #f)))
           (completion-post! gate #t)
           (check (applied-after 1) => '(alive))))))

    (test-case "rebase moves result spans past edits made while the job ran"
      (with-jobs
       (lambda ()
         (let ((gate (make-completion))
               (target (new-target))
               (forgetful (new-target)))
           ;; Text "a12b34": digits at 2..4 and 5..7.
           (start-gated-job! 'rebase [(make-span 2 4 'digit) (make-span 5 7 'digit)]
                             gate target validity: 'rebase)
           (start-gated-job! 'forgetful [(make-span 1 2 'digit)] gate forgetful validity: 'rebase)
           (on-baton (lambda ()
                       (edit! target 1 "" "xx")     ; "xxa12b34": both shift by 2
                       (edit! target 8 "" "!")      ; inside 34: that span is dropped
                       (set! (fake-target-forgotten? forgetful) #t)))
           (completion-post! gate #t)
           (check (map spans-of (applied-after 1)) => [[[4 6]]])))))

    (test-case "rebase-spans shifts, keeps edges, and drops touched spans"
      (let (spans [(make-span 3 5 'a) (make-span 7 9 'b)])
        (check (spans-of (rebase-spans spans [(make-change 1 3 "" "xy")])) => [[5 7] [9 11]])
        (check (spans-of (rebase-spans spans [(make-change 1 5 "" "xy")])) => [[3 5] [9 11]])
        (check (spans-of (rebase-spans spans [(make-change 1 4 "" "x")])) => [[8 10]])
        (check (spans-of (rebase-spans spans [(make-change 1 1 "ab" "")])) => [[1 3] [5 7]])
        (check (spans-of (rebase-spans spans [(make-change 1 4 "abc" "")])) => [[4 6]])))

    (test-case "deactivating a job's plugin cancels it"
      (with-jobs
       (lambda ()
         (on-baton (lambda () (activate-plugin! job-owner)))
         (start-gated-job! 'free 'free owner-gate (new-target))
         (on-baton (lambda () (deactivate-plugin! job-owner)))
         (completion-post! owner-gate #t)
         (check (applied-after 1) => '(free)))))))
