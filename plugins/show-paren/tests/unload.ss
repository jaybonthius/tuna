(import (tuna) (test) (test-user) (buffers) (document) (views) (show-paren) (editing-test scene) (sexp-test scene))

(test "unloading the plugin takes its highlights away"
  (let* ([b (sexp-test/scene:show! "(a b)|")] [layer (buffers:layer b show-paren:highlights (editing-test/scene:view))])
    (test-user:settle)
    (check-equal? 2 (length (buffers:spans layer 0 7)))
    (unload-owner! (module-owner '(show-paren)))
    (test-user:settle)
    (check-equal? '() (buffers:spans layer 0 7))))
