(import (tuna) (test) (test-runner) (hooks) (options) (sampler) (processes) (system-processes) (sampler-test)
        (only (host) host-user-name) (only (procfs) make-procfs procfs-process-stat proc-stat-name procfs-process-command-line)
        (only (process) pid-priority system-error?) (only (system-processes rows) boot-start-field))

(define (fixture name)
  (string-append (path-parent (car (command-line))) "/plugins/system-processes/tests/lib/system-processes-test/fixtures/"
                 name))

(define (ignore-output bytes end) (void))

(define (row-of pid) (system-processes:row pid))

(define (wait-for-row pid)
  (test-runner:wait-until (lambda () (row-of pid)))
  (row-of pid))

(test "nobody wants the rows, so there are none"
  (check-equal? '() (system-processes:rows))
  (check-equal? #f (sampler:interval system-processes:source)))

(test "the test's own process is a row with its name, arguments, effective id and user"
  (sampler-test:wanting system-processes:source 1
    (lambda ()
      (let* ([pid (get-process-id)] [r (wait-for-row pid)] [fs (make-procfs)])
        (check-equal? (proc-stat-name (procfs-process-stat fs pid)) (system-processes:row-comm r))
        (check-equal? (procfs-process-command-line fs pid) (system-processes:row-args r))
        (check (pair? (system-processes:row-args r)))
        (check-equal? (host-user-name (system-processes:row-euid r)) (system-processes:row-user r))
        (check (string? (system-processes:row-group r)))
        (check-equal? "/" (substring (system-processes:row-cgroup r) 0 1))
        (check (system-processes:row? r))
        (check-equal? #f (system-processes:row 999999999))
        (check-equal? #f (system-processes:row? (vector 1 2 3)))))))

(test "a process Tuna started has Tuna as its parent, and is gone from the rows within two readings after it ends"
  (let ([p (processes:start "sleep" '("60") ignore-output)])
    (sampler-test:wanting system-processes:source 1
      (lambda ()
        (let ([r (wait-for-row (processes:pid p))])
          (check-equal? (get-process-id) (system-processes:row-ppid r))
          (check-equal? '("sleep" "60") (system-processes:row-args r))
          (processes:stop! p)
          (test-runner:wait-until (lambda () (not (row-of (processes:pid p))))))))))

(test "a process's first reading has no recent CPU use; the next has, and a busy process uses most of a core"
  (let ([busy (processes:start "sh" '("-c" "exec yes > /dev/null") ignore-output)])
    (sampler-test:wanting system-processes:source 3600
      (lambda ()
        (let ([pid (processes:pid busy)])
          (test-runner:wait-until (lambda () (row-of pid)))
          (check-equal? #f (system-processes:row-cpu-usage (row-of pid)))
          (sampler-test:reading! system-processes:source)
          (check (> (system-processes:row-cpu-usage (row-of pid)) 0.5))
          (check (for-all (lambda (r) (let ([u (system-processes:row-cpu-usage r)]) (or (not u) (>= u 0))))
                          (system-processes:rows))))))
    (processes:stop! busy)))

(test "processes that end while a reading runs are left out, and nothing is reported"
  (let ([churn (processes:start "sh" '("-c" "while :; do /bin/true; done") ignore-output)])
    (check-equal? '()
      (test-runner:reports-during
        (lambda ()
          (sampler-test:wanting system-processes:source 3600
            (lambda ()
              (sampler-test:reading! system-processes:source)
              (sampler-test:reading! system-processes:source)
              (check (> (length (system-processes:rows)) 10)))))))
    (processes:stop! churn)))

(test "a signal reaches the process its row names, once; a row whose start no longer matches sends nothing"
  (let ([p (processes:start "sleep" '("60") ignore-output)])
    (sampler-test:wanting system-processes:source 1
      (lambda ()
        (let* ([r (wait-for-row (processes:pid p))]
               [copy (let ([v (vector-copy r)])
                       (vector-set! v boot-start-field (+ (system-processes:row-boot-start r) 1))
                       (vector->immutable-vector v))])
          (check-equal? #f (system-processes:signal! copy 'term))
          (check-equal? #f (processes:status p))
          (check-equal? #t (system-processes:set-priority! r 10))
          (check-equal? 10 (pid-priority (processes:pid p)))
          (check-equal? #f (system-processes:set-priority! copy 5))
          (check-equal? #t (system-processes:signal! r 'term))
          (test-runner:wait-until (lambda () (processes:status p)))
          (check-equal? #f (system-processes:signal! r 'term)))))))

(test "signalling a process of another user raises a system error"
  (sampler-test:wanting system-processes:source 3600
    (lambda ()
      (check-raises system-error? (system-processes:signal! (row-of 1) 'term)))))

(test "updated runs once per reading, after the rows are the new ones"
  (let ([calls '()])
    (define (note) (set! calls (cons (system-processes:rows) calls)))
    (hooks:add! system-processes:updated note)
    (sampler-test:wanting system-processes:source 3600
      (lambda ()
        (sampler-test:reading! system-processes:source)
        (check-equal? 2 (length calls))
        (check (eq? (car calls) (system-processes:rows)))
        (check (not (eq? (car calls) (cadr calls))))))
    (hooks:remove! system-processes:updated note)))

(test "an accessor of something that is not a row raises naming the accessor"
  (check-equal? 'system-processes:row-pid
    (guard (c [(assertion-violation? c) (condition-who c)]) (system-processes:row-pid (vector 1))))
  (check-raises assertion-violation? (system-processes:signal! 'row 'term))
  (check-raises assertion-violation? (system-processes:set-priority! 'row 1)))

(test "lifetime CPU and memory shares follow from the row's own numbers"
  (sampler-test:wanting system-processes:source 3600
    (lambda ()
      (let ([r (row-of (get-process-id))])
        (check-equal? (inexact (/ (system-processes:row-time r) (system-processes:row-etime r)))
          (system-processes:row-cpu-average r))
        (check (<= 0 (system-processes:row-memory-share r) 1))))))

(define link (string-append (getenv "HOME") "/proc"))

(options:set! system-processes:proc-root link)

(test "the real (sd-pam) row: its name, no tty, its counts and sizes, and its elapsed time from the uptime"
  (sampler-test:point! link (fixture "proc-a"))
  (sampler-test:wanting system-processes:source 3600
    (lambda ()
      (let ([r (row-of 1483)])
        (check-equal? "(sd-pam)" (system-processes:row-comm r))
        (check-equal? #f (system-processes:row-ttname r))
        (check-equal? -1 (system-processes:row-tpgid r))
        (check-equal? 54 (system-processes:row-minflt r))
        (check-equal? 1 (system-processes:row-thcount r))
        (check-equal? 23805952 (system-processes:row-vsize r))
        (check-equal? (* 452 4096) (system-processes:row-rss r))
        (check-equal? (- 259689565/100 4281/100) (system-processes:row-etime r))
        (check-equal? 4281/100 (system-processes:row-boot-start r))
        (check-equal? "S" (system-processes:row-state r))
        (check-equal? (inexact (/ (* 452 4096) (* 63556148 1024))) (system-processes:row-memory-share r))))))

(test "a process's arguments, user and cgroup are read again at each reading, and an id no account has has no name"
  (sampler-test:point! link (fixture "proc-a"))
  (sampler-test:wanting system-processes:source 3600
    (lambda ()
      (let ([first (row-of 4242)])
        (check-equal? '("worker" "--first") (system-processes:row-args first))
        (check-equal? 4242424 (system-processes:row-euid first))
        (check-equal? #f (system-processes:row-user first))
        (check-equal? #f (system-processes:row-group first)))
      (sampler-test:point! link (fixture "proc-b"))
      (sampler-test:reading! system-processes:source)
      (let ([second (row-of 4242)])
        (check-equal? '("worker" "--second") (system-processes:row-args second))
        (check-equal? 4242425 (system-processes:row-euid second))
        (check-equal? "/second.slice" (system-processes:row-cgroup second))))))

(test "a process that has run for no time has no lifetime CPU share, and the reading goes on"
  (sampler-test:point! link (fixture "proc-zero"))
  (sampler-test:wanting system-processes:source 3600
    (lambda ()
      (check-equal? 0 (system-processes:row-etime (row-of 1483)))
      (check-equal? #f (system-processes:row-cpu-average (row-of 1483)))
      (check (row-of 4242)))))

;; The tree names a process of this machine, a child started here, with a
;; start this process never had, as a tree of another pid namespace may.
(test "a row read from another tree is checked against Tuna's own processes before a signal, and is refused when its start differs"
  (let* ([p (processes:start "sleep" '("60") ignore-output)]
         [pid (begin (test-runner:wait-until (lambda () (processes:pid p))) (number->string (processes:pid p)))]
         [tree (sampler-test:scratch "proc-other")]
         [from (string-append (fixture "proc-a") "/4242/")])
    (sampler-test:copy-tree! (fixture "proc-a") tree)
    (mkdir (string-append tree "/" pid))
    (for-each
      (lambda (file)
        (sampler-test:write-text! (string-append tree "/" pid "/" file)
          (let ([text (sampler-test:read-text (string-append from file))])
            (if (string=? file "stat") (string-append pid (substring text 4 (string-length text))) text))))
      '("stat" "status" "cmdline" "cgroup"))
    (sampler-test:point! link tree)
    (sampler-test:wanting system-processes:source 3600
      (lambda ()
        (let ([r (row-of (processes:pid p))])
          (check-equal? 4281/100 (system-processes:row-boot-start r))
          (check-equal? #f (system-processes:signal! r 'term))
          (check-equal? #f (system-processes:set-priority! r 10))
          (check-equal? #f (processes:status p)))))
    (processes:stop! p)))

(options:unset! system-processes:proc-root)

(test "the plugin's module does not import (host), so no account lookup can run on the main thread"
  (let ([source (call-with-input-file (string-append (path-parent (car (command-line)))
                                                     "/plugins/system-processes/src/system-processes.sls")
                  (lambda (p) (get-line p) (read p)))])
    (check-equal? 'import (car source))
    (check (not (member '(host) (cdr source))))
    (check (not (exists (lambda (spec) (and (pair? spec) (member '(host) spec))) (cdr source))))))
