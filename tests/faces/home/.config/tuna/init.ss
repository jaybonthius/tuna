(import (tuna) (tuna plugins) (haml))
(use-plugin faces)
(use-plugin views)

(define (search s sub from)
  (let ([n (string-length sub)] [m (string-length s)])
    (let loop ([i from])
      (cond
        [(> (+ i n) m) #f]
        [(string=? (substring s i (+ i n)) sub) i]
        [else (loop (+ i 1))]))))

(define (lines view)
  (let ([html (html->string (views:draw view #f))])
    (substring html (+ (search html "<div class=\"view-lines\">" 0) 24) (- (string-length html) 12))))

(import (console))
