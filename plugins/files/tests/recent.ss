(import (tuna) (test) (test-runner) (hooks) (options) (commands) (buffers) (files) (files-test))

(define (home name) (files-test:expand (string-append "~/" name)))

(define (recent) (files:recent-files))

(for-each (lambda (name) (files-test:write-text! (string-append "~/" name) (string-append name "\n")))
          '("a.txt" "b.txt" "c.txt" "d.txt" "COMMIT_EDITMSG" "kept.txt" "gone.txt" "other-gone.txt"))

(define a (files:visit "~/a.txt"))
(define b (files:visit "~/b.txt"))

(test "a visited file is first in files:recent-files; visiting a file whose buffer is open changes nothing"
  (check-equal? (list (home "b.txt") (home "a.txt")) (recent))
  (files:visit "~/a.txt")
  (check-equal? (list (home "b.txt") (home "a.txt")) (recent)))

(test "a save makes its file the newest, and so does a write to another path, which records the new path"
  (buffers:replace! a 1 1 "saved ")
  (files:save-buffer a)
  (check-equal? (list (home "a.txt") (home "b.txt")) (recent))
  (files:write-file "~/b2.txt" b)
  (check-equal? (list (home "b2.txt") (home "a.txt") (home "b.txt")) (recent)))

(test "a temporary visit, as a picker's preview makes, records nothing until a visit completes it"
  (let ([c (files:visit-temporarily "~/c.txt")])
    (check-equal? #f (member (home "c.txt") (recent)))
    (files:visit "~/c.txt")
    (check-equal? (home "c.txt") (car (recent)))
    (buffers:kill! c)))

(test "with files:recent-limit 3, a fourth file drops the oldest at once"
  (options:set! files:recent-limit 3)
  (files:visit "~/d.txt")
  (check-equal? (list (home "d.txt") (home "c.txt") (home "b2.txt")) (recent))
  (options:unset! files:recent-limit)
  (check-equal? 20 (files:recent-limit)))

(define (commit-message? path) (string=? (path-last path) "COMMIT_EDITMSG"))

(test "a path an entry of files:recent-excluded accepts is not recorded"
  (hooks:add! files:recent-excluded commit-message?)
  (files:visit "~/COMMIT_EDITMSG")
  (check-equal? #f (member (home "COMMIT_EDITMSG") (recent)))
  (hooks:remove! files:recent-excluded commit-message?))

(test "killing the buffer of a recorded file that is gone removes only that file: the killed buffer of a file that exists, and another gone file not killed, stay"
  (let ([kept (files:visit "~/kept.txt")] [gone (files:visit "~/gone.txt")] [other (files:visit "~/other-gone.txt")])
    (delete-file (home "other-gone.txt"))
    (buffers:kill! kept)
    (delete-file (home "gone.txt"))
    (buffers:kill! gone)
    (test-runner:wait-until (lambda () (not (member (home "gone.txt") (recent)))))
    (check (member (home "kept.txt") (recent)))
    (check (member (home "other-gone.txt") (recent)))))

(test "a visit of a file that does not exist is recorded, and files:cleanup-recent removes it with every other path that cannot be read"
  (let ([new (files:visit "~/new.txt")])
    (check-equal? (home "new.txt") (car (recent)))
    (buffers:kill! new)
    (files-test:write-text! "~/locked.txt" "locked\n")
    (files:visit "~/locked.txt")
    (files-test:set-mode! "~/locked.txt" #o000)
    (files:cleanup-recent)
    (check-equal? #f (member (home "new.txt") (recent)))
    (check-equal? #f (member (home "other-gone.txt") (recent)))
    (check-equal? #f (member (home "locked.txt") (recent)))
    (check (member (home "kept.txt") (recent)))
    (files-test:set-mode! "~/locked.txt" #o644)))

(test "files:forget-recent! removes a recorded path, does nothing for one not recorded, and raises for a non-string"
  (files:forget-recent! (home "kept.txt"))
  (check-equal? #f (member (home "kept.txt") (recent)))
  (let ([before (recent)])
    (files:forget-recent! (home "never.txt"))
    (check-equal? before (recent)))
  (check-raises assertion-violation? (files:forget-recent! 'kept)))
