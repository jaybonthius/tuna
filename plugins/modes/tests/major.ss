(import (tuna) (test) (modes) (prog) (buffers) (views) (layout) (keys) (hooks) (options) (tables) (test-user) (buffers-test) (modes-test)
        (modes-test text) (modes-test fill) (modes-test code))

(define (local option b) (buffers:with-buffer b (option)))

(define (view) (layout:selected-view))

(test "a buffer has modes:fundamental until its mode is set; modes:fundamental has no parent, its own keymap and hook, and the lighter Fundamental"
  (let ([b (buffers:make "fresh" "one two")])
    (check-equal? modes:fundamental (modes:major-mode b))
    (check-equal? '(modes:fundamental) (modes:ancestry modes:fundamental))
    (check-equal? "Fundamental" (modes:lighter modes:fundamental))
    (check (eq? modes:fundamental-keymap (tables:ref modes:keymaps modes:fundamental #f)))
    (check (eq? modes:fundamental-hook (tables:ref modes:hooks modes:fundamental #f)))))

(test "modes:special has no parent, the lighter Special, and binds g, scrolling, digits and - in its keymap"
  (check-equal? '(modes:special) (modes:ancestry modes:special))
  (check-equal? "Special" (modes:lighter modes:special))
  (check (eq? modes:special-keymap (tables:ref modes:keymaps modes:special #f)))
  (check (eq? modes:special-hook (tables:ref modes:hooks modes:special #f)))
  (check-equal? (list buffers:revert-buffer views:scroll-up views:scroll-down views:scroll-down keys:negative-argument
                      keys:digit-argument keys:digit-argument)
                (map (lambda (key) (tables:ref modes:special-keymap key #f)) '("g" "SPC" "S-SPC" "DEL" "-" "0" "9"))))

(hooks:define-hook probe "A hook given local entries.")

(define (probed) 'probed)

(test "setting a major mode gives the buffer a new scope: local values and local hook entries go, a view's own values stay"
  (let ([b (buffers:make "scoped" "x")])
    (views:set-buffer! (view) b)
    (buffers:with-buffer b
      (options:set-local! modes-test/fill:column 99)
      (hooks:add-local! probe probed))
    (views:set-option! (view) modes-test/fill:mode #t)
    (modes:set-major-mode modes-test/text:mode b)
    (check-equal? modes-test/text:mode (modes:major-mode b))
    (check-equal? 70 (local modes-test/fill:column b))
    (check-equal? '() (buffers:with-buffer b (hooks:entries probe)))
    (check-equal? #t (views:call-with-view (view) modes-test/fill:mode))
    (views:remove-option! (view) modes-test/fill:mode)))

(test "setting the mode a buffer already has resets it too"
  (let ([b (buffers:make "again" "x")])
    (modes:set-major-mode modes-test/text:mode b)
    (buffers:with-buffer b (options:set-local! modes-test/fill:column 99))
    (modes:set-major-mode modes-test/text:mode b)
    (check-equal? 70 (local modes-test/fill:column b))))

(test "code inside with-buffer of the buffer moves to the new scope"
  (let ([b (buffers:make "inside" "x")])
    (check-equal? '(70 51)
      (buffers:with-buffer b
        (options:set-local! modes-test/fill:column 50)
        (modes:set-major-mode modes-test/text:mode b)
        (let ([after (modes-test/fill:column)])
          (options:set-local! modes-test/fill:column 51)
          (list after (modes-test/fill:column)))))
    (check-equal? 51 (local modes-test/fill:column b))))

(test "the hooks run outermost first with the buffer current; major-mode-changed runs once after them; run-mode-hooks alone does not call it"
  (let* ([b (buffers:make "hooked" "x")]
         [calls '()]
         [note! (lambda (what) (set! calls (cons what calls)))]
         [prog-entry (lambda () (note! (list 'prog (buffers:current) (modes:major-mode (buffers:current)))))]
         [code-entry (lambda () (note! 'code))]
         [changed (lambda (buffer) (note! (list 'changed buffer (eq? buffer (buffers:current)))))])
    (hooks:add! prog:mode-hook prog-entry)
    (hooks:add! modes-test/code:mode-hook code-entry)
    (hooks:add! modes:major-mode-changed changed)
    (modes:set-major-mode modes-test/code:mode b)
    (check-equal? (list (list 'prog b modes-test/code:mode) 'code (list 'changed b #t)) (reverse calls))
    (set! calls '())
    (modes:run-mode-hooks b)
    (check-equal? (list (list 'prog b modes-test/code:mode) 'code) (reverse calls))
    (hooks:remove! prog:mode-hook prog-entry)
    (hooks:remove! modes-test/code:mode-hook code-entry)
    (hooks:remove! modes:major-mode-changed changed)))

(test "local values rank by the order of changes, not by which hook runs first: a later owner's value in the parent's hook wins"
  (let ([b (buffers:make "ranked" "x")]
        [hundred (lambda () (options:set-local! modes-test/fill:column 100))])
    (modes:set-major-mode modes-test/code:mode b)
    (check-equal? 79 (local modes-test/fill:column b))
    (hooks:add! prog:mode-hook hundred)
    (modes:set-major-mode modes-test/code:mode b)
    (check-equal? 100 (local modes-test/fill:column b))
    (hooks:remove! prog:mode-hook hundred)))

(test "the public entries check their arguments"
  (let ([b (buffers:make "checked" "x")] [gone (buffers:make "gone" "x")])
    (buffers:kill! gone)
    (check-raises (buffers-test:raised? 'modes:set-major-mode "not a major mode") (modes:set-major-mode 'nothere:mode b))
    (check-raises (buffers-test:raised? 'modes:set-major-mode "not a live buffer") (modes:set-major-mode modes-test/text:mode "b"))
    (check-raises (buffers-test:raised? 'modes:set-major-mode "not a live buffer") (modes:set-major-mode modes-test/text:mode gone))
    (check-raises (buffers-test:raised? 'modes:run-mode-hooks "not a live buffer") (modes:run-mode-hooks gone))
    (check-raises (buffers-test:raised? 'modes:major-mode "not a buffer") (modes:major-mode 'b))
    (check-raises (buffers-test:raised? 'modes:ancestry "not a mode") (modes:ancestry "python"))
    (check-raises (buffers-test:raised? 'modes:active-minor-modes "not a view") (modes:active-minor-modes b))
    (check-raises (buffers-test:raised? 'modes:derived? "not a mode") (modes:derived? prog:mode 5))))

(test "a malformed hooks entry is no major mode, and the buffer keeps its mode and its local values"
  (let ([b (buffers:make "kept" "x")])
    (modes:set-major-mode modes-test/code:mode b)
    (tables:set! modes:hooks 'odd:mode 5)
    (check-raises (buffers-test:raised? 'modes:set-major-mode "not a major mode") (modes:set-major-mode 'odd:mode b))
    (check-equal? modes-test/code:mode (modes:major-mode b))
    (check-equal? 79 (local modes-test/fill:column b))
    (tables:remove! modes:hooks 'odd:mode)))

(test "a buffer's mode is set and read on the main thread only"
  (let ([b (buffers:make "threaded" "x")])
    (check-equal? '(modes:set-major-mode "not on the main thread")
                  (buffers-test:on-thread (lambda () (modes:set-major-mode modes-test/text:mode b))))
    (check-equal? '(modes:major-mode "not on the main thread") (buffers-test:on-thread (lambda () (modes:major-mode b))))
    (check-equal? '(modes:run-mode-hooks "not on the main thread") (buffers-test:on-thread (lambda () (modes:run-mode-hooks b))))))

(test "ancestry follows parents, innermost first, and stops before a mode already listed"
  (check-equal? (list modes-test/code:mode prog:mode) (modes:ancestry modes-test/code:mode))
  (check-equal? '(nothere:mode) (modes:ancestry 'nothere:mode))
  (check-equal? '(#t #f #t)
                (list (modes:derived? modes-test/code:mode prog:mode) (modes:derived? prog:mode modes-test/code:mode)
                      (modes:derived? modes-test/code:mode modes-test/code:mode)))
  (tables:set! modes:parents prog:mode modes-test/code:mode)
  (check-equal? (list modes-test/code:mode prog:mode) (modes:ancestry modes-test/code:mode))
  (check-equal? (list prog:mode modes-test/code:mode) (modes:ancestry prog:mode))
  (tables:remove! modes:parents prog:mode)
  (check-equal? (list modes-test/code:mode prog:mode) (modes:ancestry modes-test/code:mode)))

(test "a lighter is the table's entry, else a major mode's module part of its name; a minor mode or anything else without one has none"
  (check-equal? '("Text" "Fill" #f #f)
                (map modes:lighter (list modes-test/text:mode modes-test/fill:mode 'nothere:mode 5)))
  (tables:remove! modes:lighters modes-test/text:mode)
  (check-equal? "modes-test/text" (modes:lighter modes-test/text:mode))
  (tables:remove! modes:lighters modes-test/fill:mode)
  (check-equal? #f (modes:lighter modes-test/fill:mode))
  (tables:set! modes:lighters modes-test/text:mode "Prose")
  (check-equal? "Prose" (modes:lighter modes-test/text:mode)))

(test "a configuration's lighter wins over the defining module's, and stays when that module reloads"
  (tables:set! modes:lighters modes-test/code:mode "Cd")
  (reload-modules! '((modes-test code)))
  (check-equal? "Cd" (modes:lighter modes-test/code:mode))
  (tables:remove! modes:lighters modes-test/code:mode))

(tables:define-table child-keymap)

(hooks:define-hook child-hook)

(modes:define-major-mode child (parent modes-test/code:mode) (keymap child-keymap) (hook child-hook))

(test "a mode's language comes from its language clause, read along its ancestry, so a derived mode has its parent's"
  (check-equal? '("code" "code" #f #f) (map modes:language (list modes-test/code:mode child modes-test/text:mode prog:mode)))
  (check-raises (buffers-test:raised? 'modes:language "not a mode") (modes:language "code")))

(test "a configuration's language entry wins over the defining module's"
  (tables:set! modes:languages modes-test/code:mode "ours")
  (check-equal? '("ours" "ours") (map modes:language (list modes-test/code:mode child)))
  (tables:remove! modes:languages modes-test/code:mode))

(test "the clauses of modes:define-major-mode come in any order and are matched as symbols, so (keymap keymap) works"
  (check-equal? (list modes-test/code:mode prog:mode) (modes:ancestry modes-test/code:mode))
  (check (eq? modes-test/text:keymap (tables:ref modes:keymaps modes-test/text:mode #f)))
  (check (eq? child-keymap (tables:ref modes:keymaps child #f)))
  (check-equal? 'test-file/modes/major:child child))

(test "a malformed modes:define-major-mode is a syntax error naming the form"
  (for-each
    (lambda (module message)
      (check-raises (lambda (c) (and (syntax-violation? c) (string=? message (condition-message c))))
                    (load-module! (list 'modes-test 'bad module))))
    '(major-no-keymap major-no-hook major-twice major-unknown major-malformed major-string-id)
    '("a keymap clause is required" "a hook clause is required" "clause given twice" "invalid clause" "invalid clause"
      "expected (modes:define-major-mode id clause ...)")))

(test "a major mode's clauses are checked as it is defined, naming the form, and no mode is defined"
  (for-each
    (lambda (module message)
      (check-raises (buffers-test:raised? 'modes:define-major-mode message) (load-module! (list 'modes-test 'bad module)))
      (check-equal? #f (tables:ref modes:hooks (string->symbol (format "modes-test/bad/~a:bad" module)) #f)))
    '(major-keymap major-lighter major-hook major-parent major-language major-plugin-only)
    '("not a keymap" "not a string" "not a hook" "not a mode" "not a string" "not a boolean")))

(test "a major mode defined again without a clause drops what that clause gave; unloading the module takes its entries back"
  (modes-test:write-module! "mine"
    (string-append "#!tuna\n(import (modes) (prog) (hooks) (tables))\n(tables:define-table keymap)\n(hooks:define-hook hook)\n"
                   "(modes:define-major-mode mode (hook hook) (keymap keymap) (parent prog:mode) (lighter \"Mine\") (language \"mine\"))\n"))
  (load-module! '(mine))
  (check-equal? '((mine:mode prog:mode) "Mine" "mine") (list (modes:ancestry 'mine:mode) (modes:lighter 'mine:mode) (modes:language 'mine:mode)))
  (modes-test:write-module! "mine"
    "#!tuna\n(import (modes) (hooks) (tables))\n(tables:define-table keymap)\n(hooks:define-hook hook)\n(modes:define-major-mode mode (keymap keymap) (hook hook))\n")
  (reload-modules! '((mine)))
  (check-equal? '((mine:mode) "mine" #f) (list (modes:ancestry 'mine:mode) (modes:lighter 'mine:mode) (modes:language 'mine:mode)))
  (let ([b (buffers:make "mine" "x")])
    (modes:set-major-mode 'mine:mode b)
    (unload-owner! (module-owner '(mine)))
    (check-equal? '(#f #f #f) (map (lambda (t) (tables:ref t 'mine:mode #f)) (list modes:hooks modes:keymaps modes:lighters)))
    (check-equal? 'mine:mode (modes:major-mode b))))
