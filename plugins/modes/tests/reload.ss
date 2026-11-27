(import (tuna) (test) (modes) (prog) (buffers) (hooks) (options) (tables) (buffers-test)
        (modes-test text) (modes-test fill) (modes-test code))

(define (local option b) (buffers:with-buffer b (option)))

(options:define-option probe 0 fixnum? "A value set by hand.")

(define (state b) (list (modes:major-mode b) (local modes-test/fill:column b) (local probe b)))

(define code (buffers:make "code" "f(x)\n"))
(define notes (buffers:make "notes" "Buy milk.\n"))
(define plain (buffers:make "plain" "x"))

(modes:set-major-mode modes-test/code:mode code)
(modes:set-major-mode modes-test/text:mode notes)
(buffers:with-buffer code (options:set-local! probe 33))

(test "reloading a mode's module runs the mode hooks again, so its local values come back, and values set by hand stay"
  (buffers:with-buffer code (options:set-local! modes-test/fill:column 20))
  (modes:set-major-mode modes-test/code:mode code)
  (buffers:with-buffer code (options:set-local! probe 33))
  (check-equal? (list modes-test/code:mode 79 33) (state code))
  (reload-modules! '((modes-test code)))
  (check-equal? (list modes-test/code:mode 79 33) (state code))
  (check-equal? (list modes-test/code:mode modes-test/text:mode modes:fundamental) (map modes:major-mode (list code notes plain))))

(import (modes-test indent))

(test "a plugin loaded after buffers are open reaches those in its modes with its hook entries, and no other"
  (check-equal? '(2 8 8) (map (lambda (b) (local modes-test/indent:width b)) (list code notes plain))))

(test "unloading a mode's module takes its entries back, and its buffers keep the mode; loading it again gives back its values"
  (let ([old (module-owner '(modes-test code))])
    (unload-owner! old)
    (check-equal? '(#f #f #f) (map (lambda (t) (tables:ref t modes-test/code:mode #f)) (list modes:hooks modes:parents modes:lighters)))
    (check-equal? modes-test/code:mode (modes:major-mode code))
    (load-module! '(modes-test code))
    (check-equal? (list modes-test/code:mode prog:mode) (modes:ancestry modes-test/code:mode))
    (check-equal? (list modes-test/code:mode 79 33) (state code))))

(test "reloading modes keeps each buffer's mode, by name, and resets no scope"
  (reload-modules! '((modes)))
  (check-equal? (list modes-test/code:mode modes-test/text:mode modes:fundamental) (map modes:major-mode (list code notes plain)))
  (check-equal? (list modes-test/code:mode 79 33) (state code)))

(test "a buffer renamed while modes is unloaded is not found by its name when it loads again; one not renamed keeps its mode"
  (let ([a (buffers:make "a" "a\n")] [renamed (buffers:make "to rename" "b\n")])
    (for-each (lambda (b) (modes:set-major-mode modes-test/text:mode b)) (list a renamed))
    (unload-owner! (module-owner '(modes)))
    (buffers:rename! renamed "renamed")
    (load-module! '(modes))
    (check-equal? (list modes-test/text:mode modes:fundamental) (map modes:major-mode (list a renamed)))))
