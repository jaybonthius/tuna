(import (tuna) (test) (test-user) (web) (tables) (commands) (keys) (keys-test))

(define got '())

(define (take-got!) (let ([g (reverse got)]) (set! got '()) g))

(commands:define-command (read-one)
  "Records the next key, or quit when the read is cancelled."
  (set! got (cons (guard (c [(cancelled? c) 'quit]) (keys:read-key)) got)))

(commands:define-command (visit)
  "Records its prefix argument."
  (set! got (cons (list 'visit (commands:prefix-argument)) got)))

(keys:bind! keys:global "C-c k" read-one)
(keys:bind! keys:global "C-x C-f" visit)

(test "reloading the plugin raises &cancelled in every read; a read already handed its key returns it first"
  (let ([one (test-user:open-client)] [two (test-user:open-client)])
    ;; Each read runs in a task of the test's own: an item's task runs as
    ;; the owner of web's input handler, which the reload unloads too.
    (for-each (lambda (c) (spawn-task (lambda (restore) (keys:press! c "C-c") (keys:press! c "k")))) (list one two))
    (test-user:settle)
    (keys:press! two "f")
    (reload-modules! '((keys)))
    (test-user:settle)
    (check-equal? '("f" quit) (take-got!))
    (check-equal? '(#f #f) (list (keys:reading one) (keys:reading two)))))

(test "reloading the plugin ends every temporary keymap and every client's pending keys, and keeps the bindings of every owner"
  (tables:define-table reloaded-temporary "reloaded")
  (let* ([client (test-user:client)] [exits 0]
         [end (keys:push-keymap! client reloaded-temporary (lambda (f c) #t) (lambda () (set! exits (+ exits 1))))])
    (test-user:press! client "C-x")
    (reload-modules! '((keys)))
    (let ([client (test-user:client)])
      (check-equal? 1 exits)
      (check-equal? #f (keys:pending client))
      (check (not (memq reloaded-temporary (keys:active-keymaps client))))
      (check-equal? (list read-one keys:keyboard-quit keys:digit-argument)
                    (map (lambda (k) (keys:lookup client k)) '("C-c k" "C-g" "M-5")))
      (check (commands:command? (keys:lookup client "C-x o")))
      (test-user:press! client "C-u C-x C-f")
      (check-equal? '((visit (4))) (take-got!))
      (test-user:press! client "C-c k g")
      (check-equal? '("g") (take-got!))
      (end)
      (check-equal? 1 exits))))
