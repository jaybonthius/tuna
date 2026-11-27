(import (tuna) (test) (hooks) (buffers) (buffers-test))

(buffers:define-layer hl (priority 5))
(buffers:define-kind foo (inline))

(test "a reload of buffers keeps the types of the buffers, edits, anchors, kinds and layer types made before it"
  (let* ([b (buffers:make "a" "hello world\n")] [a (buffers:anchor b 3)] [e (buffers:replace! b 1 1 "q")])
    (buffers:add-span! (buffers:layer b hl) 1 3 'x)
    (reload-modules! '((buffers)))
    (check-equal? '(#t #f "a" #t #t) (list (buffers:buffer? b) (buffers:live? b) (buffers:name b) (buffers:edit? e) (buffers:anchor? a)))
    (check-equal? '(#t #t) (list (buffers:kind? (buffers:constructor-kind foo)) (buffers:kind? (buffers:kind 'buffers:text))))
    (check-raises (buffers-test:raised? 'buffers:replace! "not a live buffer") (buffers:replace! b 1 1 "q"))))

(test "a layer type defined before the reload still moves spans and checks edits"
  (let ([c (buffers:make "c" "hello\n")])
    (buffers:add-span! (buffers:layer c hl) 1 3 'y)
    (buffers:replace! c 1 1 "zz")
    (check-equal? '((3 5 y)) (buffers:spans (buffers:layer c hl) 0 8))))

(test "a reload closes every buffer without asking the kill queries or calling killed"
  (let* ([d (buffers:make "d" "")] [called '()] [note (lambda (b) (set! called (cons b called)) #t)])
    (hooks:add! buffers:kill-queries note)
    (hooks:add! buffers:killed note)
    (reload-modules! '((buffers)))
    (check-equal? '(#f ()) (list (buffers:live? d) called))
    (check-equal? '() (buffers:all))))
