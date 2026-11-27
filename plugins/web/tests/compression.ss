(import (tuna) (test) (test-runner) (web) (haml) (web-test http))

(web-test/http:use-url! (lambda () (web:url)))
(test-runner:wait-until (lambda () (web:url)))

(define (encoding accept)
  (web-test/http:header
    (web-test/http:get (string-append "/screen?datastar=" (web-test/http:encode "{\"client\":\"nobody\"}")) accept)
    "content-encoding"))

(test "the stream is compressed with the first of zstd, brotli and gzip that the browser accepts"
  (check-equal? '("zstd" "br" "gzip" #f)
    (list (encoding '(("accept-encoding" . "gzip, deflate, br, zstd"))) (encoding '(("accept-encoding" . "gzip, deflate, br")))
          (encoding '(("accept-encoding" . "gzip, deflate"))) (encoding '()))))

(define (typed-screen n)
  (haml (:pre (map (lambda (i)
                     (format "~a (define (name-~a x) (+ x ~a))~a\n"
                             i (mod (* i 7919) 997) (mod (* i 104729) 89) (if (= i 200) (make-string n #\x) "")))
                   (iota 400)))))

(test "with brotli, a screen that differs a little from the one before costs a few dozen bytes, found in the screens sent"
  (let* ([p (web-test/http:page)] [s (web-test/http:open-raw! p '(("accept-encoding" . "br")))])
    (check-equal? "br" (web-test/http:raw-encoding s))
    (let ([c (car (web:clients))])
      (web:send-screen! c (typed-screen 0) "Tuna")
      (check (> (web-test/http:raw-next s) 2000))
      (for-each
        (lambda (n)
          (web-test/http:confirm! p n)
          (web:send-screen! c (typed-screen n) "Tuna")
          (check (< 0 (web-test/http:raw-next s) 200)))
        '(1 2 3 4)))
    (web-test/http:close-raw! s)))
