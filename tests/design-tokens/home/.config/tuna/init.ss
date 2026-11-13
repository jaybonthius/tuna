(import (tuna) (tuna plugins))
(use-plugin design-tokens)
(use-plugin faces)

(define (library-file name)
  (call-with-input-file (string-append (getenv "TUNA_LIBRARY") "/" name) get-string-all))

(define (search s sub from)
  (let ([n (string-length sub)] [m (string-length s)])
    (let loop ([i from])
      (cond
        [(> (+ i n) m) #f]
        [(let match ([k 0])
           (or (= k n) (and (char=? (string-ref s (+ i k)) (string-ref sub k)) (match (+ k 1)))))
         i]
        [else (loop (+ i 1))]))))

(define (occurrences s sub)
  (let loop ([from 0] [acc '()])
    (let ([i (search s sub from)])
      (if i (loop (+ i 1) (cons i acc)) (reverse acc)))))

(define (after s start)
  (substring s (+ (search s start 0) (string-length start)) (string-length s)))

(define (before s end)
  (substring s 0 (search s end 0)))

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

(define (split s c)
  (let loop ([i 0] [from 0] [acc '()])
    (cond
      [(= i (string-length s)) (reverse (cons (substring s from i) acc))]
      [(char=? (string-ref s i) c) (loop (+ i 1) (+ i 1) (cons (substring s from i) acc))]
      [else (loop (+ i 1) from acc)])))

(define (prefix? p s)
  (and (<= (string-length p) (string-length s)) (string=? p (substring s 0 (string-length p)))))

(define (declarations block)
  (fold-right
    (lambda (statement acc)
      (let ([statement (trim statement)])
        (if (prefix? "--" statement)
            (let ([colon (search statement ":" 0)])
              (cons (cons (substring statement 0 colon)
                          (trim (substring statement (+ colon 1) (string-length statement))))
                    acc))
            acc)))
    '() (split (without-comments block) #\;)))

(define tokens-css (library-file "design-tokens/design-tokens.css"))
(define tokens (declarations (before (after (before tokens-css "@layer preferences") ":root {") "}")))
(define reduced (declarations (before (after (after tokens-css "@layer preferences") ":root {") "}")))

(define (token name) (cdr (assoc (string-append "--tuna-" name) tokens)))

(define semantic-names
  '("surface" "surface-subtle" "surface-raised" "text" "text-muted" "text-faint"
    "bar" "on-bar" "bar-inactive" "on-bar-inactive" "border" "border-strong" "focus"
    "accent" "on-accent" "link" "hover" "pressed" "selected" "on-selected" "control"
    "cursor" "region" "line-current" "match" "match-other"
    "error" "error-surface" "warning" "warning-surface" "success" "success-surface" "info" "info-surface"
    "added" "added-surface" "removed" "removed-surface" "changed" "changed-surface"
    "font-ui" "font-code" "font-size-ui" "font-size-code" "line-height-code"
    "control-radius" "panel-radius" "border-width" "focus-width" "shadow-raised" "duration" "ease"))

(define (semantic? name) (member (substring name 7 (string-length name)) semantic-names))

(define primitives (filter (lambda (d) (not (semantic? (car d)))) tokens))

(define (named-primitive value)
  (and (prefix? "var(--tuna-" value)
       (let ([name (substring value 4 (- (string-length value) 1))])
         (and (assoc name primitives) (substring name 7 (string-length name))))))

(define (unresolved-semantic)
  (filter (lambda (n)
            (let ([d (assoc (string-append "--tuna-" n) tokens)])
              (not (and d (named-primitive (cdr d))))))
          semantic-names))

(define keyframes
  (map (lambda (i) (let ([from (+ i (string-length "@keyframes "))])
                     (substring tokens-css from (search tokens-css " " from))))
       (occurrences tokens-css "@keyframes ")))

(define (animations-without-keyframes)
  (filter (lambda (d)
            (and (prefix? "--tuna-animation-" (car d))
                 (let ([name (substring (cdr d) 0 (search (cdr d) " " 0))])
                   (not (and (member name keyframes)
                             (string=? name (string-append "tuna-" (substring (car d) 17 (string-length (car d))))))))))
          tokens))

(define (motion-left-on)
  (filter (lambda (d)
            (let ([r (assoc (car d) reduced)])
              (cond
                [(prefix? "--tuna-duration" (car d)) (not (and r (string=? (cdr r) "0s")))]
                [(prefix? "--tuna-animation-" (car d)) (not (and r (string=? (cdr r) "none")))]
                [else #f])))
          tokens))

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
  (map (lambda (i)
         (let ([parts (filter (lambda (w) (not (string=? w ""))) (split (substring value (+ i 6) (search value ")" i)) #\space))])
           (list (/ (string->number (before (car parts) "%")) 100.0)
                 (string->number (cadr parts))
                 (string->number (caddr parts)))))
       (occurrences value "oklch(")))

(define colour-names
  (filter (lambda (d)
            (let ([v (cdr d)])
              (and (or (prefix? "light-dark(oklch(" v) (prefix? "oklch(" v))
                   (not (string=? (car d) "--tuna-shadow-color")))))
          primitives))

(define (colour name mode)
  (let ([vs (oklch-values (token name))])
    (apply oklch->linear (if (and (eq? mode 'dark) (pair? (cdr vs))) (cadr vs) (car vs)))))

(define (outside-srgb)
  (filter (lambda (d)
            (exists (lambda (v) (not (for-all (lambda (x) (<= -1e-6 x (+ 1 1e-6))) (apply oklch->linear v))))
                    (oklch-values (cdr d))))
          colour-names))

(define (luminance rgb)
  (let ([clip (lambda (x) (max 0 (min 1 x)))])
    (+ (* 0.2126 (clip (car rgb))) (* 0.7152 (clip (cadr rgb))) (* 0.0722 (clip (caddr rgb))))))

(define (contrast a b)
  (let ([x (luminance a)] [y (luminance b)])
    (/ (+ (max x y) 0.05) (+ (min x y) 0.05))))

(define (primitive-of name)
  (if (member name semantic-names) (named-primitive (token name)) name))

(define faces-css (library-file "faces/faces.css"))

(define face-colours
  (map (lambda (i)
         (let* ([from (+ (search faces-css ", var(--tuna-" i) (string-length ", var(--tuna-"))])
           (substring faces-css from (search faces-css ")" from))))
       (occurrences faces-css "var(--faces-")))

(define pairs
  (append
    (map (lambda (bg) (list "text" bg 7)) '("surface" "surface-subtle" "surface-raised" "hover" "line-current" "region"))
    (apply append
      (map (lambda (fg) (map (lambda (bg) (list fg bg 4.5)) '("surface" "surface-subtle" "line-current" "region")))
           (append '("text-muted" "link") face-colours)))
    (map (lambda (p) (list (car p) (cdr p) 4.5))
         '(("on-bar" . "bar") ("on-bar-inactive" . "bar-inactive") ("on-accent" . "accent") ("on-selected" . "selected")
           ("text" . "control") ("text" . "match") ("text" . "match-other")))
    (apply append
      (map (lambda (s) (list (list s "surface" 4.5) (list s (string-append s "-surface") 4.5)))
           '("error" "warning" "success" "info" "added" "removed" "changed")))
    '(("text-faint" "surface" 3) ("focus" "surface" 3) ("cursor" "surface" 3))))

(define (low-contrast)
  (fold-right
    (lambda (p acc)
      (fold-right
        (lambda (mode acc)
          (let ([r (contrast (colour (primitive-of (car p)) mode) (colour (primitive-of (cadr p)) mode))])
            (if (< r (caddr p)) (cons (list (car p) (cadr p) mode r) acc) acc)))
        acc '(light dark)))
    '() pairs))

(define stylesheets
  '("design-tokens/design-tokens.css" "faces/faces.css" "views/views.css" "layout/layout.css" "layout-split/layout-split.css" "ui/ui.css"))

(define (references css)
  (map (lambda (i)
         (let* ([from (+ i 4)]
                [end (let loop ([k from]) (if (memv (string-ref css k) '(#\, #\))) k (loop (+ k 1))))])
           (cons (substring css from end) (char=? (string-ref css end) #\,))))
       (occurrences css "var(--")))

;; A design token must be declared; any other custom property is a
;; component token or a plugin's own, which nobody need declare, so it
;; must carry a fallback.
(define (dangling-references)
  (apply append
    (map (lambda (file)
           (map (lambda (r) (list file (car r)))
                (filter (lambda (r) (not (if (prefix? "--tuna-" (car r)) (assoc (car r) tokens) (cdr r))))
                        (references (library-file file)))))
         stylesheets)))

;; Without the token file a declaration that reads a token with no
;; fallback is invalid as a whole, so a fallback beside it never shows.
(define (bare-tokens file selector)
  (let ([css (library-file file)])
    (map car (filter (lambda (r) (not (cdr r)))
                     (references (before (after css (string-append "\n  " selector " {")) "}"))))))

(define (without-layer-order)
  (filter (lambda (file) (not (prefix? "@layer defaults, themes, preferences;" (library-file file)))) stylesheets))

(define (with-important)
  (filter (lambda (file) (search (library-file file) "!important" 0)) stylesheets))

(import (console))
