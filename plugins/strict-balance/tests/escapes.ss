(import (tuna) (test) (test-user) (options) (views) (editing) (strict-balance) (editing-test scene) (sexp-test scene))

(define after sexp-test/scene:after)

(options:set! strict-balance:mode #t)

(test "an escape typed before a string's closing quote goes in with the next key's character"
  (check-equal? "(display \"~a\\n|\")" (after "(display \"~a|\")" "\\ n")))

(test "an escape typed after # goes in with the next key's character, even a bracket"
  (check-equal? "'(#\\space #\\t|)" (after "'(#\\space #|)" "\\ t"))
  (check-equal? "(f #\\(|)" (after "(f #|)" "\\ (")))

(test "an escape followed by a key that types no character inserts nothing"
  (check-equal? "(f #|)" (after "(f #|)" "\\ <f1>")))

(test "DEL and C-d on either half of an escape in an atom take both"
  (check-equal? "(f #|)" (after "(f #\\a|)" "DEL"))
  (check-equal? "(f #|)" (after "(f #\\|a)" "C-d"))
  (check-equal? "(f #|)" (after "(f #\\|a)" "DEL"))
  (check-equal? "(f #|)" (after "(f #|\\a)" "C-d")))

(test "an escape typed in a comment goes in alone"
  (check-equal? "; a \\|" (after "; a |" "\\")))

(test ") after a character literal of a blank keeps the blank"
  (check-equal? "(eqv? c #\\ )|" (after "(eqv? c #\\ |)" ")"))
  (check-equal? "(a #\\ )|" (after "(a #\\ |" ")")))

(test "\" typed between an escape and its character in a string goes after the character"
  (check-equal? "(f \"a\\n\\\"|b\")" (after "(f \"a\\|nb\")" "\"")))

(test "an escape inside a string followed by a key that types no character inserts nothing"
  (check-equal? "\"a|b\"" (after "\"a|b\"" "\\ <f1>")))
