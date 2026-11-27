(import (tuna) (test) (test-runner) (hooks) (timers) (document) (buffers) (files) (files-test))

(define a #f)
(define b #f)

(test "reloading files alone takes back its live buffers, unsaved edits and modified flags included"
  (files-test:write-text! "~/a.txt" "alpha\n")
  (files-test:write-text! "~/b.txt" "beta\n")
  (set! a (files:visit "~/a.txt"))
  (set! b (files:visit "~/b.txt"))
  (buffers:replace! a 1 1 "unsaved ")
  (buffers:rename! b "my b")
  (reload-modules! '((files)))
  (check-equal? (list (list a b) #t #f (files-test:expand "~/b.txt"))
    (list (files:buffers) (buffers:modified? a) (buffers:modified? b) (files:path b)))
  (check (eq? b (files:visit "~/b.txt")))
  (files:save-buffer a)
  (check-equal? '("unsaved alpha\n" #f) (list (files-test:read-text "~/a.txt") (buffers:modified? a))))

(test "reloading buffers closes every buffer, so files visits each file again; without undo an unsaved edit is lost"
  (buffers:replace! a 1 1 "again ")
  (reload-modules! '((buffers)))
  (test-runner:wait-until (lambda () (= (length (files:buffers)) 2)))
  (let ([a2 (car (files:buffers))])
    (check-equal? '(#f "a.txt" "unsaved alpha\n" #f ("a.txt" "b.txt"))
      (list (buffers:live? a) (buffers:name a2) (files-test:text a2) (buffers:modified? a2) (map buffers:name (files:buffers))))))

(define (with-unsaved read path)
  (let-values ([(doc length hash) (read path)])
    (values (document:replace doc 1 1 (document:from-datum "restored ")) length hash)))

(test "advice on files:read-document lets a visit carry edits made before the buffer exists, as undo-log's does; the buffer starts modified"
  (advice-add! files:read-document with-unsaved)
  (files-test:write-text! "~/c.txt" "gamma\n")
  (let ([c (files:visit "~/c.txt")])
    (check-equal? '("restored gamma\n" #t 6)
      (list (files-test:text c) (buffers:modified? c) (call-with-values (lambda () (files:fingerprint c)) (lambda (n h) n))))
    (advice-remove! files:read-document with-unsaved)
    (files:save-buffer c)
    (check-equal? '("restored gamma\n" #f) (list (files-test:read-text "~/c.txt") (buffers:modified? c)))))

(define (slow-read read path)
  (let-values ([(doc length hash) (read path)])
    (timers:sleep 0.02)
    (values doc length hash)))

(test "visits of one file at once keep their reads apart while the advice pauses, so the buffer does not start modified"
  (advice-add! files:read-document slow-read)
  (files-test:write-text! "~/eps.txt" "epsilon\n")
  (let ([eps (map test-runner:join (map (lambda (i) (spawn-task (lambda (restore) (files:visit "~/eps.txt")))) '(1 2)))])
    (advice-remove! files:read-document slow-read)
    (check-equal? '(#t #f) (list (eq? (car eps) (cadr eps)) (buffers:modified? (car eps))))
    (buffers:kill! (car eps))))

(define seen #f)

(define (slow-entry buffer) (timers:sleep 0.05) (set! seen (buffers:name buffer)))

(test "an after-visit entry may pause, and the visit returns after it"
  (hooks:add! files:after-visit slow-entry)
  (files-test:write-text! "~/d.txt" "delta\n")
  (check-equal? '("d.txt" "d.txt") (list (buffers:name (files:visit "~/d.txt")) seen))
  (hooks:remove! files:after-visit slow-entry))
