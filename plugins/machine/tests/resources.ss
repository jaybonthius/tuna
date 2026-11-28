(import (tuna) (test) (test-runner) (options) (tables) (sampler) (metrics) (machine) (machine-test) (sampler-test) (metrics-test latest))

(define (prefix? prefix s)
  (and (>= (string-length s) (string-length prefix)) (string=? prefix (substring s 0 (string-length prefix)))))

(test "memory used is total less available, at the same time"
  (sampler-test:wanting machine:memory 1
    (lambda ()
      (test-runner:wait-until (lambda () (metrics:latest machine:memory-used '())))
      (let ([used (metrics:latest machine:memory-used '())])
        (check-equal? (car used) (car (metrics:latest machine:memory-total '())))
        (check-equal? (cdr used) (- (metrics-test/latest:latest-value machine:memory-total '()) (metrics-test/latest:latest-value machine:memory-available '())))))))

(test "the network filter leaves Docker's veth interfaces out; the loopback and the wired interface are recorded"
  (options:set! machine:network-filter (lambda (name) (not (prefix? "veth" name))))
  (sampler-test:wanting machine:network 1
    (lambda ()
      (test-runner:wait-until (lambda () (metrics:latest machine:network-receive '("lo"))))
      (let ([interfaces (map car (metrics:label-sets machine:network-receive))])
        (check (member "lo" interfaces))
        (check (member "enp2s0" interfaces))
        (check (not (exists (lambda (name) (prefix? "veth" name)) interfaces))))))
  (options:unset! machine:network-filter))

(test "on this machine the root file system is recorded, and a file system that needs no device is not"
  (sampler-test:wanting machine:file-systems 1
    (lambda ()
      (test-runner:wait-until (lambda () (metrics:latest machine:file-system-size '("/"))))
      (check (>= (metrics-test/latest:latest-value machine:file-system-size '("/")) (metrics-test/latest:latest-value machine:file-system-available '("/")) 1))
      (check (not (member '("/proc") (metrics:label-sets machine:file-system-size)))))))

(define link (sampler-test:scratch "proc"))

(define (pair-of source a b) (machine-test:pair-of source link a b))

(options:set! machine:proc-root link)

(test "a counter that drops gives no rate for that interval"
  (let ([dropped (sampler-test:variant! "proc-lo-dropped" (machine-test:fixture "proc-2") "net/dev"
                   (lambda (text) (machine-test:replace-line text "    lo: " "    lo: 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0")))])
    (pair-of machine:network (machine-test:fixture "proc-1") dropped)
    (let ([time (sampler:last-time machine:network)])
      (check-equal? time (car (metrics:latest machine:network-receive '("enp2s0"))))
      (check (not (eqv? time (car (metrics:latest machine:network-receive '("lo")))))))))

(test "a kernel without pressure files records no pressure, and the source does not fail"
  (let ([old (sampler-test:variant! "proc-without-pressure" (machine-test:fixture "proc-1") "stat" (lambda (text) text))])
    (for-each (lambda (f) (delete-file (string-append old "/pressure/" f))) '("cpu" "memory" "io"))
    (pair-of machine:pressure old old)
    (check-equal? #f (sampler:failure machine:pressure))
    (check-equal? '() (metrics:label-sets machine:io-pressure-some))))

;; The pair was read seconds apart and is read here within milliseconds, so
;; the rate is only checked for its kind.
(test "pressure is a rate of each file's total, recorded from the second reading on"
  (pair-of machine:pressure (machine-test:fixture "proc-1") (machine-test:fixture "proc-2"))
  (let ([io (metrics-test/latest:latest-value machine:io-pressure-some '())])
    (check (flonum? io))
    (check (>= io 0))
    (check-equal? (sampler:last-time machine:pressure) (car (metrics:latest machine:cpu-pressure-full '())))))

(test "a mount whose file system cannot be asked for its space is skipped and the rest are recorded"
  (let ([ghost (sampler-test:variant! "proc-with-ghost-mount" (machine-test:fixture "proc-1") "self/mountinfo"
                 (lambda (text) (string-append text "999 1 259:9 / /nonexistent-mount rw,relatime - ext4 /dev/ghost rw\n")))])
    (pair-of machine:file-systems ghost ghost)
    (check (metrics:latest machine:file-system-size '("/")))
    (check (not (member '("/nonexistent-mount") (metrics:label-sets machine:file-system-size))))))

(test "setting the root restarts the sources; readings then come from the new root"
  (let ([fixture-free (* 1024 (string->number (cadr (machine-test:words (find (lambda (l) (prefix? "MemFree:" l))
                                                                    (machine-test:split-lines
                                                                      (sampler-test:read-text (machine-test:fixture "proc-1/meminfo"))))))))])
    (sampler-test:wanting machine:memory 3600
      (lambda ()
        (options:set! machine:proc-root (machine-test:fixture "proc-1"))
        (test-runner:wait-until (lambda () (eqv? (exact (metrics-test/latest:latest-value machine:memory-free '())) fixture-free)))
        (options:set! machine:proc-root "/proc")
        (test-runner:wait-until (lambda () (not (eqv? (exact (metrics-test/latest:latest-value machine:memory-free '())) fixture-free))))))))

(options:set! machine:sys-root (machine-test:fixture "sys"))

(metrics:define-metric gtt-used (unit bytes) (labels card))

(test "a table entry for another file of the card fills the metric it names, from the next restart"
  (tables:set! machine:gpu-attributes "mem_info_gtt_used" (cons gtt-used 1))
  (sampler-test:wanting machine:gpu 3600
    (lambda ()
      (test-runner:wait-until (lambda () (metrics:latest gtt-used '("card0"))))
      (check-equal? (exact (metrics-test/latest:latest-value gtt-used '("card0")))
        (string->number (car (machine-test:split-lines
                               (sampler-test:read-text
                                 (machine-test:fixture "sys/devices/pci0000:00/0000:00:08.1/0000:c5:00.0/mem_info_gtt_used"))))))
      (check-equal? 0.0 (metrics-test/latest:latest-value machine:gpu-busy '("card0")))))
  (tables:remove! machine:gpu-attributes "mem_info_gtt_used"))
