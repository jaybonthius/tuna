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

(define (library-file name)
  (call-with-input-file (string-append (getenv "TUNA_LIBRARY") "/" name) get-string-all))

(define (without-comments s)
  (let loop ([from 0] [acc '()])
    (let ([i (search s "/*" from)])
      (if i
          (loop (+ (search s "*/" i) 2) (cons (substring s from i) acc))
          (apply string-append (reverse (cons (substring s from (string-length s)) acc)))))))

(define (trim s)
  (let loop ([i 0] [j (string-length s)])
    (cond
      [(and (< i j) (char-whitespace? (string-ref s i))) (loop (+ i 1) j)]
      [(and (< i j) (char-whitespace? (string-ref s (- j 1)))) (loop i (- j 1))]
      [else (substring s i j)])))

(define (prefix? p s)
  (and (<= (string-length p) (string-length s)) (string=? p (substring s 0 (string-length p)))))

(define (split s c)
  (let loop ([i 0] [from 0] [depth 0] [acc '()])
    (cond
      [(= i (string-length s)) (reverse (cons (substring s from i) acc))]
      [(char=? (string-ref s i) #\() (loop (+ i 1) from (+ depth 1) acc)]
      [(char=? (string-ref s i) #\)) (loop (+ i 1) from (- depth 1) acc)]
      [(and (= depth 0) (char=? (string-ref s i) c)) (loop (+ i 1) (+ i 1) depth (cons (substring s from i) acc))]
      [else (loop (+ i 1) from depth acc)])))

(define (closing s open)
  (let loop ([i (+ open 1)] [depth 1])
    (case (string-ref s i)
      [(#\{) (loop (+ i 1) (+ depth 1))]
      [(#\}) (if (= depth 1) i (loop (+ i 1) (- depth 1)))]
      [else (loop (+ i 1) depth)])))

(define (css-rules css)
  (let walk ([s (without-comments css)] [layer ""])
    (let loop ([i 0] [acc '()])
      (let ([open (search s "{" i)])
        (if (not open)
            (reverse acc)
            (let* ([end (closing s open)]
                   [start (let back ([k open])
                            (if (or (= k i) (memv (string-ref s (- k 1)) '(#\; #\}))) k (back (- k 1))))]
                   [prelude (trim (substring s start open))]
                   [body (substring s (+ open 1) end)])
              (loop (+ end 1)
                    (cond
                      [(prefix? "@layer " prelude)
                       (append (reverse (walk body (trim (substring prelude 7 (string-length prelude))))) acc)]
                      [(prefix? "@keyframes" prelude) acc]
                      [(prefix? "@" prelude) (append (reverse (walk body (string-append layer " " prelude))) acc)]
                      [else
                       (cons (list layer prelude
                                   (map (lambda (d) (let ([colon (search d ":" 0)])
                                                      (cons (trim (substring d 0 colon)) (trim (substring d (+ colon 1) (string-length d))))))
                                        (filter (lambda (d) (not (string=? (trim d) ""))) (split body #\;))))
                             acc)]))))))))

(define every-stylesheet
  (let ([library (getenv "TUNA_LIBRARY")])
    (list-sort string<?
      (apply append
        (map (lambda (folder)
               (if (file-directory? (string-append library "/" folder))
                   (map (lambda (f) (string-append folder "/" f))
                        (filter (lambda (f) (let ([n (string-length f)]) (and (> n 4) (string=? (substring f (- n 4) n) ".css"))))
                                (directory-list (string-append library "/" folder))))
                   '()))
             (directory-list library))))))

(define (face-rule? r) (prefix? "[data-face" (cadr r)))

(define face-stylesheets
  (filter (lambda (file) (exists (lambda (r) (string=? (car r) "defaults.faces")) (css-rules (library-file file))))
          every-stylesheet))

(define (face-rules-outside-sublayer)
  (apply append
    (map (lambda (file)
           (map (lambda (r) (list file (car r) (cadr r)))
                (filter (lambda (r) (and (face-rule? r) (not (string=? (car r) "defaults.faces"))
                                         (not (prefix? "preferences" (car r)))))
                        (css-rules (library-file file)))))
         every-stylesheet)))

(define (face-of-rule r)
  (let* ([sel (cadr r)] [from (+ (search sel "\"" 0) 1)])
    (substring sel from (search sel "\"" from))))

(define seven
  '(("color" . "color") ("background-color" . "background") ("font-weight" . "font-weight")
    ("font-style" . "font-style") ("font-family" . "font-family") ("font-size" . "font-size")
    ("text-decoration" . "text-decoration")))

(define (hyphens s) (list->string (map (lambda (c) (if (char=? c #\.) #\- c)) (string->list s))))

(define (own-token file face suffix)
  (if (string=? file "faces/faces.css")
      (string-append "--faces-" (if (string=? face "") "builtin" (hyphens face)) "-" suffix)
      (string-append "--" (hyphens face) "-" suffix)))

(define (chain value)
  (if (prefix? "var(--" value)
      (let ([comma (search value "," 0)])
        (if comma
            (cons (substring value 4 comma)
                  (chain (trim (substring value (+ comma 1) (- (string-length value) 1)))))
            (list (substring value 4 (- (string-length value) 1)))))
      (list value)))

(define (rule-chain file face property)
  (let ([r (find (lambda (r) (and (string=? (car r) "defaults.faces") (string=? (face-of-rule r) face)))
                 (css-rules (library-file file)))])
    (chain (cdr (assoc property (caddr r))))))

(define (malformed-face-rules)
  (apply append
    (map (lambda (file)
           (fold-right
             (lambda (r acc)
               (if (not (string=? (car r) "defaults.faces"))
                   acc
                   (let* ([face (if (prefix? "[data-face$=" (cadr r)) "" (face-of-rule r))]
                          [ds (caddr r)]
                          [bad (filter (lambda (p)
                                         (let ([d (assoc (car p) ds)])
                                           (not (and d
                                                     (let ([c (chain (cdr d))])
                                                       (and (string=? (car c) (own-token file face (cdr p)))
                                                            (for-all (lambda (t) (let ([n (string-length t)] [m (string-length (cdr p))])
                                                                                   (and (> n m) (string=? (substring t (- n m) n) (cdr p)))))
                                                                     (reverse (cdr (reverse c))))
                                                            (let ([end (car (last-pair c))])
                                                              (or (not (prefix? "--" end)) (prefix? "--tuna-" end)))))))))
                                       seven)]
                          [extra (filter (lambda (d) (not (or (assoc (car d) seven) (string=? (car d) "text-decoration-skip-ink")))) ds)])
                     (if (and (null? bad) (null? extra))
                         acc
                         (cons (list file (cadr r) (map car bad) (map car extra)) acc)))))
             '() (css-rules (library-file file))))
         face-stylesheets)))

(define defined-faces
  (let ([source (library-file "faces.sls")])
    (map (lambda (i) (let ([from (+ i 8)]) (substring source from (search source " " from))))
         (let loop ([from 0] [acc '()])
           (let ([i (search source "(define " from)])
             (if i (loop (+ i 1) (cons i acc)) (reverse acc)))))))

(define styled-faces
  (map face-of-rule (filter (lambda (r) (and (string=? (car r) "defaults.faces") (prefix? "[data-face=\"" (cadr r))))
                            (css-rules (library-file "faces/faces.css")))))

(define (unstyled-faces) (filter (lambda (f) (not (member f styled-faces))) defined-faces))

(define (styled-not-defined) (filter (lambda (f) (not (member f defined-faces))) styled-faces))
