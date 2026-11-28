(import (tuna) (test) (test-runner) (options) (buffers) (files) (auto-revert) (file-watch-test) (auto-revert-test))

(define (home name) (file-watch-test:home name))

(options:set! auto-revert:interval 0.05)

(test "a buffer whose watch is inactive, as when its folder is missing, is checked every auto-revert:interval seconds and reloads"
  (let ([later (files:visit (home "later/l.txt"))])
    (file-watch-test:folder! "later")
    (file-watch-test:write! "later/l.txt" "made later\n")
    (auto-revert-test:wait-for-text later "made later\n")
    (file-watch-test:write! "later/l.txt" "made later, changed\n")
    (auto-revert-test:wait-for-text later "made later, changed\n")))

(test "with auto-revert:use-notify? false no buffer is watched, and every buffer is polled; set again, the buffers are watched and each checked once"
  (file-watch-test:write! "p.txt" "p\n")
  (let ([p (files:visit (home "p.txt"))])
    (options:set! auto-revert:use-notify? #f)
    (check-equal? 0 (auto-revert-test:inotify-watches))
    (file-watch-test:write! "p.txt" "p polled\n")
    (auto-revert-test:wait-for-text p "p polled\n")
    (options:set! auto-revert:interval 1000)
    (file-watch-test:write! "p.txt" "p checked once\n")
    (options:unset! auto-revert:use-notify?)
    (check (> (auto-revert-test:inotify-watches) 0))
    (auto-revert-test:wait-for-text p "p checked once\n")))
