#!tuna
(import (design-tokens-test css))

(define (split-words s)
  (let loop ([chars (string->list s)] [word '()] [acc '()])
    (let ([add (lambda () (if (null? word) acc (cons (list->string (reverse word)) acc)))])
      (cond
        [(null? chars) (reverse (add))]
        [(char=? (car chars) #\space) (loop (cdr chars) '() (add))]
        [else (loop (cdr chars) (cons (car chars) word) acc)]))))

;; Björn Ottosson's OKLab matrices.
(define (oklch->linear l c h)
  (let* ([a (* c (cos (* h (/ (acos -1.0) 180))))] [b (* c (sin (* h (/ (acos -1.0) 180))))]
         [l* (expt (+ l (* 0.3963377774 a) (* 0.2158037573 b)) 3)]
         [m* (expt (- l (* 0.1055613458 a) (* 0.0638541728 b)) 3)]
         [s* (expt (- l (* 0.0894841775 a) (* 1.2914855480 b)) 3)])
    (list (+ (* 4.0767416621 l*) (* -3.3077115913 m*) (* 0.2309699292 s*))
          (+ (* -1.2684380046 l*) (* 2.6097574011 m*) (* -0.3413193965 s*))
          (+ (* -0.0041960863 l*) (* -0.7034186147 m*) (* 1.7076147010 s*)))))

(define (oklch-values value)
  (let loop ([from 0] [acc '()])
    (let ([i (design-tokens-test/css:search value "oklch(" from)])
      (if i
          (let* ([end (design-tokens-test/css:search value ")" i)]
                 [parts (split-words (substring value (+ i 6) end))]
                 [l (car parts)])
            (loop end (cons (list (/ (string->number (substring l 0 (- (string-length l) 1))) 100.0)
                                  (string->number (cadr parts)) (string->number (caddr parts)))
                            acc)))
          (reverse acc)))))

(define (srgb-encode x)
  (let ([x (max 0 (min 1 x))])
    (if (<= x 0.0031308) (* 12.92 x) (- (* 1.055 (expt x (/ 1 2.4))) 0.055))))

(define (srgb-decode x)
  (if (<= x 0.04045) (/ x 12.92) (expt (/ (+ x 0.055) 1.055) 2.4)))

;; A browser draws a translucent colour over its background in encoded
;; sRGB, so an overlay on the surface is mixed there.
(define (overlay top alpha under)
  (map (lambda (t u) (srgb-decode (+ (* alpha (srgb-encode t)) (* (- 1 alpha) (srgb-encode u))))) top under))

(define (hex-colours value)
  (let loop ([from 0] [acc '()])
    (let ([i (design-tokens-test/css:search value "#" from)])
      (if i (loop (+ i 1) (cons (substring value (+ i 1) (+ i 7)) acc)) (reverse acc)))))

(define (hex->linear hex)
  (map (lambda (k) (srgb-decode (/ (string->number (substring hex k (+ k 2)) 16) 255.0))) '(0 2 4)))

(define (luminance rgb)
  (let ([clip (lambda (x) (max 0 (min 1 x)))])
    (+ (* 0.2126 (clip (car rgb))) (* 0.7152 (clip (cadr rgb))) (* 0.0722 (clip (caddr rgb))))))

(define (contrast a b)
  (let ([x (luminance a)] [y (luminance b)])
    (/ (+ (max x y) 0.05) (+ (min x y) 0.05))))

(define (rounded r) (/ (round (* 100 r)) 100.0))
