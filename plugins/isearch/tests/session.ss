(import (tuna) (test) (test-user) (hooks) (options) (keys) (layout) (layout-split) (views) (web) (search) (isearch) (isearch-test))

(define here isearch-test:here)

(define with-setting isearch-test:with-setting)

(define (at! p) (views:set-point! (isearch-test:view) p))

(test "isearch:started, isearch:updated and isearch:ended are called with the search; ended after its keymap and highlights are gone"
  (let* ([events '()]
         [note! (lambda e (set! events (cons e events)))]
         [started (lambda (s) (note! 'started (isearch:search-direction s)))]
         [updated (lambda (s) (note! 'updated))]
         [ended (lambda (s cancelled?) (note! 'ended cancelled? (keys:prompt (test-user:client))))])
    (hooks:add! isearch:started started)
    (hooks:add! isearch:updated updated)
    (hooks:add! isearch:ended ended)
    (isearch-test:show! "s" "alpha beta gamma beta\n")
    (test-user:press! "C-s b e")
    (check-equal? '("I-search: " (#f . "be")) (isearch:prompt (isearch:current (test-user:client))))
    (test-user:press! "RET")
    (check-equal? '((started forward) (ended #f #f)) (filter (lambda (e) (not (equal? e '(updated)))) (reverse events)))
    (check (member '(updated) events))
    (set! events '())
    (check (isearch-test:cancelling! "C-r b C-g"))
    (check-equal? '(ended #t #f) (car events))
    (hooks:remove! isearch:started started)
    (hooks:remove! isearch:updated updated)
    (hooks:remove! isearch:ended ended)))

(test "advice on isearch:prompt changes the prompt"
  (let ([shout (lambda (prompt s) (cons "Look: " (cdr (prompt s))))])
    (isearch-test:show! "s" "alpha beta gamma beta\n")
    (advice-add! isearch:prompt shout)
    (test-user:press! "C-s b e")
    (check-equal? '("Look: " (#f . "be")) (keys:prompt (test-user:client)))
    (test-user:press! "RET")
    (advice-remove! isearch:prompt shout)))

(test "the search's accessors"
  (let ([b (isearch-test:show! "s" "alpha beta gamma beta\n")])
    (test-user:press! "C-s b e")
    (let ([s (isearch:current (test-user:client))])
      (check (isearch:search? s))
      (check-equal? (list (isearch-test:view) (test-user:client) 1 (search:direction forward) "be" 7 9)
                    (list (isearch:search-view s) (isearch:search-client s) (isearch:search-origin s) (isearch:search-direction s)
                          (search:query-text (isearch:search-query s))
                          (search:match-start (isearch:search-match s)) (search:match-end (isearch:search-match s))))
      (check (search:scan? (isearch:search-scan s))))
    (test-user:press! "RET")))

(test "another client's search runs apart: each client has its own keymap and search"
  (let ([other (test-user:open-client)] [b (isearch-test:show! "s" "alpha beta gamma beta\n")] [first (isearch-test:view)])
    (layout-split:split-below #f)
    (let ([second (find (lambda (v) (not (eq? v first))) (layout:views))])
      (views:set-point! second 1)
      (layout:select! second)
      (test-user:press! other "C-s g")
      (layout:select! first)
      (test-user:press! "C-s b")
      (check-equal? (list second 8 13) (list (isearch:search-view (isearch:current other)) (views:point first) (views:point second)))
      (check-equal? '("I-search: " (#f . "g")) (keys:prompt other))
      (check-equal? '("I-search: " (#f . "b")) (keys:prompt (test-user:client)))
      (test-user:press! "RET")
      (test-user:press! other "RET")
      (check-equal? #f (isearch:current other))
      (layout:select! second)
      (test-user:press! "C-x 0")
      (web:close-client! other))))

(test "isearch:start! starts a search for code with a query and a client; isearch:end! ends it"
  (isearch-test:show! "s" "alpha beta gamma beta\n")
  (let ([s (isearch:start! (isearch-test:view) (test-user:client) (search:make-query "gamma" search:literal (search:case exact)) (search:direction forward))])
    (test-user:settle)
    (check-equal? '(1 17 ("I-search: " (#f . "gamma")))
                  (list (isearch:search-origin s) (isearch-test:point) (keys:prompt (test-user:client))))
    (isearch:end! s)
    (test-user:settle)
    (check-equal? '(#f #f) (list (isearch:current (test-user:client)) (keys:prompt (test-user:client))))))

(test "isearch:start! keeps the query's own filter"
  (isearch-test:show! "fl" "ab ab ab\n")
  (isearch:start! (isearch-test:view) (test-user:client)
                  (search:make-query "ab" search:literal (search:case smart) (search:spaces literal) (lambda (b start end) (> start 2)))
                  (search:direction forward))
  (test-user:settle)
  (check-equal? '(6 "I-search: ab" "ab") (here))
  (test-user:press! "C-s")
  (check-equal? '(9 "I-search: ab" "ab") (here))
  (test-user:press! "RET"))

(test "a backward symbol search started from code finds whole symbols only"
  (isearch-test:show! "fb" "foo foobar\n")
  (at! 9)
  (isearch:start! (isearch-test:view) (test-user:client) (search:make-query "foo" search:symbol) (search:direction backward))
  (test-user:settle)
  (check-equal? '(1 "Symbol I-search backward: foo" "foo") (here))
  (test-user:press! "RET"))

(test "isearch:wrap immediately wraps at once; never stops at the last match"
  (isearch-test:show! "sy" "(foo-bar x) foo-bar foo-barz foo-bar\n")
  (with-setting isearch:wrap 'immediately
    (lambda ()
      (at! 30)
      (test-user:press! "C-s f o o - b a r C-s")
      (check-equal? '(9 "Wrapped I-search: foo-bar" "foo-bar") (here))
      (test-user:press! "RET")))
  (with-setting isearch:wrap 'never
    (lambda ()
      (at! 30)
      (test-user:press! "C-s f o o - b a r C-s C-s")
      (check-equal? '(37 "Failing I-search: foo-bar" "foo-bar") (here))
      (check (isearch-test:cancelling! "C-g C-g")))))

(test "with repeat-on-direction-change on, turning around goes to another match"
  (isearch-test:show! "sy" "(foo-bar x) foo-bar foo-barz foo-bar\n")
  (with-setting isearch:repeat-on-direction-change #t
    (lambda ()
      (test-user:press! "C-s f o o C-s C-r")
      (check-equal? '(2 "I-search backward: foo" "foo") (here))
      (test-user:press! "RET"))))

(test "isearch:default-style is the style C-s starts in"
  (isearch-test:show! "d" "a.c abc\n")
  (with-setting isearch:default-style search:regexp
    (lambda ()
      (test-user:press! "C-s a . c C-s")
      (check-equal? '(8 "Regexp I-search: a.c" "abc") (here))
      (test-user:press! "RET"))))

(test "a quit during a long find fails the state it was making, and C-g then goes back to the last state that matched"
  (isearch-test:show! "qb" "abc abd abe\n")
  (let ([quitting (lambda (find . args) (raise (make-cancelled #f)))])
    (test-user:press! "C-s a b")
    (advice-add! search:find quitting)
    (test-user:press! "d")
    (advice-remove! search:find quitting)
    (check-equal? '(3 "Failing I-search: ab{d}" "ab") (here))
    (test-user:press! "C-g")
    (check-equal? '(3 "I-search: ab" "ab") (here))
    (test-user:press! "RET")))

(test "a client closed mid-search ends its search at its match"
  (let ([third (test-user:open-client)])
    (isearch-test:show! "rc" "foo\n")
    (test-user:press! third "C-s f")
    (check (isearch:current third))
    (web:close-client! third)
    (test-user:settle)
    (check-equal? '(#f 2) (list (isearch:current third) (isearch-test:point)))))

(test "unloading isearch ends every search"
  (isearch-test:show! "u" "foo\n")
  (test-user:press! "C-s f o")
  (unload-owner! (module-owner '(isearch)))
  (test-user:settle)
  (check-equal? #f (keys:prompt (test-user:client))))
