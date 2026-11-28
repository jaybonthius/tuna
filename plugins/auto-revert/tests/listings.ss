(import (tuna) (test) (test-runner) (test-user) (options) (document) (buffers) (views) (dired) (files) (auto-revert)
        (files-test) (file-watch-test) (auto-revert-test))

(define (home name) (file-watch-test:home name))

(define (entries b)
  (let ([doc (buffers:document b)])
    (let loop ([p 0] [acc '()])
      (let ([t (document:token doc p)])
        (cond
          [(eof-object? t) (reverse acc)]
          [(and (document:node? t) (eq? (document:node-kind t) 'dired:%entry)) (loop (+ p 1) (cons t acc))]
          [else (loop (+ p 1) acc)])))))

(define (lines b)
  (map (lambda (e) (string-append (let ([m (dired:entry-mark e)]) (if m (string m) " ")) " " (path-last (dired:entry-path e))))
       (filter (lambda (e) (not (member (path-last (dired:entry-path e)) '("." "..")))) (entries b))))

(file-watch-test:folder! "src")
(file-watch-test:write! "src/a.txt" "a\n")
(file-watch-test:write! "src/b.txt" "b\n")

(define listing (dired:visit (home "src")))

(define v (auto-revert-test:show! listing))

(define (point-name) (path-last (dired:entry-path (dired:entry-at v))))

(test "with auto-revert:non-file-buffers? left #f, a listing is not watched, and a revisit does what dired:refresh-when-revisited? says"
  (check-equal? 0 (auto-revert-test:inotify-watches))
  (file-watch-test:write! "src/new.txt" "new\n")
  (files-test:take-said!)
  (dired:visit (home "src"))
  (check-equal? '(("  a.txt" "  b.txt") ("Folder changed on disk; type g to refresh")) (list (lines listing) (files-test:take-said!)))
  (options:set! dired:refresh-when-revisited? #t)
  (dired:visit (home "src"))
  (check-equal? '("  a.txt" "  b.txt" "  new.txt") (lines listing))
  (options:unset! dired:refresh-when-revisited?)
  (delete-file (home "src/new.txt"))
  (dired:refresh listing))

(test "with it #t, a listing is watched at its folder, and an entry made or deleted there refreshes it, keeping its marks and point"
  (options:set! auto-revert:non-file-buffers? #t)
  (views:set-point! v (document:node-start (car (filter (lambda (e) (equal? "a.txt" (path-last (dired:entry-path e)))) (entries listing)))))
  (test-user:press! "m")
  (check-equal? '(("* a.txt" "  b.txt") "b.txt") (list (lines listing) (point-name)))
  (file-watch-test:write! "src/c.txt" "c\n")
  (test-runner:wait-until (lambda () (equal? '("* a.txt" "  b.txt" "  c.txt") (lines listing))))
  (check-equal? "b.txt" (point-name))
  (delete-file (home "src/c.txt"))
  (test-runner:wait-until (lambda () (equal? '("* a.txt" "  b.txt") (lines listing))))
  (check-equal? "b.txt" (point-name))
  (options:unset! auto-revert:non-file-buffers?))
