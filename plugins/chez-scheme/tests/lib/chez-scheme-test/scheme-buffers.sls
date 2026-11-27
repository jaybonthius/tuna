#!tuna
(import (buffers) (document) (modes) (syntax) (syntax-highlighting) (chez-scheme))

(define (text b) (document:text (buffers:document b)))

(define (scheme-buffer name content)
  (let ([b (buffers:make (buffers:free-name name) content)])
    (modes:set-major-mode chez-scheme:mode b)
    b))

(define (faces b)
  (map (lambda (s) (list (document:text (buffers:document b) (car s) (cadr s)) (cdr (assq 'face (caddr s)))))
       (buffers:spans (buffers:layer b syntax-highlighting:faces) 0 (document:length (buffers:document b)))))

(define (face-of b word)
  (let ([found (assoc word (faces b))])
    (and found (cadr found))))

(define (brackets b)
  (buffers:spans (buffers:layer b syntax:brackets) 0 (document:length (buffers:document b))))

(define (%index b string)
  (let* ([all (text b)] [n (string-length string)])
    (let loop ([i 0])
      (if (string=? (substring all i (+ i n)) string)
          i
          (loop (+ i 1))))))

(define (after b string)
  (document:position (buffers:document b) (+ (%index b string) (string-length string)) (document:unit characters)))

(define (home-file path) (string-append (getenv "HOME") "/" path))

(define (write-text! path text)
  (call-with-port (open-file-output-port (home-file path) (file-options no-fail))
    (lambda (p) (put-bytevector p (string->utf8 text)))))

;; Tests open, edit and reload these as a user's own modules, in lib/.
(define (write-lib-modules!)
  (write-text! ".config/tuna/lib/zeppo.sls"
    "#!tuna\n(import (buffers))\n\n(define (%tune n) n)\n\n(define (sing n) (%tune n))\n\n(define volume 3)\n")
  (write-text! ".config/tuna/lib/tunes.sls" "#!tuna\n(define (hum) (%note 1))\n\n(define (%note n) n)\n"))
