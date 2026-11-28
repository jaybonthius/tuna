(import (tuna) (test) (test-runner) (options) (sampler) (metrics) (machine) (machine-test) (sampler-test) (metrics-test latest))

(define (stat-line tree)
  (car (machine-test:split-lines (sampler-test:read-text (string-append tree "/stat")))))

(define (ticks line) (map string->number (cdr (machine-test:words line))))

(define link (sampler-test:scratch "proc"))

(define (pair-of a b) (machine-test:pair-of machine:cpu link a b))


(test "on this machine CPU usage is a share, recorded from the second reading on"
  (sampler-test:wanting machine:cpu 1
    (lambda ()
      (check-equal? #f (metrics:latest machine:cpu-usage '()))
      (test-runner:wait-until (lambda () (metrics:latest machine:cpu-usage '())))
      (let ([usage (metrics-test/latest:latest-value machine:cpu-usage '())])
        (check (flonum? usage))
        (check (<= 0 usage 1)))
      (check-equal? 16 (length (metrics:label-sets machine:cpu-core-usage))))))

(options:set! machine:proc-root link)

(test "the mode shares of a real pair of readings sum to 1"
  (pair-of (machine-test:fixture "proc-1") (machine-test:fixture "proc-2"))
  (let* ([modes '(user nice system idle iowait irq softirq steal)]
         [shares (map (lambda (m) (metrics:latest machine:cpu-mode-share (list m))) modes)])
    (check (for-all pair? shares))
    (check (apply = (map car shares)))
    (check-compare (lambda (a b) (< (abs (- a b)) 1e-12)) 1.0 (apply + (map cdr shares)))))

(test "a processor gone in the second reading gets no point for it; the others do"
  (let ([gone (sampler-test:variant! "proc-without-cpu15" (machine-test:fixture "proc-2") "stat"
                (lambda (text) (machine-test:replace-line text "cpu15 " #f)))])
    (pair-of (machine-test:fixture "proc-1") gone)
    (let ([time (sampler:last-time machine:cpu)])
      (check-equal? time (car (metrics:latest machine:cpu-core-usage '(0))))
      (check (not (equal? time (car (metrics:latest machine:cpu-core-usage '(15)))))))))

(test "an iowait that goes down counts as no time, so usage is still recorded"
  (let* ([before (ticks (stat-line (machine-test:fixture "proc-1")))]
         [after (list (+ (list-ref before 0) 100) (list-ref before 1) (list-ref before 2) (+ (list-ref before 3) 100)
                      (- (list-ref before 4) 10) (list-ref before 5) (list-ref before 6) (list-ref before 7)
                      (list-ref before 8) (list-ref before 9))]
         [lower (sampler-test:variant! "proc-iowait-lower" (machine-test:fixture "proc-1") "stat"
                  (lambda (text)
                    (machine-test:replace-line text "cpu  "
                      (apply string-append "cpu " (map (lambda (n) (string-append " " (number->string n))) after)))))])
    (pair-of (machine-test:fixture "proc-1") lower)
    (check-equal? (sampler:last-time machine:cpu) (car (metrics:latest machine:cpu-usage '())))
    (check-equal? 0.5 (metrics-test/latest:latest-value machine:cpu-usage '()))))

(options:unset! machine:proc-root)

(test "on this machine each processor's frequency is recorded in hertz, within its limits"
  (sampler-test:wanting machine:cpufreq 1
    (lambda ()
      (test-runner:wait-until (lambda () (= 16 (length (metrics:label-sets machine:cpu-frequency)))))
      (for-each
        (lambda (cpu)
          (let ([hz (metrics-test/latest:latest-value machine:cpu-frequency (list cpu))]
                [limit (lambda (file)
                         (* 1000 (string->number
                                   (car (machine-test:split-lines
                                          (sampler-test:read-text
                                            (format "/sys/devices/system/cpu/cpu~a/cpufreq/~a" cpu file)))))))])
            (check (<= (* 0.5 (limit "scaling_min_freq")) hz (* 1.5 (limit "scaling_max_freq"))))))
        (iota 16)))))

(test "while nobody wants them, no source of the plugin has an interval, and each metric names its source"
  (for-each (lambda (s) (check-equal? #f (sampler:interval s)))
            (list machine:cpu machine:cpufreq machine:memory machine:load machine:pressure machine:disks
                  machine:file-systems machine:network machine:gpu))
  (check-equal? machine:cpu (metrics:source machine:cpu-usage))
  (check-equal? machine:gpu (metrics:source machine:gpu-busy))
  (check-equal? 'ratio (metrics:unit machine:cpu-usage)))
