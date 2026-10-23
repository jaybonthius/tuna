;;; Reading processes from a /proc-like directory (proced plugin).
(import :std/error
        :std/test
        :tuna/plugins/proced/plugin
        "../support/proc-fixture")
(export read-test)

(def (rows reading) (car reading))

(def read-test
  (test-suite "tuna/plugins/proced: reading processes"
    (test-case "rows by pid, formatted as shown; a command may hold spaces and parentheses"
      (let (root (make-proc-fixture))
        (try
         (write-process! root 42 command: "a (b) c" state: "R" ticks: 6150 rss: 2560)
         (write-process! root 7)
         (create-directory* (path-expand "self" root))      ; not a pid
         (create-directory* (path-expand "99" root))        ; went away: no stat
         (check (rows (read-processes root #f))
                => '((7 "S" "0.0" "1.0" "0:00" "sleep")
                     (42 "R" "0.0" "10.0" "1:01" "a (b) c")))
         (finally (delete-proc-fixture root)))))

    (test-case "%CPU is the processor time since the previous reading over the time passed"
      (let* ((first (processes-reading [[1 "busy" "R" 100 0] [2 "idle" "S" 7 0]] 10. #f))
             (second (processes-reading [[1 "busy" "R" 150 0] [2 "idle" "S" 7 0] [3 "new" "S" 900 0]] 11. first)))
        (check (map caddr (rows first)) => '("0.0" "0.0"))
        (check (map caddr (rows second)) => '("50.0" "0.0" "0.0"))
        (check (cdr second) => '(11. (1 . 150) (2 . 7) (3 . 900)))))

    (test-case "a missing root is an error, which the source reports"
      (check (with-catch (lambda (e) 'raised) (lambda () (read-processes "/nonexistent-tuna-proc" #f)))
             => 'raised))))
