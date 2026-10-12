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

;; The job groups of plugins that start jobs, set when each activates.
(def starter #f)
(def other-starter #f)
(def owner-jobs #f)

(defplugin (job-starter ctx)
  "Lends a job group to the tests."
  (set! starter (new-job-group ctx)))

(defplugin (other-job-starter ctx)
  "Lends a second job group to the tests."
  (set! other-starter (new-job-group ctx)))

;; Turned off and on by the tests; each activation makes a new group.
(defplugin (job-owner ctx)
  "Lends a job group that the tests deactivate."
  (set! owner-jobs (new-job-group ctx)))

(def (with-jobs thunk)
  (call-with-test-kernel
   (lambda ()
     (set! applied [])
     (activate-plugin! test-input-plugin)
     (activate-plugin! job-starter)
     (activate-plugin! other-job-starter)
     (start-editor-loop!)
     (thunk))))

;; Start a job of GROUP (by default the job-starter plugin's) on the baton
;; whose run waits for GATE and returns its input.
(def (start-gated-job! key input gate target validity: (validity 'exact-revision) group: (group #f))
  (call-on-editor-loop
   (lambda ()
     (job-group-start! (or group starter) key input: input target: target validity: validity
                       run: (lambda (input) (completion-wait! gate) input)
                       apply: (lambda (result) (set! applied (cons result applied)))))))

(def (on-baton thunk) (call-on-editor-loop thunk))

;; Wait until N results were applied, then a little longer for strays.
(def (applied-after n)
  (wait-until (lambda () (>= (length applied) n)))
  (on-baton void)
  (reverse applied))

(def setting (make-parameter 'outside))


(def jobs-test
  (test-suite "tuna/lib/jobs"
    (test-case "a job runs with a cleared dynamic environment and applies on the baton"
      (with-jobs
       (lambda ()
         (on-baton
          (lambda ()
            (parameterize ((setting 'inside))
              (job-group-start! starter 'probe input: 'input target: (new-target)
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

    (test-case "jobs of two groups with the same key do not coalesce"
      (with-jobs
       (lambda ()
         (let ((gate (make-completion))
               (target (new-target)))
           (for-each (lambda (n) (start-gated-job! 'same n gate target)) [1 2])
           (for-each (lambda (n) (start-gated-job! 'same n gate target group: other-starter))
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

    (test-case "deactivating a job's plugin cancels its running and pending jobs"
      (with-jobs
       (lambda ()
         (let ((gate (make-completion))
               (target (new-target)))
           (on-baton (lambda () (activate-plugin! job-owner)))
           (start-gated-job! 'k 'running gate target group: owner-jobs)
           (start-gated-job! 'k 'pending gate target group: owner-jobs)
           (start-gated-job! 'free 'free gate target)
           (on-baton (lambda () (deactivate-plugin! job-owner)))
           (completion-post! gate #t)
           (check (applied-after 1) => '(free))))))

    (test-case "after reactivation, a job of the new group does not wait for the old group's"
      (with-jobs
       (lambda ()
         (let ((old-gate (make-completion))
               (open-gate (make-completion))
               (target (new-target)))
           (completion-post! open-gate #t)
           (on-baton (lambda () (activate-plugin! job-owner)))
           (start-gated-job! 'k 'old old-gate target group: owner-jobs)
           (on-baton (lambda ()
                       (deactivate-plugin! job-owner)
                       (activate-plugin! job-owner)))
           (start-gated-job! 'k 'new open-gate target group: owner-jobs)
           (check (applied-after 1) => '(new))
           (completion-post! old-gate #t)
           (thread-sleep! 0.05)
           (check (applied-after 1) => '(new))))))

    (test-case "a closed group refuses new jobs"
      (with-jobs
       (lambda ()
         (on-baton (lambda () (activate-plugin! job-owner)))
         (let (closed owner-jobs)
           (on-baton (lambda () (deactivate-plugin! job-owner)))
           (check (job-group? closed) => #t)
           (check (with-catch (lambda (e) (and (Error? e) (Error-message e)))
                              (lambda () (start-gated-job! 'k 'late (make-completion) (new-target)
                                                           group: closed)))
                  => "Job group is closed; its plugin was deactivated")
           (check applied => [])))))))
