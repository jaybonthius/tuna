(import (tuna) (test) (test-user) (keys) (buffers) (views) (layout) (layout-split) (search) (occur) (isearch-test) (occur-test))

(define wins occur-test:wins)

(define b (occur-test:src! "one foo\ntwo\nfoo three foo\n"))

(test "r renames *Occur* after its source; a name in use is an error; C-u r makes a free name"
  (occur-test:occur! (occur-test:rx "foo") 0 #f)
  (occur-test:in-occur!)
  (test-user:press! "r")
  (check-equal? "*Occur: src*" (buffers:name (views:buffer (occur-test:view))))
  (layout:select! (occur-test:source-view b))
  (occur-test:occur! (occur-test:rx "foo") 0 #f)
  (occur-test:in-occur!)
  (check-equal? '("Buffer name ‘*Occur: src*’ is in use") (occur-test:reported "r"))
  (check-equal? "*Occur*" (buffers:name (views:buffer (occur-test:view))))
  (test-user:press! "C-u r")
  (check-equal? "*Occur: src*<2>" (buffers:name (views:buffer (occur-test:view)))))

(test "a printing key no map binds is undefined and changes nothing"
  (let ([before (occur-test:text-of (views:buffer (occur-test:view)))])
    (check-equal? '("a is undefined") (occur-test:reported "a"))
    (check-equal? before (occur-test:text-of (views:buffer (occur-test:view))))))

(test "SPC and DEL scroll, as in any special buffer"
  (check-equal? (list views:scroll-up views:scroll-down)
                (views:with-view (occur-test:view) (map (lambda (k) (keys:lookup (test-user:client) k)) (list "SPC" "DEL")))))

(test "q puts back what the view showed before *Occur*, keeping *Occur*"
  (test-user:press! "q")
  (check-equal? '((("src" 1 #f) ("*Occur: src*" 2 #t)) #t)
                (list (wins) (buffers:live? (buffers:find "*Occur: src*<2>")))))

(test "q deletes a view split for *Occur*, keeping *Occur*"
  (occur-test:src! "one foo\n")
  (occur-test:only!)
  (occur-test:occur! (occur-test:rx "foo") 0 #f)
  (check-equal? '(("src" 1 #t) ("*Occur*" 2 #f)) (wins))
  (occur-test:in-occur!)
  (test-user:press! "q")
  (check-equal? (list '(("src" 1 #t)) #t) (list (wins) (buffers:live? (occur-test:occur-buffer)))))
