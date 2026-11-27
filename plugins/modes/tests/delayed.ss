(import (tuna) (test) (modes) (prog) (buffers) (hooks) (options) (buffers-test) (modes-test fill) (modes-test code))

(define (local option b) (buffers:with-buffer b (option)))

(define calls '())

(define (note! what) (set! calls (cons what calls)))

(define (take-calls!) (let ([c (reverse calls)]) (set! calls '()) c))

(define (hooked) (note! (list 'hook (buffers:current))))

(define (changed b) (note! (list 'changed b (eq? b (buffers:current)))))

(define (delayed b) (note! (list 'delayed b (eq? b (buffers:current)))))

(hooks:add! modes-test/code:mode-hook hooked)
(hooks:add! modes:major-mode-changed changed)
(hooks:add! modes:delayed-mode-changed delayed)

(test "a mode set with its hooks delayed gets a new scope and runs delayed-mode-changed, with the buffer current, and no mode hook"
  (let ([b (buffers:make "previewed" "x")])
    (buffers:with-buffer b (options:set-local! modes-test/fill:column 99))
    (modes:set-major-mode-delaying-hooks modes-test/code:mode b)
    (check-equal? (list (list 'delayed b #t)) (take-calls!))
    (check-equal? modes-test/code:mode (modes:major-mode b))
    (check-equal? #t (modes:hooks-delayed? b))
    (check-equal? 70 (local modes-test/fill:column b))))

(test "run-delayed-hooks runs the hooks and major-mode-changed once, in the scope the mode was set with; then it does nothing"
  (let ([b (buffers:make "completed" "x")])
    (modes:set-major-mode-delaying-hooks modes-test/code:mode b)
    (take-calls!)
    (buffers:with-buffer b (options:set-local! modes-test/fill:mode #t))
    (modes:run-delayed-hooks b)
    (check-equal? (list (list 'hook b) (list 'changed b #t)) (take-calls!))
    (check-equal? '(#f 79 #t) (list (modes:hooks-delayed? b) (local modes-test/fill:column b) (local modes-test/fill:mode b)))
    (modes:run-delayed-hooks b)
    (check-equal? '() (take-calls!))))

(test "a buffer whose hooks wait is left out of the runs after a module loads"
  (let ([waiting (buffers:make "waiting" "x")] [set (buffers:make "set" "x")])
    (modes:set-major-mode-delaying-hooks modes-test/code:mode waiting)
    (modes:set-major-mode modes-test/code:mode set)
    (take-calls!)
    (reload-modules! '((modes-test fill)))
    (check-equal? (list (list 'hook set)) (filter (lambda (c) (memq (cadr c) (list waiting set))) (take-calls!)))
    (check-equal? #t (modes:hooks-delayed? waiting))))

(test "setting the mode as usual ends the wait"
  (let ([b (buffers:make "set later" "x")])
    (modes:set-major-mode-delaying-hooks modes-test/code:mode b)
    (modes:set-major-mode modes-test/code:mode b)
    (check-equal? #f (modes:hooks-delayed? b))
    (take-calls!)
    (modes:run-delayed-hooks b)
    (check-equal? '() (take-calls!))))

(test "the delayed entries check their arguments"
  (let ([b (buffers:make "checked" "x")] [gone (buffers:make "gone" "x")])
    (buffers:kill! gone)
    (check-raises (buffers-test:raised? 'modes:set-major-mode-delaying-hooks "not a major mode")
                  (modes:set-major-mode-delaying-hooks 'nothere:mode b))
    (check-raises (buffers-test:raised? 'modes:set-major-mode-delaying-hooks "not a live buffer")
                  (modes:set-major-mode-delaying-hooks modes-test/code:mode gone))
    (check-raises (buffers-test:raised? 'modes:hooks-delayed? "not a live buffer") (modes:hooks-delayed? gone))
    (check-raises (buffers-test:raised? 'modes:run-delayed-hooks "not a live buffer") (modes:run-delayed-hooks gone))
    (check-equal? '(modes:set-major-mode-delaying-hooks "not on the main thread")
                  (buffers-test:on-thread (lambda () (modes:set-major-mode-delaying-hooks modes-test/code:mode b))))
    (check-equal? modes:fundamental (modes:major-mode b))))
