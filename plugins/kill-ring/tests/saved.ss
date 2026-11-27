(import (tuna) (test) (test-runner) (hooks) (options) (document) (buffers) (kill-ring))

(define saved-file (string-append (getenv "HOME") "/.local/share/tuna/saved/tuna/kill-ring/texts.ss"))

(define (saved-texts) (and (file-exists? saved-file) (call-with-input-file saved-file read)))

(define (ring-texts)
  (map (lambda (entry) (map (lambda (kill) (kill-ring:text (list kill))) entry)) (kill-ring:entries)))

(define (kill-ring-advice-on-batch-ended)
  (let ([owner (module-owner '(kill-ring))])
    (filter (lambda (c) (eq? (car c) owner)) (definition-changes batch-ended))))

(buffers:define-layer responses (travels) (sticky after))

(define long-a (make-string 4096 #\a))

(define saved-ring (list '("newest") '("one" "Hello") (list long-a)))

(define b (buffers:make "b" "Hello world\n"))

(buffers:add-span! (buffers:layer b responses) 1 6 'gpt)

(define one #f)

(test "the ring's text is saved after the batch that changed it: a kill as its text, but neither an entry with a kill over 4,096 characters nor the yank pointer"
  (kill-ring:push! (list long-a))
  (kill-ring:push! (list "small" (make-string 4097 #\b)))
  (kill-ring:push! (list "one" (buffers:piece b 1 6)))
  (kill-ring:push! (list "newest"))
  (set! one (kill-ring:rotate! 1))
  (check-equal? "one\nHello" (kill-ring:text one))
  (test-runner:wait-until (lambda () (equal? saved-ring (saved-texts))))
  (check-equal? saved-ring (saved-texts)))

(test "a reload keeps the ring's text, other owners' settings and hook entries, and kills made before it"
  (let* ([pushed '()] [note (lambda (entry) (set! pushed (cons (kill-ring:text entry) pushed)))])
    (options:set! kill-ring:skip-duplicates #t)
    (hooks:add! kill-ring:after-push note)
    (reload-modules! '((kill-ring)))
    (check-equal? saved-ring (ring-texts))
    (check-equal? '("newest") (kill-ring:current))
    (check (kill-ring:skip-duplicates))
    (kill-ring:push! (list "after"))
    (check-equal? '("after") pushed)
    (hooks:remove! kill-ring:after-push note)
    (options:unset! kill-ring:skip-duplicates))
  (check-equal? '((12 . 17)) (kill-ring:insert! b 12 (cadr one)))
  (check-equal? '("Hello" "Hello")
    (map (lambda (s) (document:text (buffers:document b) (car s) (cadr s)))
         (buffers:spans (buffers:layer b responses) 0 (document:length (buffers:document b)))))
  (check-equal? 1 (length (kill-ring-advice-on-batch-ended))))

(test "unloading saves a change made in the same batch and takes back the advice that saves; loading again reads the saved ring"
  (let ([old (module-owner '(kill-ring))])
    (kill-ring:push! (list "last"))
    (unload-owner! old)
    (check (not (owner-live? old)))
    (check (not (exists (lambda (c) (eq? (car c) old)) (definition-changes batch-ended))))
    (test-runner:wait-until (lambda () (equal? '("last") (car (saved-texts)))))
    (load-module! '(kill-ring))
    (check-equal? '("last") (kill-ring:current))
    (check-equal? (saved-texts) (ring-texts))
    (check-equal? 1 (length (kill-ring-advice-on-batch-ended)))))
