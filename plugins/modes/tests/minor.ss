(import (tuna) (test) (modes) (prog) (buffers) (views) (layout) (keys) (commands) (hooks) (options) (tables) (test-user)
        (buffers-test) (modes-test) (modes-test text) (modes-test fill) (modes-test code) (modes-test view))

(define (view) (layout:selected-view))

(define (minor-named name)
  (find (lambda (m) (eq? name (modes:name m))) (map car (tables:entries modes:minor-modes))))

(test "an option mode is an option, off by default, with its documentation, recorded at depth 0 with its lighter, keymap and name"
  (check (options:option? modes-test/fill:mode))
  (check-equal? #f (modes-test/fill:mode))
  (check-equal? #f (options:default modes-test/fill:mode))
  (check-equal? "Whether typing past fill:column breaks the line." (options:documentation modes-test/fill:mode))
  (check-equal? 0 (tables:ref modes:minor-modes modes-test/fill:mode #f))
  (check-equal? "Fill" (tables:ref modes:lighters modes-test/fill:mode #f))
  (check (eq? modes-test/fill:keymap (tables:ref modes:keymaps modes-test/fill:mode #f)))
  (check-equal? #f (tables:ref modes:minor-mode-majors modes-test/fill:mode #f))
  (check-equal? 'modes-test/fill:mode (modes:name modes-test/fill:mode)))

(test "an option mode takes #t and #f only"
  (check-raises (buffers-test:raised? 'options:set! "always is not a valid value for modes-test/fill:mode")
                (options:set! modes-test/fill:mode 'always))
  (check-equal? #f (modes-test/fill:mode)))

(define changes '())

(modes:define-minor-mode mine "Whether mine is on." (default #t) (on-change (lambda (on?) (set! changes (cons on? changes)))))

(test "an option mode takes a default and an on-change, as options:define-option does; the name is prefixed with the defining owner"
  (check-equal? '(#t #t) (list (mine) (options:default mine)))
  (options:set! mine #f)
  (check-equal? '(#f) changes)
  (check-equal? 'test-file/modes/minor:mine (modes:name mine))
  (options:unset! mine))

(test "a state mode is a procedure of no arguments with its documentation, not an option, recorded with its lighter and name"
  (let ([b (buffers:make "viewed" "x")])
    (check-equal? '(#t #f) (list (procedure? modes-test/view:mode) (options:option? modes-test/view:mode)))
    (check-equal? "Whether the current buffer is viewed, not edited." (definition-documentation modes-test/view:mode))
    (check-equal? #f (buffers:with-buffer b (modes-test/view:mode)))
    (modes-test/view:set-viewing! b #t)
    (check-equal? #t (buffers:with-buffer b (modes-test/view:mode)))
    (check-equal? '(0 "View" modes-test/view:mode)
                  (list (tables:ref modes:minor-modes modes-test/view:mode #f) (modes:lighter modes-test/view:mode)
                        (modes:name modes-test/view:mode)))))

(define (bad-form-raises module message)
  (check-raises (lambda (c) (and (who-condition? c) (eq? 'modes:define-minor-mode (condition-who c))
                                 (string=? message (condition-message c))))
                (load-module! (list 'modes-test 'bad module))))

(test "a malformed modes:define-minor-mode is a syntax error naming the form"
  (for-each
    (lambda (module message)
      (check-raises (lambda (c) (and (syntax-violation? c) (string=? message (condition-message c))))
                    (load-module! (list 'modes-test 'bad module))))
    '(minor-no-doc minor-string-id minor-unknown minor-twice minor-malformed minor-state-default minor-state-on-change
      minor-state-formals minor-state-malformed minor-majors-empty minor-majors-dotted)
    '("expected (modes:define-minor-mode id doc-string clause ...)" "expected (modes:define-minor-mode id doc-string clause ...)"
      "invalid clause" "clause given twice" "invalid clause" "a state mode has no default or on-change clause"
      "a state mode has no default or on-change clause" "a state mode's formals must allow no arguments" "invalid clause"
      "invalid clause" "invalid clause")))

(test "a minor mode's lighter, keymap, depth and major modes are checked as it is defined, naming the form, and nothing is recorded"
  (for-each bad-form-raises '(minor-lighter minor-keymap minor-depth minor-majors)
            '("not a string" "not a keymap" "not a real number" "not a mode"))
  (check-equal? #f (minor-named 'modes-test/bad/minor-lighter:bad)))

(test "a minor mode defined again without a lighter, keymap or majors clause keeps none of the ones it had"
  (modes-test:write-module! "again"
    "#!tuna\n(import (modes) (prog) (tables))\n(tables:define-table keymap \"Keys.\")\n(modes:define-minor-mode mode \"Whether again is on.\" (lighter \"Again\") (keymap keymap) (majors prog:mode))\n")
  (load-module! '(again))
  (let ([first (minor-named 'again:mode)])
    (check-equal? "Again" (modes:lighter first))
    (check (tables:table? (tables:ref modes:keymaps first #f)))
    (check-equal? (list prog:mode) (tables:ref modes:minor-mode-majors first #f)))
  (modes-test:write-module! "again" "#!tuna\n(import (modes))\n(modes:define-minor-mode mode \"Whether again is on.\")\n")
  (reload-modules! '((again)))
  (let ([second (minor-named 'again:mode)])
    (check-equal? '(#f #f #f)
                  (list (modes:lighter second) (tables:ref modes:keymaps second #f) (tables:ref modes:minor-mode-majors second #f))))
  (unload-owner! (module-owner '(again))))

(test "unloading the defining module takes its mode's entries away, and its name"
  (modes-test:write-module! "gone" "#!tuna\n(import (modes))\n(modes:define-minor-mode mode \"Whether gone is on.\" (lighter \"Gone\"))\n")
  (load-module! '(gone))
  (let ([mode (minor-named 'gone:mode)])
    (unload-owner! (module-owner '(gone)))
    (check-equal? '(#f #f #f)
                  (list (tables:ref modes:minor-modes mode #f) (modes:lighter mode) (modes:name mode)))))

(test "modes:name gives a major mode's own name, a minor mode's recorded one, and #f for anything else, a bare procedure in modes:minor-modes included"
  (let ([plain (lambda () #t)])
    (tables:set! modes:minor-modes plain 0)
    (check-equal? (list modes-test/code:mode 'modes-test/fill:mode #f #f #f)
                  (map modes:name (list modes-test/code:mode modes-test/fill:mode plain car 'nothing:mode)))
    (tables:remove! modes:minor-modes plain)))

(define (show-buffer! name)
  (let ([b (buffers:make (buffers:free-name name) "f(x)\n")])
    (modes:set-major-mode modes-test/code:mode b)
    (views:set-buffer! (view) b)
    b))

(define (in-view thunk) (views:call-with-view (view) thunk))

(define (keymap-names keymaps names)
  (map (lambda (k) (let ([found (assq k names)]) (if found (cdr found) 'other))) keymaps))

(options:define-option one #f boolean?)
(options:define-option two #f boolean?)
(options:define-option three #f boolean?)
(tables:define-table one-keymap)
(tables:define-table two-keymap)
(tables:define-table three-keymap)

(define names
  (list (cons one-keymap 'one) (cons two-keymap 'two) (cons three-keymap 'three) (cons modes-test/fill:keymap 'fill)
        (cons modes-test/code:keymap 'code) (cons prog:keymap 'prog) (cons layout:keymap 'layout) (cons keys:global 'global)))

(test "the modes' keymaps: minor modes on by depth, then in the order their keys were first set; then the major mode's ancestry, innermost first"
  (let ([b (show-buffer! "keyed")])
    (tables:set! modes:minor-modes one 0)
    (tables:set! modes:minor-modes two -5)
    (tables:set! modes:minor-modes three 0)
    (tables:set! modes:keymaps one one-keymap)
    (tables:set! modes:keymaps two two-keymap)
    (tables:set! modes:keymaps three three-keymap)
    (options:set! one #t three #t modes-test/fill:mode #t)
    (check-equal? '(fill one three code prog) (keymap-names (in-view (lambda () (modes:active-keymaps (test-user:client) #f))) names))
    (buffers:with-buffer b (options:set-local! two #t three #f))
    (check-equal? '(two fill one code prog) (keymap-names (in-view (lambda () (modes:active-keymaps (test-user:client) #f))) names))
    (views:set-option! (view) three #t)
    (check-equal? '(two fill one three code prog) (keymap-names (in-view (lambda () (modes:active-keymaps (test-user:client) #f))) names))
    (check-equal? (list two modes-test/fill:mode one three) (remp (lambda (m) (not (memq m (list one two three modes-test/fill:mode))))
                                                                  (modes:active-minor-modes (view))))
    (views:remove-option! (view) three)
    (options:set! one #f three #f modes-test/fill:mode #f)))

(test "the modes' keymaps come after those at the cursor and before the layout's containers'"
  (show-buffer! "between")
  (options:set! modes-test/fill:mode #t)
  (let ([found (keymap-names (in-view (lambda () (keys:active-keymaps (test-user:client)))) names)])
    (check-equal? '(fill code prog layout global) (remq 'other found)))
  (options:set! modes-test/fill:mode #f))

(test "a minor mode with no keymap gives none, and any procedure in modes:minor-modes is a minor mode"
  (let ([always (lambda () #t)])
    (show-buffer! "plain")
    (tables:set! modes:minor-modes always 10)
    (check (memq always (modes:active-minor-modes (view))))
    (check-equal? '(code prog) (keymap-names (in-view (lambda () (modes:active-keymaps (test-user:client) #f))) names))
    (tables:remove! modes:minor-modes always)))

(test "minor modes are read in the view: a view's own value applies in that view only, at once inside it"
  (let* ([b (show-buffer! "two views")] [other (views:make b)])
    (tables:set! modes:minor-modes one 0)
    (views:set-option! other one #t)
    (check-equal? '(#f #t) (list (and (memq one (modes:active-minor-modes (view))) #t) (and (memq one (modes:active-minor-modes other)) #t)))
    (check-equal? #t (in-view (lambda () (views:set-option! (view) one #t) (and (memq one (modes:active-minor-modes (view))) #t))))
    (views:remove-option! (view) one)
    (views:drop! other)))

(test "a minor mode that raises, or a depth that is not a real number, is reported and skipped; the other modes and keymaps stay"
  (let ([broken (lambda () #t)] [raising (lambda () (error 'raising "broken minor mode"))] [on #f] [keymaps #f])
    (show-buffer! "broken")
    (tables:set! modes:minor-modes broken 'high)
    (tables:set! modes:minor-modes raising 0)
    (options:set! modes-test/fill:mode #t)
    (check-equal? '(("modes:minor-modes" "not a real number") ("raising" "broken minor mode")
                    ("modes:minor-modes" "not a real number") ("raising" "broken minor mode"))
                  (map (lambda (c) (list (symbol->string (condition-who c)) (condition-message c)))
                       (buffers-test:reports-during
                         (lambda ()
                           (set! on (modes:active-minor-modes (view)))
                           (set! keymaps (in-view (lambda () (modes:active-keymaps (test-user:client) #f))))))))
    (check (memq modes-test/fill:mode on))
    (check-equal? '(#f #f) (list (memq broken on) (memq raising on)))
    (check-equal? '(fill code prog) (keymap-names keymaps names))
    (tables:remove! modes:minor-modes broken)
    (tables:remove! modes:minor-modes raising)
    (options:set! modes-test/fill:mode #f)))

(commands:define-command (anywhere) "Runs anywhere." (void))
(commands:define-command (in-code) "Runs in code buffers." (void))
(commands:define-command (in-one) "Runs in text or while one is on." (void))
(commands:define-command (nowhere) "Runs nowhere." (void))

(test "a command is for a view when nothing marks it or a mode it is marked for is on there; marked for no mode, for no view"
  (show-buffer! "commands")
  (tables:set! modes:minor-modes one 0)
  (tables:set! commands:command-modes in-code (list modes-test/code:mode))
  (tables:set! commands:command-modes in-one (list modes-test/text:mode one))
  (tables:set! commands:command-modes nowhere '())
  (let ([for-view (lambda () (map (lambda (c) (modes:command-for-view? c (view))) (list anywhere in-code in-one nowhere)))])
    (check-equal? '(#t #t #f #f) (for-view))
    (views:set-option! (view) one #t)
    (check-equal? '(#t #t #t #f) (for-view))
    (views:remove-option! (view) one))
  (check-raises (buffers-test:raised? 'modes:command-for-view? "not a command") (modes:command-for-view? 'anywhere (view)))
  (check-raises (buffers-test:raised? 'modes:command-for-view? "not a view")
                (modes:command-for-view? anywhere (views:buffer (view)))))

(test "modes:on? is true for a major mode the view's buffer derives from, or a minor mode on in the view"
  (show-buffer! "on")
  (check-equal? '(#t #t #f #f)
                (map (lambda (m) (modes:on? m (view))) (list modes-test/code:mode prog:mode modes-test/text:mode modes-test/fill:mode)))
  (views:set-option! (view) modes-test/fill:mode #t)
  (check-equal? #t (modes:on? modes-test/fill:mode (view)))
  (views:remove-option! (view) modes-test/fill:mode)
  (check-raises (buffers-test:raised? 'modes:on? "not a mode") (modes:on? "code" (view)))
  (check-raises (buffers-test:raised? 'modes:on? "not a view") (modes:on? prog:mode 5)))

(tables:define-table click-keymap)

(buffers:define-kind clickable (content atom) (keymap click-keymap))

(define clicked '())

(commands:define-command (on-kind) "Notes a click on the atom." (set! clicked (cons 'kind clicked)))

(commands:define-command (on-text) "Notes a click in text mode." (set! clicked (cons 'mode clicked)))

(test "a mouse key looks in the view of its position, after the keymaps there"
  (let ([clicks (buffers:make "clicks" (list 'buffers:text '() "ab" (clickable '()) "cd"))])
    (modes:set-major-mode modes-test/text:mode clicks)
    (views:set-buffer! (view) clicks)
    (test-user:settle)
    (keys:bind! click-keymap "<mouse-1>" on-kind)
    (keys:bind! modes-test/text:keymap "<mouse-1>" on-text)
    (test-user:click! (view) 3)
    (test-user:click! (view) 1)
    (check-equal? '(kind mode) (reverse clicked))
    (keys:unbind! modes-test/text:keymap "<mouse-1>")))

(test "taken out of keys:find-keymaps, the modes' keymaps are gone; they come back when the removal goes with its owner"
  (show-buffer! "removed")
  (let ([remover (make-owner '(remover))] [found (lambda () (remq 'other (keymap-names (in-view (lambda () (keys:active-keymaps (test-user:client)))) names)))])
    (call-as-owner remover (lambda () (hooks:remove! keys:find-keymaps modes:active-keymaps)))
    (check-equal? '(layout global) (found))
    (unload-owner! remover)
    (check-equal? '(code prog layout global) (found))))
