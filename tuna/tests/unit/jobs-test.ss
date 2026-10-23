(import :std/error
        :std/interface
        :std/sync/completion
        :std/test
        :tuna/kernel
        :tuna/lib/jobs
        "../support/kernel"
        "../support/string-input")
(export jobs-test)

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
(def ran [])                            ; inputs of cancellable jobs that started
(def stopped [])                        ; inputs of those that saw their cancellation

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
  (set! applied [])
  (set! ran [])
  (set! stopped [])
  (call-with-fresh-kernel [test-input job-starter other-job-starter]
    (lambda ()
      (start-editor-loop!)
      (thunk))))

;; Start a job of GROUP (by default the job-starter plugin's) on the baton
;; whose run waits for GATE and returns its input.
(def (start-gated-job! key input gate target validity: (validity 'exact-revision) group: (group #f))
  (call-on-editor-loop
   (lambda ()
     (job-group-start! (or group starter) key input: input target: target validity: validity
                       run: (lambda (input cancelled? post!) (completion-wait! gate) input)
                       apply: (lambda (result) (set! applied (cons result applied)))))))

;; Start a job of GROUP (by default the job-starter plugin's) on the baton
;; whose run notes its input in RAN, then polls its cancellation check for
;; up to ten seconds, far longer than wait-until waits; once the check
;; turns true it notes its input in STOPPED and returns.
(def (start-cancellable-job! key input target group: (group #f) validity: (validity 'exact-revision))
  (call-on-editor-loop
   (lambda ()
     (job-group-start! (or group starter) key input: input target: target validity: validity
                       run: (lambda (input cancelled? post!)
                              (set! ran (cons input ran))
                              (let poll ((n 0))
                                (cond
                                 ((cancelled?) (set! stopped (cons input stopped)))
                                 ((< n 1000) (thread-sleep! 0.01) (poll (fx1+ n)))))
                              input)
                       apply: (lambda (result) (set! applied (cons result applied)))))))

(def (noted? input notes)
  (wait-until (lambda () (and (memq input (notes)) #t))))

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
                                run: (lambda (input cancelled? post!) [input (setting) (running-task)])
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

    (test-case "a pending job replaced by a newer one never runs"
      (with-jobs
       (lambda ()
         (let ((gate (make-completion))
               (target (new-target)))
           (start-gated-job! 'same 'first gate target)
           (start-cancellable-job! 'same 'replaced target)
           (start-gated-job! 'same 'newest gate target)
           (completion-post! gate #t)
           (check (applied-after 2) => '(first newest))
           (check ran => [])))))

    (test-case "a cancelled running job sees its check turn true, stops early, and applies nothing"
      (with-jobs
       (lambda ()
         (let* ((open-gate (make-completion))
                (target (new-target))
                (j (start-cancellable-job! 'k 'cancelled target)))
           (completion-post! open-gate #t)
           (check (noted? 'cancelled (lambda () ran)) => #t)
           (check stopped => [])
           (on-baton (lambda () (job-cancel! j)))
           (check (noted? 'cancelled (lambda () stopped)) => #t)
           (start-gated-job! 'free 'free open-gate target)
           (check (applied-after 1) => '(free))))))

    (test-case "a newer job cancels a running exact-revision job of its key once the target changed"
      (with-jobs
       (lambda ()
         (let ((open-gate (make-completion))
               (target (new-target)))
           (completion-post! open-gate #t)
           (start-cancellable-job! 'k 'running target)
           (check (noted? 'running (lambda () ran)) => #t)
           ;; Same revision: the running job's result can still apply.
           (start-gated-job! 'k 'same-revision open-gate target)
           (thread-sleep! 0.1)
           (check (memq 'running stopped) => #f)
           (on-baton (lambda () (edit! target)))
           (start-gated-job! 'k 'newer open-gate target)
           (check (noted? 'running (lambda () stopped)) => #t)
           (check (applied-after 1) => '(newer))))))

    (test-case "a newer job leaves a running rebase job of its key running after a change"
      (with-jobs
       (lambda ()
         (let* ((open-gate (make-completion))
                (target (new-target))
                (j (start-cancellable-job! 'k 'rebasing target validity: 'rebase)))
           (completion-post! open-gate #t)
           (check (noted? 'rebasing (lambda () ran)) => #t)
           (on-baton (lambda () (edit! target)))
           (start-gated-job! 'k 'next open-gate target)
           (thread-sleep! 0.1)
           (check (memq 'rebasing stopped) => #f)
           (on-baton (lambda () (job-cancel! j)))
           (check (noted? 'rebasing (lambda () stopped)) => #t)
           (check (applied-after 1) => '(next))))))

    (test-case "closing a job's group cancels its running job cooperatively"
      (with-jobs
       (lambda ()
         (let ((open-gate (make-completion))
               (target (new-target)))
           (completion-post! open-gate #t)
           (on-baton (lambda () (activate-plugin! job-owner)))
           (start-cancellable-job! 'k 'owned target group: owner-jobs)
           (check (noted? 'owned (lambda () ran)) => #t)
           (on-baton (lambda () (deactivate-plugin! job-owner)))
           (check (noted? 'owned (lambda () stopped)) => #t)
           (start-gated-job! 'free 'free open-gate target)
           (check (applied-after 1) => '(free))))))

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

    (test-case "a job's posts apply in order, before the result it returns"
      (with-jobs
       (lambda ()
         (on-baton
          (lambda ()
            (job-group-start! starter 'posting input: 3 target: (new-target)
                              run: (lambda (n cancelled? post!)
                                     (let lp ((i 1)) (when (<= i n) (post! i) (lp (+ i 1))))
                                     'end)
                              apply: (lambda (result) (set! applied (cons result applied))))))
         (check (applied-after 4) => '(1 2 3 end)))))

    (test-case "coalesce latest applies only the newest post not yet applied"
      (with-jobs
       (lambda ()
         (let ((posted (make-completion))
               (release (make-completion))
               (gate (make-completion)))
           ;; The task holds the baton while the job posts five results.
           (spawn-task! 'hold
                        (lambda ()
                          (job-group-start! starter 'latest input: 5 target: (new-target) coalesce: 'latest
                                            run: (lambda (n cancelled? post!)
                                                   (let lp ((i 1)) (when (<= i n) (post! i) (lp (+ i 1))))
                                                   (completion-post! posted #t)
                                                   (completion-wait! gate)
                                                   'end)
                                            apply: (lambda (result) (set! applied (cons result applied))))
                          (completion-wait! release)))
           (completion-wait! posted)
           (completion-post! release #t)
           (completion-post! gate #t)
           (check (applied-after 2) => '(5 end))))))

    (test-case "each post is checked for validity: exact-revision posts stop once the target changes"
      (with-jobs
       (lambda ()
         (let ((gate (make-completion))
               (target (new-target)))
           (on-baton
            (lambda ()
              (job-group-start! starter 'k input: #f target: target
                                run: (lambda (input cancelled? post!)
                                       (post! 'before)
                                       (completion-wait! gate)
                                       (post! 'after)
                                       'end)
                                apply: (lambda (result) (set! applied (cons result applied))))))
           (check (applied-after 1) => '(before))
           (on-baton (lambda () (edit! target)))
           (completion-post! gate #t)
           (thread-sleep! 0.1)
           (check (applied-after 1) => '(before))))))

    (test-case "cancelling a job drops its posts not yet applied"
      (with-jobs
       (lambda ()
         (let (posted (make-completion))
           (spawn-task! 'hold
                        (lambda ()
                          (let (j (job-group-start! starter 'k input: #f target: (new-target)
                                                    run: (lambda (input cancelled? post!)
                                                           (post! 'dropped)
                                                           (completion-post! posted #t)
                                                           (job-sleep 10 cancelled?)
                                                           'end)
                                                    apply: (lambda (result) (set! applied (cons result applied)))))
                            (completion-wait! posted)
                            (job-cancel! j))))
           (thread-sleep! 0.1)
           (check (applied-after 0) => [])))))

    (test-case "job-sleep returns #t after its delay, and #f at once when the job is cancelled"
      (with-jobs
       (lambda ()
         (let ((woke #f)
               (cancelled-at #f))
           (on-baton
            (lambda ()
              (job-group-start! starter 'short input: 0.05
                                run: (lambda (seconds cancelled? post!) (job-sleep seconds cancelled?))
                                apply: (lambda (result) (set! applied (cons result applied))))))
           (check (applied-after 1) => '(#t))
           (let (j (on-baton
                    (lambda ()
                      (job-group-start! starter 'long input: 10
                                        run: (lambda (seconds cancelled? post!)
                                               (job-sleep seconds cancelled?)
                                               (set! woke (time->seconds (current-time))))
                                        apply: void))))
             (thread-sleep! 0.05)
             (on-baton (lambda ()
                         (set! cancelled-at (time->seconds (current-time)))
                         (job-cancel! j)))
             (check (wait-until (lambda () woke)) => #t)
             (check (< (- woke cancelled-at) 0.05) => #t))))))

    (test-case "a job without a target applies every result until cancelled"
      (with-jobs
       (lambda ()
         (on-baton
          (lambda ()
            (job-group-start! starter 'untargeted input: 'x
                              run: (lambda (input cancelled? post!) (post! 'posted) input)
                              apply: (lambda (result) (set! applied (cons result applied))))))
         (check (applied-after 2) => '(posted x)))))

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
