(import (tuna) (test) (hooks) (options) (ask) (commands) (buffers) (files) (files-test))

(options:set! files:require-final-newline #t)

(files-test:folder! "~/repo")
(files-test:write-text! "~/repo/a.py" "a\n")
(files-test:write-text! "~/repo/b.py" "b\n")
(files-test:write-text! "~/other.txt" "o\n")

(define a (files:visit "~/repo/a.py"))
(define other (files:visit "~/other.txt"))
(define b (files:visit "~/repo/b.py"))

(define (in-repo? buffer)
  (let ([p (files:path buffer)] [repo (files-test:expand "~/repo/")])
    (and p (string=? (substring p 0 (min (string-length p) (string-length repo))) repo))))

(test "files:save-some-buffers asks only about the modified file buffers its predicate accepts, in the order they were visited"
  (for-each (lambda (x) (buffers:replace! x 1 1 "edit ")) (list a other b))
  (options:set! ask:y-or-n-reader (files-test:answer #t))
  (files:save-some-buffers in-repo?)
  (check-equal? '(("Save file ~/repo/a.py? " "Save file ~/repo/b.py? ") (#f #t #f))
    (list (files-test:questions) (map buffers:modified? (list a other b)))))

(test "run by a key, it accepts every file buffer"
  (commands:run files:save-some-buffers)
  (check-equal? '(("Save file ~/other.txt? ") #f) (list (files-test:questions) (buffers:modified? other)))
  (check-raises assertion-violation? (files:save-some-buffers 'all))
  (options:unset! ask:y-or-n-reader))

(define reverts 0)

(define (count-revert buffer) (set! reverts (+ reverts 1)))

(test "files:revert-changed-buffers reverts each unmodified file buffer the predicate accepts whose file changed, asking nothing; a modified buffer keeps its edits, and one whose file is gone stays"
  (files-test:write-text! "~/repo/gone.py" "g\n")
  (let ([gone (files:visit "~/repo/gone.py")])
    (buffers:replace! a 1 1 "unsaved ")
    (files-test:write-text! "~/repo/a.py" "git wrote a\n")
    (files-test:write-text! "~/repo/b.py" "git wrote b\n")
    (files-test:write-text! "~/other.txt" "changed too\n")
    (delete-file (files-test:expand "~/repo/gone.py"))
    (files:revert-changed-buffers in-repo?)
    (check-equal? '(("unsaved edit a\n" #t) ("git wrote b\n" #f) ("edit o\n" #f) ("g\n" #f))
      (map (lambda (x) (list (files-test:text x) (buffers:modified? x))) (list a b other gone)))
    (check-equal? '() (files-test:questions))))

(test "an unchanged file's buffer is not read again"
  (hooks:add! files:after-revert count-revert)
  (files:revert-changed-buffers in-repo?)
  (check-equal? 0 reverts)
  (files:revert-changed-buffers (lambda (buffer) #t))
  (check-equal? '(1 "changed too\n") (list reverts (files-test:text other)))
  (hooks:remove! files:after-revert count-revert)
  (check-raises assertion-violation? (files:revert-changed-buffers #f)))
