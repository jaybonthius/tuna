(import (tuna) (test) (buffers) (buffers-test))

(test "a new buffer is unmodified, an edit modifies it, and set-modified! marks it either way"
  (let ([notes (buffers-test:fresh "Buy milk.\n")])
    (check-equal? #f (buffers:modified? notes))
    (buffers:replace! notes 1 1 "Today: ")
    (check-equal? #t (buffers:modified? notes))
    (buffers:set-modified! notes #f)
    (check-equal? '(#f 1 1) (list (buffers:modified? notes) (buffers:version notes) (buffers:save-stamp notes)))
    (buffers:set-modified! notes 'yes)
    (check-equal? '(#t -2) (list (buffers:modified? notes) (buffers:save-stamp notes)))
    (buffers:set-modified! notes #t)
    (check-equal? -2 (buffers:save-stamp notes))))

(test "set-modified! raises for a killed buffer and on another thread"
  (let ([b (buffers-test:fresh "x\n")])
    (check-equal? '(buffers:set-modified! "not on the main thread")
      (buffers-test:on-thread (lambda () (buffers:set-modified! b #f))))
    (check-equal? #f (buffers-test:on-thread (lambda () (buffers:modified? b))))
    (buffers:kill! b)
    (check-raises (buffers-test:raised? 'buffers:set-modified! "not a live buffer") (buffers:set-modified! b #f))))

(test "an edit to a buffer inside with-silent-edits of it is silent and leaves modified? as it was; edits to other buffers there are not"
  (let ([quiet (buffers-test:fresh "abc\n")] [other (buffers-test:fresh "xyz\n")])
    (check-equal? '(one two)
      (call-with-values
        (lambda () (buffers:with-silent-edits quiet (buffers:replace! other 1 1 "o") (buffers:replace! quiet 1 1 "q") (values 'one 'two)))
        list))
    (check-equal? '(#f #t (#t) (#f))
      (list (buffers:modified? quiet) (buffers:modified? other) (map buffers:edit-silent? (buffers:edits-since quiet 0))
            (map buffers:edit-silent? (buffers:edits-since other 0))))
    (check-equal? 1 (buffers:save-stamp quiet))
    (buffers:replace! quiet 1 1 "Q")
    (buffers:call-with-silent-edits quiet (lambda () (buffers:replace! quiet 1 1 "q")))
    (check-equal? '(#t 1) (list (buffers:modified? quiet) (buffers:save-stamp quiet)))))

(test "a task that pauses inside with-silent-edits is still inside it when it resumes"
  (let* ([quiet (buffers-test:fresh "abc\n")] [resume-it #f]
         [task (spawn-task
                 (lambda (restore)
                   (buffers:with-silent-edits quiet
                     (suspend (lambda (resume) (set! resume-it resume)))
                     (buffers:replace! quiet 1 1 "p"))))])
    (suspend (lambda (resume) (spawn-task (lambda (restore) (resume void)))))
    (check (procedure? resume-it))
    (buffers:replace! quiet 1 1 "n")
    (resume-it void)
    (join-task task)
    (check-equal? '(#f #t) (map buffers:edit-silent? (buffers:edits-since quiet 0)))))

(test "a silent buffer makes every edit silent; one made with an internal name starts so, and set-silent! turns it either way"
  (let ([quiet (buffers-test:fresh "abc\n")] [internal (buffers:make " internal" "\n")])
    (check-equal? '(#f #t) (list (buffers:silent? quiet) (buffers:silent? internal)))
    (buffers:set-silent! quiet #t)
    (check-equal? '(#t #t #f) (list (buffers:silent? quiet) (buffers:edit-silent? (buffers:replace! quiet 1 1 "s")) (buffers:modified? quiet)))
    (buffers:set-silent! internal #f)
    (check-equal? '(#f #f #t) (list (buffers:silent? internal) (buffers:edit-silent? (buffers:replace! internal 1 1 "s")) (buffers:modified? internal)))))

(test "the silent procedures check their arguments"
  (let ([quiet (buffers-test:fresh "abc\n")])
    (check-raises (buffers-test:raised? 'buffers:silent? "not a buffer") (buffers:silent? 'x))
    (check-raises (buffers-test:raised? 'buffers:set-silent! "not a buffer") (buffers:set-silent! 'x #t))
    (check-raises (buffers-test:raised? 'buffers:call-with-silent-edits "not a buffer") (buffers:call-with-silent-edits 'x void))
    (check-raises (buffers-test:raised? 'buffers:call-with-silent-edits "not a procedure") (buffers:call-with-silent-edits quiet 'x))
    (check-raises (buffers-test:raised? 'buffers:edit-silent? "not an edit") (buffers:edit-silent? 'x))))
