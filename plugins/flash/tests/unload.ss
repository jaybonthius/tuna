(import (tuna) (test) (test-user) (test-runner) (views) (buffers) (keys) (tables) (commands) (search) (flash))

;; This file opens its own client: a client a test library opened would
;; close as the library, which imports flash, unloads before it.
(define (answer name value)
  (let ([v (and (equal? name "views-shown") (views:find (cdr (assoc "view" value))))])
    (if v
        (let-values ([(lo hi) (views:bounds v)])
          (list (cons "version" (buffers:version (views:buffer v))) (cons "start" (list (cons "at" lo)))
                (cons "end" (list (cons "at" hi)))))
        'null)))

(define user (test-user:open-client answer))

(define outcome #f)

(commands:define-command (read-and-keep)
  "Reads a match and keeps what came of it."
  (set! outcome 'waiting)
  (set! outcome (guard (c [(unloaded? c) 'unloaded] [(cancelled? c) 'cancelled]) (flash:read-match))))

(keys:bind! keys:global "C-c r" read-and-keep)

(test "unloading flash ends every jump: no mark or keymap of it remains, and a waiting read raises &unloaded"
  (let ([sources (length (tables:entries views:span-sources))] [other (test-user:open-client answer)])
    (keys:bind! keys:global "C-c ;" flash:jump)
    (test-user:show! "foo fob for\nbar |foo\nfox\nFoo\n")
    (test-user:press! user "C-c r f o")
    (test-user:press! other "C-c ; f")
    (check-equal? (+ sources 6) (length (tables:entries views:span-sources)))
    ;; The jump the other client started was flash:jump's own, which the
    ;; unload ends with &unloaded, as it does any command in its code.
    (check-equal? '(#t)
                  (map unloaded?
                       (test-runner:reports-during (lambda () (unload-owner! (module-owner '(flash))) (test-user:settle)))))
    (check-equal? 'unloaded outcome)
    (check-equal? (list #f #f) (list (keys:prompt user) (keys:prompt other)))
    (check-equal? sources (length (tables:entries views:span-sources)))
    (check-equal? '() (test-user:elements-with (test-user:screen user) "data-flash-label"))))
