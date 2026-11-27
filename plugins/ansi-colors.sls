#!tuna
(import (views) (web) (prefix (ghostty) ghostty:) (tables))

(define black 'ansi-colors.black)
(define red 'ansi-colors.red)
(define green 'ansi-colors.green)
(define yellow 'ansi-colors.yellow)
(define blue 'ansi-colors.blue)
(define magenta 'ansi-colors.magenta)
(define cyan 'ansi-colors.cyan)
(define white 'ansi-colors.white)
(define bright-black 'ansi-colors.bright-black)
(define bright-red 'ansi-colors.bright-red)
(define bright-green 'ansi-colors.bright-green)
(define bright-yellow 'ansi-colors.bright-yellow)
(define bright-blue 'ansi-colors.bright-blue)
(define bright-magenta 'ansi-colors.bright-magenta)
(define bright-cyan 'ansi-colors.bright-cyan)
(define bright-white 'ansi-colors.bright-white)

(module %internals
  (faces default-palette plain-style check-palette span-value-of span-attributes filter-of)

  (define faces
    (vector black red green yellow blue magenta cyan white
            bright-black bright-red bright-green bright-yellow bright-blue bright-magenta bright-cyan
            bright-white))

  (define default-palette (ghostty:color-default-palette))

  (define plain-style (ghostty:make-style #f #f #f #f #f #f #f #f #f #f #f 'none))

  (define (check-palette who palette)
    (unless (and (vector? palette) (fx= (vector-length palette) 256))
      (assertion-violation who "not a vector of 256 colors" palette)))

  (define (hex rgb)
    (format "#~2,'0x~2,'0x~2,'0x" (ghostty:rgb-red rgb) (ghostty:rgb-green rgb) (ghostty:rgb-blue rgb)))

  (define (resolve-color c palette)
    (cond
      [(not c) #f]
      [(ghostty:rgb? c) (hex c)]
      [(fx< c 16) c]
      [else (hex (vector-ref palette c))]))

  (define (span-value-of style palette)
    (let* ([inverse? (ghostty:style-inverse? style)]
           [fg (resolve-color (ghostty:style-foreground style) palette)]
           [bg (resolve-color (ghostty:style-background style) palette)]
           [fg* (if inverse? (or bg 'background) fg)]
           [bg* (if inverse? (or fg 'foreground) bg)]
           [words '()] [properties '()] [face #f])
      (define (word! w) (set! words (cons w words)))
      (define (property! name value) (set! properties (cons (cons name value) properties)))
      (cond
        [(not fg*)]
        [(eq? fg* 'background) (word! "fg-background")]
        [(fixnum? fg*) (set! face (vector-ref faces fg*))]
        [else (word! "fg") (property! "--ansi-colors-fg" fg*)])
      (cond
        [(not bg*)]
        [(eq? bg* 'foreground) (word! "bg-foreground")]
        [(fixnum? bg*) (word! (format "bg-~a" bg*))]
        [else (word! "bg") (property! "--ansi-colors-bg" bg*)])
      (when (ghostty:style-bold? style) (word! "bold"))
      (when (ghostty:style-italic? style) (word! "italic"))
      (when (ghostty:style-faint? style) (word! "faint"))
      (when (ghostty:style-invisible? style) (word! "invisible"))
      (when (ghostty:style-strikethrough? style) (word! "strike"))
      (when (ghostty:style-overline? style) (word! "overline"))
      (let ([u (ghostty:style-underline style)])
        (unless (eq? u 'none) (word! (format "underline-~a" u))))
      (let ([uc (resolve-color (ghostty:style-underline-color style) palette)])
        (cond
          [(not uc)]
          [(fixnum? uc) (word! (format "underline-color-~a" uc))]
          [else (word! "underline-color") (property! "--ansi-colors-underline" uc)]))
      (and (or face (pair? words))
           (append (if face (list (cons 'face face)) '())
                   (if (pair? words) (list (cons 'ansi-colors (cons (reverse words) (reverse properties)))) '())))))

  (define (span-attributes v)
    (let ([words (car v)] [properties (cdr v)])
      (append
        (list (cons "data-ansi-colors"
                    (apply string-append (car words) (map (lambda (w) (string-append " " w)) (cdr words)))))
        (if (null? properties)
            '()
            (list (cons "style" (apply string-append (map (lambda (p) (string-append (car p) ":" (cdr p) ";")) properties))))))))

  ;; The pen changes as libghostty's terminal changes its own, in
  ;; Screen.setAttribute, so a run and a terminal read one sequence alike.
  (define (apply-attributes pen attributes)
    (let ([fg (ghostty:style-foreground pen)] [bg (ghostty:style-background pen)]
          [uc (ghostty:style-underline-color pen)] [bold? (ghostty:style-bold? pen)]
          [italic? (ghostty:style-italic? pen)] [faint? (ghostty:style-faint? pen)]
          [blink? (ghostty:style-blink? pen)] [inverse? (ghostty:style-inverse? pen)]
          [invisible? (ghostty:style-invisible? pen)] [strike? (ghostty:style-strikethrough? pen)]
          [overline? (ghostty:style-overline? pen)] [underline (ghostty:style-underline pen)])
      (for-each
        (lambda (a)
          (let ([v (ghostty:sgr-attribute-value a)])
            (case (ghostty:sgr-attribute-kind a)
              [(unset)
               (set! fg #f) (set! bg #f) (set! uc #f) (set! bold? #f) (set! italic? #f) (set! faint? #f)
               (set! blink? #f) (set! inverse? #f) (set! invisible? #f) (set! strike? #f)
               (set! overline? #f) (set! underline 'none)]
              [(bold) (set! bold? #t)]
              [(reset-bold) (set! bold? #f) (set! faint? #f)]
              [(italic) (set! italic? #t)]
              [(reset-italic) (set! italic? #f)]
              [(faint) (set! faint? #t)]
              [(underline) (set! underline v)]
              [(underline-color underline-color-256) (set! uc v)]
              [(reset-underline-color) (set! uc #f)]
              [(overline) (set! overline? #t)]
              [(reset-overline) (set! overline? #f)]
              [(blink) (set! blink? #t)]
              [(reset-blink) (set! blink? #f)]
              [(inverse) (set! inverse? #t)]
              [(reset-inverse) (set! inverse? #f)]
              [(invisible) (set! invisible? #t)]
              [(reset-invisible) (set! invisible? #f)]
              [(strikethrough) (set! strike? #t)]
              [(reset-strikethrough) (set! strike? #f)]
              [(direct-color-fg fg-8 bright-fg-8 fg-256) (set! fg v)]
              [(direct-color-bg bg-8 bright-bg-8 bg-256) (set! bg v)]
              [(reset-fg) (set! fg #f)]
              [(reset-bg) (set! bg #f)]
              [else (void)])))
        attributes)
      (ghostty:make-style fg bg uc bold? italic? faint? blink? inverse? invisible? strike? overline? underline)))

  ;; An empty parameter is 0, and one past what the parser takes is
  ;; clamped, as a terminal clamps it.
  (define (sgr-parameters s start end)
    (let loop ([i start] [n 0] [numbers '()] [separators '()])
      (if (fx= i end)
          (values (reverse (cons n numbers)) (list->string (reverse (cons #\; separators))))
          (let ([c (string-ref s i)])
            (if (or (char=? c #\;) (char=? c #\:))
                (loop (fx+ i 1) 0 (cons n numbers) (cons c separators))
                (loop (fx+ i 1) (fxmin 65535 (fx+ (fx* n 10) (fx- (char->integer c) 48))) numbers separators))))))

  (define (sgr-parameter-char? c) (or (char<=? #\0 c #\9) (char=? c #\;) (char=? c #\:)))

  (define (sequence-end s from n)
    (let parameters ([i from])
      (cond
        [(fx= i n) 'cut]
        [(char<=? #\x30 (string-ref s i) #\x3F) (parameters (fx+ i 1))]
        [else
         (let intermediates ([i i])
           (cond
             [(fx= i n) 'cut]
             [(char<=? #\x20 (string-ref s i) #\x2F) (intermediates (fx+ i 1))]
             [(char<=? #\x40 (string-ref s i) #\x7E) i]
             [else #f]))])))

  (define (sgr? s from end)
    (and (char=? (string-ref s end) #\m)
         (let loop ([i from])
           (or (fx= i end) (and (sgr-parameter-char? (string-ref s i)) (loop (fx+ i 1)))))))

  (define (filter-of on-text)
    (let ([held ""] [pen plain-style] [value #f])
      (lambda (text)
        (unless (string? text)
          (assertion-violation 'ansi-colors:filter "not a string" text))
        (let* ([s (if (fx= (string-length held) 0) text (string-append held text))] [n (string-length s)])
          (define (emit from to)
            (when (fx< from to) (on-text (substring s from to) value)))
          (set! held "")
          (let loop ([i 0] [from 0])
            (cond
              [(fx= i n) (emit from n)]
              [(not (char=? (string-ref s i) #\esc)) (loop (fx+ i 1) from)]
              [(fx= (fx+ i 1) n) (emit from i) (set! held (substring s i n))]
              [(not (char=? (string-ref s (fx+ i 1)) #\[)) (loop (fx+ i 1) from)]
              [else
               (let ([end (sequence-end s (fx+ i 2) n)])
                 (cond
                   [(eq? end 'cut) (emit from i) (set! held (substring s i n))]
                   [(not end) (loop (fx+ i 1) from)]
                   [else
                    (emit from i)
                    (when (sgr? s (fx+ i 2) end)
                      (let-values ([(numbers separators) (sgr-parameters s (fx+ i 2) end)])
                        (set! pen (apply-attributes pen
                                    (if (fx= end (fx+ i 2)) (ghostty:sgr-parse '()) (ghostty:sgr-parse numbers separators))))
                        (set! value (span-value-of pen default-palette))))
                    (loop (fx+ end 1) (fx+ end 1))]))])))))))

(import %internals)

(define (filter on-text)
  (unless (procedure? on-text)
    (assertion-violation 'ansi-colors:filter "not a procedure" on-text))
  (filter-of on-text))

(define (span-value style palette)
  (unless (ghostty:style? style)
    (assertion-violation 'ansi-colors:span-value "not a style" style))
  (check-palette 'ansi-colors:span-value palette)
  (span-value-of style palette))

(tables:set! views:span-properties 'ansi-colors span-attributes)
(tables:set! web:stylesheets 'ansi-colors "ansi-colors/ansi-colors.css")
