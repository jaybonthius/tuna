(import (tuna) (test) (test-user) (hooks) (views) (editing) (completion) (completion-test sessions))

(load-module! '(completion-popup))

(define (greek)
  (let* ([v (views:current)] [b (views:buffer v)] [p (views:point v)] [s (editing:forward-word-position b p -1)])
    (and (< s p) (completion:region s p (list (completion:source (candidates (vector "alpha" "alpine"))))))))

(define (popup-roots) (test-user:elements (test-user:screen) "completion-popup"))

(test "unloading completion-popup closes its popups and leaves the session; loading it again draws the next"
  (hooks:add! completion:find-region greek)
  (test-user:show! "al|")
  (test-user:press! "C-M-i")
  (check-equal? 1 (length (popup-roots)))
  (unload-owner! (module-owner '(completion-popup)))
  (test-user:settle)
  (check-equal? '() (popup-roots))
  (check (completion-test/sessions:session))
  (test-user:press! "C-g")
  (load-module! '(completion-popup))
  (test-user:press! "C-M-i")
  (check-equal? 1 (length (popup-roots)))
  (test-user:press! "C-g")
  (hooks:remove! completion:find-region greek))
