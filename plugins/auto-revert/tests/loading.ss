(import (tuna) (test) (test-runner) (buffers) (views) (layout) (files) (file-watch-test) (auto-revert-test))

;; This file loads and unloads auto-revert itself, so it imports neither
;; the plugin nor anything that does, which would unload the file with it.

(define (home name) (file-watch-test:home name))

(file-watch-test:folder! "open")
(file-watch-test:write! "open/kept.txt" "kept\n")
(file-watch-test:write! "open/edited.txt" "edited\n")

(define kept (files:visit (home "open/kept.txt")))
(define edited (files:visit (home "open/edited.txt")))

(define v (layout:selected-view))

(test "loading the plugin with file buffers open watches each and checks it once: a file changed before the load is reloaded"
  (views:set-buffer! v edited)
  (buffers:replace! edited 1 1 "mine ")
  (file-watch-test:write! "open/kept.txt" "kept, changed\n")
  (file-watch-test:write! "open/edited.txt" "edited, changed\n")
  (load-module! '(auto-revert))
  (auto-revert-test:wait-for-text kept "kept, changed\n")
  (test-runner:wait-until (lambda () (member "Stale" (auto-revert-test:lighters v))))
  (check-equal? 1 (auto-revert-test:inotify-watches)))

(test "unloading the plugin ends every watch and takes Stale away"
  (unload-owner! (module-owner '(auto-revert)))
  (check-equal? #f (member "Stale" (auto-revert-test:lighters v)))
  (check-equal? 0 (auto-revert-test:inotify-watches)))
