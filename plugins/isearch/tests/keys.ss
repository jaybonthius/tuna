(import (tuna) (test) (test-user) (keys) (views) (editing) (search) (isearch) (isearch-test))

(define here isearch-test:here)

(define (reset!) (views:set-point! (isearch-test:view) 1))

(define b (isearch-test:show! "k" "foo bar foo baz\n"))

(test "C-g in a failing search goes back to the last state that matched; in a successful one it cancels, point back at the origin"
  (test-user:press! "C-s f o o x y")
  (check-equal? '(4 "Failing I-search: foo{xy}" "foo") (here))
  (test-user:press! "C-g")
  (check-equal? '(4 "I-search: foo" "foo") (here))
  (check (isearch-test:cancelling! "C-g"))
  (check-equal? '(1 #f #f) (here)))

(test "ESC cancels at once"
  (test-user:press! "C-s b a")
  (check-equal? '(7 "I-search: ba" "ba") (here))
  (check (isearch-test:cancelling! "ESC"))
  (check-equal? '(1 #f #f) (here)))

(test "a key isearch:keymap does not bind ends the search at the match and then runs"
  (test-user:press! "C-s b a z C-f")
  (check-equal? '(17 #f #f) (here))
  (reset!))

(test "a key the user binds in isearch:keymap keeps the search"
  (keys:bind! isearch:keymap "C-v" editing:forward-char)
  (test-user:press! "C-s f o C-v")
  (check-equal? '(4 "I-search: fo" "fo") (here))
  (test-user:press! "o")
  (check-equal? '(4 "I-search: foo" "foo") (here))
  (test-user:press! "RET")
  (keys:unbind! isearch:keymap "C-v")
  (reset!))

(test "a key that ends the search runs at the new match"
  (test-user:press! "C-s b a r C-f")
  (check-equal? '(9 #f #f) (here))
  (reset!))

(define finds 0)

(define (count-find find . args) (set! finds (+ finds 1)) (apply find args))

(test "adding to a failing literal search reads no text: the added part shows in isearch.fail and DEL takes it back"
  (advice-add! search:find count-find)
  (test-user:press! "C-s q")
  (check-equal? '(1 "Failing I-search: {q}" #f) (here))
  (set! finds 0)
  (test-user:press! "x y")
  (check-equal? (list 0 '(1 "Failing I-search: {qxy}" #f)) (list finds (here)))
  (test-user:press! "DEL DEL")
  (check-equal? '(1 "Failing I-search: {q}" #f) (here))
  (check (isearch-test:cancelling! "C-g C-g"))
  (test-user:press! "M-s w q x")
  (check-equal? (list 1 '(1 "Failing word I-search: {qx}" #f)) (list finds (here)))
  (check (isearch-test:cancelling! "C-g C-g"))
  (advice-remove! search:find count-find))

(test "a regexp searches again at each key, so one an unfinished pattern failed matches once it is closed"
  (advice-add! search:find count-find)
  (set! finds 0)
  (test-user:press! "C-M-s ( f o )")
  (check (positive? finds))
  (check-equal? '(3 "Regexp I-search: (fo)" "fo") (here))
  (test-user:press! "RET")
  (advice-remove! search:find count-find)
  (reset!))

(test "the search moves the primary cursor only"
  (views:add-cursor! (isearch-test:view) 12)
  (test-user:press! "C-s b a z RET")
  (check-equal? '(16 12) (map views:cursor-point (views:cursors (isearch-test:view))))
  (views:remove-cursor! (isearch-test:view) (cadr (views:cursors (isearch-test:view))))
  (reset!))
