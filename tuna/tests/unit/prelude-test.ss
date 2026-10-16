(import (only-in :std/error contract-violation-error?)
        :std/test
        :std/source
        :std/misc/process
        (only-in :gerbil/expander current-expander-context import-module)
        (only-in :gerbil/runtime/syntax syntax-error?)
        (only-in :tuna/prelude open-definition install-open! redefine)
        "../support/open-functions/target"
        "../support/open-functions/caller")
(export prelude-test)

(def target-module
  (path-expand "../support/open-functions/target.ss" (this-source-directory)))
(def compiled-check
  (path-expand "../support/open-functions/recompile.sh" (this-source-directory)))

;; The same public mechanism used by enter!; private helpers stay private.
(def (evaluate-in-target (form : :t)) => :t
  (parameterize ((current-expander-context (import-module target-module #f #t)))
    (eval form)))

(def prelude-test
  (test-suite "tuna/prelude"
    (test-case "redefine reaches same-module, imported and saved callers"
      (let ((original (open-definition typed)) (saved typed))
        (try
         (check (inside 1) => 2)
         (check (outside 1) => 2)
         (redefine (typed (n : :fixnum)) => :fixnum (fx+ n 10))
         (check (inside 1) => 11)
         (check (outside 1) => 11)
         (check (saved 1) => 11)
         (check ((open-definition typed) 1) => 11)
         (set! typed (lambda ((n : :fixnum)) => :fixnum (fx+ n 20)))
         (check (outside 1) => 21)
         (finally (install-open! typed original)))))
    (test-case "ordinary signatures, local definitions and core-bound macros"
      (check (optional 1) => 3)
      (check (optional 1 4) => 5)
      (check (keyword 1) => 4)
      (check (keyword 1 add: 7) => 8)
      (check (rest 1 2 3) => '(1 2 3))
      (check ((curried 1) 2) => 3)
      (check (local 1) => 2)
      (check (closed 1) => 2)
      (check (foreign-made 1) => 8)
      (check (macro-made 1) => 6)
      (let (count default-count)
        (check (defaulted) => 3)
        (check default-count => (fx1+ count))
        (check (defaulted 9) => 9)
        (check default-count => (fx1+ count)))
      (check (call-with-values multiple-values list) => '(1 2))
      (check {value (make-sample 7)} => 7)
      (check-exception (evaluate-in-target '(open-definition closed)) syntax-error?)
      (check-exception (evaluate-in-target '(open-definition foreign-made)) syntax-error?))
    (test-case "def*, lambda and case-lambda definitions are open"
      (check (clauses) => 0)
      (check (clauses 7) => 7)
      (check (clauses 7 8) => '(7 8))
      (check (case-procedure) => 0)
      (check (case-procedure 7) => 7)
      (let ((original (open-definition clauses))
            (literal (open-definition literal-procedure))
            (cases (open-definition case-procedure))
            (macro (open-definition macro-made)))
        (try
         (install-open! clauses (case-lambda (() 10) ((n) (fx+ n 10)) ((n . ns) (cons n ns))))
         (install-open! literal-procedure (lambda (n) (fx+ n 20)))
         (install-open! case-procedure (case-lambda (() 30) ((n) (fx+ n 30))))
         (install-open! macro-made (lambda (n) (fx+ n 40)))
         (check (clauses) => 10)
         (check (clauses 7) => 17)
         (check (literal-procedure 1) => 21)
         (check (case-procedure) => 30)
         (check (case-procedure 7) => 37)
         (check (macro-made 1) => 41)
         (finally
          (install-open! clauses original)
          (install-open! literal-procedure literal)
          (install-open! case-procedure cases)
          (install-open! macro-made macro)))))
    (test-case "nullable return contracts still reject invalid replacements"
      (let (original (open-definition nullable))
        (try
         (check (nullable 0) => #f)
         (check (nullable 1) => 1)
         (install-open! nullable (lambda (n) "invalid"))
         (check-exception (nullable 1) contract-violation-error?)
         (finally (install-open! nullable original)))))
    (test-case "private module-context redefine resolves private helpers"
      (let ((original (evaluate-in-target '(open-definition secret)))
            (context (current-expander-context)))
        (try
         (check (outside-private 1) => 5)
         (evaluate-in-target '(redefine (secret (n : :fixnum)) => :fixnum (fx+ (helper n) 10)))
         (check (public-call 1) => 14)
         (check (outside-private 1) => 15)
         (check (eq? token (evaluate-in-target 'token)) => #t)
         (check (eq? context (current-expander-context)) => #t)
         (check-exception (evaluate-in-target '(def (secret n) n)) syntax-error?)
         (finally
          ((evaluate-in-target '(lambda (replacement) (install-open! secret replacement))) original)))))
    (test-case "source callers preserve tail calls (ten million compiled below)"
      (check (self-loop 10000) => 0)
      (check (mutual-a 10000) => #t)
      (check (tail-trace 1000000) => (tail-trace 1)))
    (test-case "compiled callers survive target-only recompilation"
      (check (string-contains (run-process ["sh" compiled-check]) "RECOMPILE-STABILITY-PASS") ? integer?))))
