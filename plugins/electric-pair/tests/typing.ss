(import (tuna) (test) (test-user) (options) (hooks) (tables) (buffers) (document) (views) (modes) (syntax) (editing)
        (electric-pair) (sexp-test scene))

(define after sexp-test/scene:after)

(options:set! electric-pair:mode #t)

(test "an opening bracket gets its closing one, the cursor between"
  (check-equal? "a (|)b" (after "a |b" "("))
  (check-equal? "(a (|))" (after "(a |)" "("))
  (check-equal? "a [|]" (after "a |" "[")))

(test "an opening bracket goes in alone when a closing bracket after the cursor has no match"
  (check-equal? "(a (|))" (after "(a |))" "("))
  (check-equal? "a (|)" (after "a |)" "(")))

(test "in Scheme, { is part of a symbol, so it is not paired"
  (check-equal? "a {|" (after "a |" "{")))

(test "a closing bracket types over the closing bracket of the list holding the cursor, past blanks and line breaks"
  (check-equal? "(a )|" (after "(a |)" ")"))
  (check-equal? "(a  )|" (after "(a | )" ")"))
  (check-equal? "(a \n)|" (after "(a |\n)" ")")))

(test "a closing bracket is inserted when a list holding the cursor has no match, at top level, or before another shape"
  (check-equal? "((a )|)" (after "((a |)" ")"))
  (check-equal? "a )|" (after "a |" ")"))
  (check-equal? "(a )|]" (after "(a |]" ")")))

(test "a quote starts a pair, types over the string's closing quote, and in a string starts a pair that splits it"
  (check-equal? "a \"|\"" (after "a |" "\""))
  (check-equal? "\"a\"|" (after "\"a|\"" "\""))
  (check-equal? "\"a \"|\"b\"" (after "\"a |b\"" "\"")))

(test "a quote that only balances the text's strings goes in alone"
  (check-equal? "\"|\"(f \"x\")" (after "|(f \"x\")" "\"")))

(test "in a comment or a string, brackets and quotes pair by their characters"
  (check-equal? "; a (|)" (after "; a |" "("))
  (check-equal? "; a \"|\"" (after "; a |" "\""))
  (check-equal? "\"a (|)\"" (after "\"a |\"" "(")))

(test "a prefix goes in alone"
  (check-equal? "a '|" (after "a |" "'"))
  (check-equal? "a `|" (after "a |" "`")))

(test "C-q inserts a bracket alone"
  (check-equal? "a (|" (after "a |" "C-q (")))

(test "a count inserts that many balanced pairs"
  (check-equal? "a (((|)))" (after "a |" "M-3 (")))

(test "curly quotes pair"
  (check-equal? "a \x2018;|\x2019;" (after "a |" "\x2018;")))

(test "after #\\, a bracket or quote is a character literal, alone"
  (check-equal? "#\\(|" (after "#\\|" "("))
  (check-equal? "#\\\"|" (after "#\\|" "\"")))

(test "in a buffer whose mode has no lexer, nothing pairs"
  (sexp-test/scene:show-in! modes:fundamental "a |")
  (test-user:press! "(")
  (check-equal? "a (|" (sexp-test/scene:shown)))

(test "each cursor pairs"
  (check-equal? "(|) (|)" (after "| |" "(")))

(test "with the mode off in a buffer, a bracket goes in alone"
  (let ([b (sexp-test/scene:show! "a |")])
    (buffers:with-buffer b (options:set-local! electric-pair:mode #f))
    (test-user:press! "(")
    (check-equal? "a (|" (sexp-test/scene:shown))))

(define (before-word next buffer position char)
  (let ([t (document:token (buffers:document buffer) position)])
    (and (not (and (char? t) (char-alphabetic? t))) (next buffer position char))))

(test "advice on electric-pair:pair-typed? decides whether an opening bracket pairs"
  (advice-add! electric-pair:pair-typed? before-word)
  (check-equal? "a (|b" (after "a |b" "("))
  (check-equal? "a (|) b" (after "a | b" "("))
  (advice-remove! electric-pair:pair-typed? before-word))

(hooks:define-hook brace-hook "Called in brace buffers.")

(tables:define-table brace-keymap "Keys in brace buffers.")

(modes:define-major-mode brace-mode (keymap brace-keymap) (hook brace-hook))

;; Chez reads { as part of a symbol, so pairing it needs a language whose
;; lexer reads it as a bracket.
(define (brace-lexer doc)
  (let ([n (document:length doc)] [no-marks (syntax:lexeme-marks)])
    (let loop ([p 0] [depth 0] [acc '()])
      (if (fx>= p n)
          (list->vector (reverse acc))
          (let ([t (document:token doc p)])
            (cond
              [(memv t '(#\( #\{))
               (loop (fx+ p 1) (fx+ depth 1) (cons (syntax:make-lexeme (syntax:class open) p (fx+ p 1) (fx+ depth 1) no-marks) acc))]
              [(memv t '(#\) #\}))
               (loop (fx+ p 1) (fxmax 0 (fx- depth 1)) (cons (syntax:make-lexeme (syntax:class close) p (fx+ p 1) depth no-marks) acc))]
              [(and (char? t) (not (char-whitespace? t)))
               (let run ([q (fx+ p 1)])
                 (let ([u (and (fx< q n) (document:token doc q))])
                   (if (and (char? u) (not (char-whitespace? u)) (not (memv u '(#\( #\{ #\) #\}))))
                       (run (fx+ q 1))
                       (loop q depth (cons (syntax:make-lexeme (syntax:class atom) p q depth no-marks) acc)))))]
              [else (loop (fx+ p 1) depth acc)]))))))

(tables:set! syntax:lexers brace-mode brace-lexer)
(tables:set! syntax:bracket-pairs brace-mode (list (cons #\( #\)) (cons #\{ #\})))

(test "a mode's own bracket pairs pair"
  (sexp-test/scene:show-in! brace-mode "a |")
  (test-user:press! "{")
  (check-equal? "a {|}" (sexp-test/scene:shown)))
