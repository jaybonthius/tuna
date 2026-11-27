(import (tuna) (test) (test-user) (layout) (views) (buffers) (document))

(define (raised-by who)
  (lambda (e) (and (who-condition? e) (eq? who (condition-who e)))))

(test "show! puts the text in a new buffer in the selected view, point at the mark, and text reads it back"
  (test-user:show! "one\nt|wo")
  (let ([first (views:buffer (layout:selected-view))])
    (check-equal? "one\ntwo" (document:text (buffers:document first)))
    (check-equal? "one\nt|wo" (test-user:text))
    (test-user:show! "|")
    (check (not (eq? first (views:buffer (layout:selected-view)))))
    (check (buffers:live? first))
    (check-equal? "|" (test-user:text))))

(test "another character can mark point, so the text can hold a |"
  (test-user:show! "a|b^c" #\^)
  (check-equal? "a|b^c" (test-user:text #\^))
  (check-equal? "a|b|c" (test-user:text)))

(test "show! takes text with exactly one point mark"
  (check-raises (raised-by 'test-user:show!) (test-user:show! "none"))
  (check-raises (raised-by 'test-user:show!) (test-user:show! "t|w|o"))
  (check-raises (raised-by 'test-user:show!) (test-user:show! 'one))
  (check-raises (raised-by 'test-user:show!) (test-user:show! "o|ne" "|"))
  (check-raises (raised-by 'test-user:text) (test-user:text "|")))
