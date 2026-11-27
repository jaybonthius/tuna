(import (tuna) (test) (test-runner) (git) (git-test repositories))

(define (file i) (string-append "f" (number->string (+ 1 (mod i 300))) ".txt"))

(define (index-bytes) (call-with-port (open-file-input-port (git-test/repositories:path "lk/.git/index")) get-bytevector-all))

(mkdir (git-test/repositories:path "lk"))
(git-test/repositories:git! "lk" "init" "-q" "-b" "main")
(for-each (lambda (i) (git-test/repositories:write-file! (string-append "lk/" (file i)) (format "~a\n" i))) (iota 300))
(git-test/repositories:git! "lk" "add" "-A")
(git-test/repositories:git! "lk" "commit" "-qm" "base")

(define repo (git:find-repository (git-test/repositories:path "lk")))

(test "a query takes no optional lock: git status does not refresh the index for a file whose time changed"
  (let ([before (index-bytes)])
    (git-test/repositories:run! "lk" "touch" "-d" (format "@~a" (+ (time-second (current-time)) 10)) "f1.txt")
    (check-equal? '() (git:status-entries (git:status repo)))
    (check-equal? before (index-bytes))))

(test "queries in a loop beside 150 commands make none of them fail on the index lock"
  (let* ([stop? #f] [query-failures '()] [command-failures '()]
         [readers (map (lambda (i)
                         (spawn-task
                           (lambda (restore)
                             (let loop ()
                               (unless stop?
                                 (guard (c [(git:failed-condition? c) (set! query-failures (cons (git:failure-summary c) query-failures))])
                                   (git:status repo))
                                 (loop))))))
                       '(1 2 3))]
         [writer (spawn-task
                   (lambda (restore)
                     (for-each
                       (lambda (i)
                         (git-test/repositories:write-file! (string-append "lk/" (file i)) (format "v~a\n" i))
                         (guard (c [(git:failed-condition? c) (set! command-failures (cons (git:failure-summary c) command-failures))])
                           (git:stage repo (list (file i)))))
                       (iota 150))))])
    (test-runner:join writer)
    (set! stop? #t)
    (for-each test-runner:join readers)
    (check-equal? '() command-failures)
    (check-equal? '() query-failures)))
