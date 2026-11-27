(import (tuna) (test) (options) (tables) (views) (web) (ansi-colors) (prefix (ghostty) ghostty:))

;; ansi-colors loads web, which listens on 7337 by default; other tests'
;; Tunas may hold it, so this one takes a port of its own before web
;; starts listening, after the batch it loaded in.
(options:set! web:port (+ 20000 (mod (get-process-id) 20000)))

(define (read-stretches . texts)
  (let* ([stretches '()] [filter (ansi-colors:filter (lambda (text value) (set! stretches (cons (cons text value) stretches))))])
    (for-each filter texts)
    (reverse stretches)))

(define palette (ghostty:color-default-palette))

(define (violation thunk)
  (guard (c [(assertion-violation? c) (list (condition-who c) (condition-message c))])
    (thunk)
    'no-violation))

(test "the filter removes control sequences and gives each stretch of text the span value of its style, or #f for plain text"
  (check-equal? '(("failed" (face . ansi-colors.red) (ansi-colors ("bold"))) (": 2 tests" . #f))
    (read-stretches "\x1b;[1;31mfailed\x1b;[0m: 2 tests")))

(test "a stretch's value is what ansi-colors:span-value gives the style a terminal's pen would have"
  (check-equal? (ansi-colors:span-value (ghostty:make-style 1 #f #f #t #f #f #f #f #f #f #f 'none) palette)
    (cdar (read-stretches "\x1b;[1;31mx"))))

(test "each reset ends the style, ESC [ m being ESC [ 0 m"
  (check-equal? '(("a" (face . ansi-colors.green) (ansi-colors ("bold"))) ("b" . #f))
    (read-stretches "\x1b;[1;32ma\x1b;[mb")))

(test "direct colours with ; or :, colours 16 to 255 through the default palette, and backgrounds"
  (check-equal? '(("a" (ansi-colors ("fg") ("--ansi-colors-fg" . "#0A141E")))
                  ("b" (ansi-colors ("fg") ("--ansi-colors-fg" . "#0A141E")))
                  ("c" (ansi-colors ("fg") ("--ansi-colors-fg" . "#FF0000")))
                  ("d" (face . ansi-colors.bright-white) (ansi-colors ("bg-4"))))
    (read-stretches "\x1b;[38;2;10;20;30ma\x1b;[0;38:2::10:20:30mb\x1b;[0;38;5;196mc\x1b;[0;44;97md")))

(test "underline styles and their colour, inverse, and the other attributes become words"
  (check-equal? '(("a" (ansi-colors ("underline-curly" "underline-color-1")))
                  ("b" (ansi-colors ("fg-background" "bg-foreground")))
                  ("c" (ansi-colors ("italic" "faint" "invisible" "strike" "overline")))
                  ("d" (ansi-colors ("underline-double"))))
    (read-stretches "\x1b;[4:3;58;5;1ma\x1b;[0;7mb\x1b;[0;2;3;8;9;53mc\x1b;[0;21md")))

(test "the style holds from one string to the next until a sequence changes it, and 22 clears bold and faint"
  (check-equal? '(("a" (face . ansi-colors.red) (ansi-colors ("bold" "faint")))
                  ("b" (face . ansi-colors.red) (ansi-colors ("bold" "faint")))
                  ("c" (face . ansi-colors.red)))
    (read-stretches "\x1b;[1;2;31ma" "b\x1b;[22mc")))

(test "a sequence cut across strings waits for the rest, as does a lone ESC at the end"
  (check-equal? '(("a" . #f) ("b" (face . ansi-colors.red)) ("c" . #f))
    (read-stretches "a\x1b;[3" "1mb\x1b;" "[0mc")))

(test "other control sequences go, and ESC before anything but [ stays in the text"
  (check-equal? '(("x" . #f) ("y" . #f) ("z\x1b;Xw" . #f))
    (read-stretches "x\x1b;[2Ky\x1b;[?25lz\x1b;Xw")))

(test "the filter, its procedure and ansi-colors:span-value check their arguments"
  (check-equal? '(ansi-colors:filter "not a procedure") (violation (lambda () (ansi-colors:filter 'nope))))
  (check-equal? '(ansi-colors:filter "not a string") (violation (lambda () ((ansi-colors:filter (lambda (text value) (void))) 5))))
  (check-equal? '(ansi-colors:span-value "not a style") (violation (lambda () (ansi-colors:span-value 'plain palette)))))

(test "the sixteen colours a program names by number are faces, each a definition whose value is its symbol"
  (check-equal? '(ansi-colors.black ansi-colors.red ansi-colors.green ansi-colors.yellow ansi-colors.blue ansi-colors.magenta
                  ansi-colors.cyan ansi-colors.white ansi-colors.bright-black ansi-colors.bright-red ansi-colors.bright-green
                  ansi-colors.bright-yellow ansi-colors.bright-blue ansi-colors.bright-magenta ansi-colors.bright-cyan
                  ansi-colors.bright-white)
    (list ansi-colors:black ansi-colors:red ansi-colors:green ansi-colors:yellow ansi-colors:blue ansi-colors:magenta
          ansi-colors:cyan ansi-colors:white ansi-colors:bright-black ansi-colors:bright-red ansi-colors:bright-green
          ansi-colors:bright-yellow ansi-colors:bright-blue ansi-colors:bright-magenta ansi-colors:bright-cyan
          ansi-colors:bright-white)))

(define (style foreground background inverse? blink?)
  (ghostty:make-style foreground background #f #f #f #f blink? inverse? #f #f #f 'none))

(test "ansi-colors:span-value gives #f for the plain style and for blink alone, which draws as nothing"
  (check-equal? #f (ansi-colors:span-value (style #f #f #f #f) palette))
  (check-equal? #f (ansi-colors:span-value (style #f #f #f #t) palette)))

(test "ansi-colors:span-value takes colours 16 to 255 from the palette it is given"
  (let ([own (vector-copy palette)])
    (vector-set! own 200 (ghostty:make-rgb 1 2 3))
    (check-equal? '((ansi-colors ("fg") ("--ansi-colors-fg" . "#010203"))) (ansi-colors:span-value (style 200 #f #f #f) own))
    (check-equal? '(ansi-colors:span-value "not a vector of 256 colors")
      (violation (lambda () (ansi-colors:span-value (style 1 #f #f #f) (vector-copy palette 0 16)))))))

(test "inverse swaps the two colours, a default one drawn as the surface's background or text"
  (check-equal? '((ansi-colors ("fg-background" "bg-1"))) (ansi-colors:span-value (style 1 #f #t #f) palette))
  (check-equal? '((face . ansi-colors.green) (ansi-colors ("bg-foreground"))) (ansi-colors:span-value (style #f 2 #t #f) palette)))

(test "the span value's words and properties are drawn as data-ansi-colors and style, and the stylesheet is web's"
  (check-equal? '(("data-ansi-colors" . "fg bold") ("style" . "--ansi-colors-fg:#0A141E;"))
    ((tables:ref views:span-properties 'ansi-colors) '(("fg" "bold") ("--ansi-colors-fg" . "#0A141E"))))
  (check-equal? '(("data-ansi-colors" . "underline-double")) ((tables:ref views:span-properties 'ansi-colors) '(("underline-double"))))
  (check-equal? "ansi-colors/ansi-colors.css" (tables:ref web:stylesheets 'ansi-colors)))
