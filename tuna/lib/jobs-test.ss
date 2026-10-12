(import (only-in :gerbil/runtime/hash HashTable)
        :std/error
        :std/interface
        :std/sync/completion
        :std/test
        :tuna/kernel
        :tuna/lib/jobs)
(export jobs-test)

(include "../kernel/test-fixtures.ss")

;; A job target the tests change by hand. It rebases a result R computed at
;; revision N to (R N current-revision); FORGOTTEN? makes it drop results
;; instead, as a text does once its journal no longer reaches back.
(defclass fake-target ((revision   : :fixnum)
                       (alive?     : :boolean)
                       (forgotten? : :boolean))
  final: #t)

(implement JobTarget fake-target
  (job-revision (lambda (self) self.revision))
  (job-target-alive? (lambda (self) self.alive?))
  (job-rebase (lambda (self result revision)
                (and (not self.forgotten?) [[result revision self.revision]]))))

(def (new-target) (fake-target revision: 0 alive?: #t forgotten?: #f))

(def (edit! target)
  (set! (fake-target-revision target) (fx1+ (fake-target-revision target))))

(def applied [])

;; The contexts of two plugins that start jobs.
(def starter #f)
(def other-starter #f)

(defplugin (job-starter ctx)
  "Lends its context to the tests to start jobs in."
  (set! starter ctx))

(defplugin (other-job-starter ctx)
  "Lends a second context to the tests."
  (set! other-starter ctx))

(def (with-jobs thunk)
  (call-with-test-kernel
   (lambda ()
     (set! applied [])
     (activate-plugin! test-input-plugin)
     (activate-plugin! job-starter)
     (activate-plugin! other-job-starter)
     (start-editor-loop!)
     (thunk))))

;; Start a job of CTX (by default the job-starter plugin's) on the baton
;; whose run waits for GATE and returns its input.
(def (start-gated-job! key input gate target validity: (validity 'exact-revision) context: (ctx #f))
  (call-on-editor-loop
   (lambda ()
     (context-start-job! (or ctx starter) key input: input target: target validity: validity
                         run: (lambda (input) (completion-wait! gate) input)
                         apply: (lambda (result) (set! applied (cons result applied)))))))

(def (on-baton thunk) (call-on-editor-loop thunk))

;; Wait until N results were applied, then a little longer for strays.
(def (applied-after n)
  (wait-until (lambda () (>= (length applied) n)))
  (on-baton void)
  (reverse applied))

(def setting (make-parameter 'outside))

(def owner-gate (make-completion))

(defplugin (job-owner ctx)
  "Starts a job that it owns."
  (context-start-job! ctx 'owned input: 'owned target: (new-target)
                      run: (lambda (input) (completion-wait! owner-gate) input)
                      apply: (lambda (result) (set! applied (cons result applied)))))

(def jobs-test
  (test-suite "tuna/lib/jobs"
    (test-case "a job runs with a cleared dynamic environment and applies on the baton"
      (with-jobs
       (lambda ()
         (on-baton
          (lambda ()
            (parameterize ((setting 'inside))
              (context-start-job! starter 'probe input: 'input target: (new-target)
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

    (test-case "jobs of two contexts with the same key do not coalesce"
      (with-jobs
       (lambda ()
         (let ((gate (make-completion))
               (target (new-target)))
           (for-each (lambda (n) (start-gated-job! 'same n gate target)) [1 2])
           (for-each (lambda (n) (start-gated-job! 'same n gate target context: other-starter))
                     [3 4])
           (completion-post! gate #t)
           (check (list-sort < (applied-after 4)) => [1 2 3 4])))))

    (test-case "exact-revision drops a result once the target changed"
      (with-jobs
       (lambda ()
         (let ((gate (make-completion))
               (target (new-target)))
           (start-gated-job! 'stale 'stale gate target)
           (on-baton (lambda () (edit! target)))
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
                       (edit! alive)
                       (set! (fake-target-alive? gone) #f)))
           (completion-post! gate #t)
           (check (applied-after 1) => '(alive))))))

    (test-case "rebase asks the target to adjust the result for changes since the job started"
      (with-jobs
       (lambda ()
         (let ((gate (make-completion))
               (target (new-target))
               (forgetful (new-target))
               (gone (new-target)))
           (on-baton (lambda () (edit! target)))
           (start-gated-job! 'rebase 'r gate target validity: 'rebase)
           (start-gated-job! 'forgetful 'f gate forgetful validity: 'rebase)
           (start-gated-job! 'gone 'g gate gone validity: 'rebase)
           (on-baton (lambda ()
                       (edit! target)
                       (edit! target)
                       (set! (fake-target-forgotten? forgetful) #t)
                       (set! (fake-target-alive? gone) #f)))
           (completion-post! gate #t)
           (check (applied-after 1) => '((r 1 3)))))))

    (test-case "deactivating a job's plugin cancels it"
      (with-jobs
       (lambda ()
         (on-baton (lambda () (activate-plugin! job-owner)))
         (start-gated-job! 'free 'free owner-gate (new-target))
         (on-baton (lambda () (deactivate-plugin! job-owner)))
         (completion-post! owner-gate #t)
         (check (applied-after 1) => '(free)))))))
