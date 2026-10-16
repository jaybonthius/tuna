(import :std/test :std/error :std/source :std/list/list
        (only-in :gerbil/runtime/mop slot-ref)
        (only-in :gerbil/expander current-expander-context import-module)
        (only-in :gerbil/runtime/syntax syntax-error?)
        :tuna/kernel
        (only-in :tuna/prelude advise! unadvise! function-advice advised-functions
                 advice-info-owner advice-info-name advice-info-kind advice-info-depth
                 advice-info-source function-advice-info-name function-advice-info-source
                 function-advice-info-advice advice-error? open-definition install-open! redefine)
        "../support/kernel"
        "../support/open-functions/advice-target"
        "../support/open-functions/target"
        "../support/open-functions/caller")
(export advice-test)
(declare (separate))

(def target-path
  (path-expand "../support/open-functions/target.ss" (this-source-directory)))
(defrule (with-advice kind callback body ...)
  (let ()
    (defplugin (advisor ctx) "One composition layer."
      (advise! ctx probe 'test kind callback))
    (call-with-fresh-kernel [advisor] (lambda () body ...))))
(def (probe-values . args) => :list
  (call-with-values (lambda () (apply probe args)) list))
(def (caught (thunk : :procedure)) => :t
  (with-catch values (lambda () (thunk) #f)))
(def (names) => :list
  (map advice-info-name (function-advice-info-advice (function-advice probe))))

(def advice-test
  (test-suite "tuna/lib/advice"
    (test-case "before/after preserve all values and run only on normal return"
      (let (log [])
        (with-advice before: (lambda args (set! log (cons args log)) (values 7 8))
          (check (probe-values 1 2) => '(1 2))
          (check (probe-values) => '())
          (check log => '(() (1 2))))
        (with-advice after: (lambda args (set! log args) (values))
          (check (probe-values 3 4) => '(3 4))
          (check log => '(3 4))))
      (let ((base (open-definition probe)) (ran? #f))
        (try
         (install-open! probe (lambda args (error "body")))
         (with-advice after: (lambda args (set! ran? #t))
           (check (advice-error? (caught (lambda () (probe)))) => #f)
           (check ran? => #f))
         (finally (install-open! probe base)))))
    (test-case "around and override may replace arguments, results and call count"
      (with-advice around: (lambda (original . args) (apply original args))
        (check (probe-values) => '())
        (check (probe-values 1 2) => '(1 2)))
      (with-advice around: (lambda (original n)
                             (values (original (+ n 1)) (original (+ n 2))))
        (check (probe-values 10) => '(11 12)))
      (with-advice override: (lambda args (values 'replacement args))
        (check (probe-values 1 2) => '(replacement (1 2)))))
    (test-case "filter-args receives one list; filter-return receives every value"
      (with-advice filter-args: (lambda (args) (reverse args))
        (check (probe-values 1 2 3) => '(3 2 1)))
      (with-advice filter-return: (lambda results (apply values (reverse results)))
        (check (probe-values 1 2) => '(2 1))
        (check (probe-values) => '()))
      (with-advice filter-return: (lambda results (values))
        (check (probe-values 1 2) => '()))
      (with-advice filter-args: (lambda (args) 'not-a-list)
        (check-exception (probe 1) advice-error?)))
    (test-case "conditional kinds use only #f as false and selected returns keep arity"
      (with-advice before-while: (lambda args #f)
        (check (probe-values 1 2) => '(#f)))
      (with-advice before-while: (lambda args '())
        (check (probe-values 1 2) => '(1 2)))
      (with-advice before-until: (lambda args 0)
        (check (probe-values 1 2) => '(0)))
      (with-advice before-until: (lambda args #f)
        (check (probe-values 1 2) => '(1 2)))
      (with-advice after-while: (lambda args (values 'a 'b))
        (check (probe-values #f) => '(#f))
        (check (probe-values '()) => '(a b)))
      (with-advice after-until: (lambda args (values 'a 'b))
        (check (probe-values 0) => '(0))
        (check (probe-values #f) => '(a b)))
      (with-advice before-while: (lambda args (values 1 2))
        (check-exception (probe 1) advice-error?))
      (with-advice before-until: (lambda args (values))
        (check-exception (probe 1) advice-error?))
      (with-advice after-while: (lambda args 'unreachable)
        (check (caught (lambda () (probe 1 2))) ? exception?))
      (with-advice after-until: (lambda args 'unreachable)
        (check (caught (lambda () (probe))) ? exception?)))
    (test-case "keywords/rest and typed imported callers retain their signatures"
      (defplugin (arguments ctx) "Observe normalized keyword arguments."
        (advise! ctx keyword-probe 'arguments
          filter-args: (lambda (args) (check args => '(1 add: 3)) '(1 add: 8)))
        (advise! ctx typed 'typed around: (lambda (original n) (+ (original n) 10))))
      (let (saved typed)
        (call-with-fresh-kernel [arguments]
          (lambda ()
            (check (keyword-probe 1) => 9)
            (check (outside 1) => 12)
            (check (inside 1) => 12)
            (check (saved 1) => 12))))
      (check (outside 1) => 2))
    (test-case "depth, declaration order and same-owner names determine nesting"
      (let ((owner #f) (log []))
        (defplugin (earlier ctx) "Declared first, activated second."
          (set! owner ctx)
          (advise! ctx probe 'z before: (lambda args (set! log (append log '(z)))))
          (advise! ctx probe 'a before: (lambda args (set! log (append log '(a))))))
        (defplugin (later ctx) "Declared later, activated first."
          (advise! ctx probe 'b before: (lambda args (set! log (append log '(b)))))
          (advise! ctx probe 'outer before: (lambda args (set! log (append log '(outer)))) depth: -1))
        (call-with-fresh-kernel []
          (lambda ()
            (activate-plugin! later order: 20)
            (activate-plugin! earlier order: 10)
            (check (names) => '(outer a z b))
            (check (advice-info-source
                    (car (function-advice-info-advice (function-advice probe)))) ? string?)
            (probe 1)
            (check log => '(outer a z b))
            (deactivate-plugin! earlier)
            (activate-plugin! earlier)
            (check (names) => '(outer a z b))
            (advise! owner probe 'a before: (lambda args (void)))
            (check (names) => '(outer a z b))))))
    (test-case "either deactivation order and explicit removal preserve other owners"
      (for-each
       (lambda (first?)
         (let (owner #f)
           (defplugin (one ctx) "First contributor."
             (set! owner ctx)
             (advise! ctx probe 'same around: (lambda (original n) (+ 10 (original n)))))
           (defplugin (two ctx) "Second contributor."
             (advise! ctx probe 'same around: (lambda (original n) (* 2 (original n)))))
           (call-with-fresh-kernel [one two]
             (lambda ()
               (check (length (names)) => 2)
               (if first?
                 (begin (deactivate-plugin! one) (check (probe 3) => 6))
                 (begin (deactivate-plugin! two) (check (probe 3) => 13)))
               (unadvise! owner probe 'same)
               (check (probe 3) => (if first? 6 3))))))
       '(#t #f))
      (check (names) => '()))
    (test-case "advice follows the shared module, not the selected test kernel"
      (defplugin (shared-definition ctx) "Module-wide contribution."
        (advise! ctx probe 'shared override: (lambda args 'shared)))
      (call-with-fresh-kernel [shared-definition]
        (lambda ()
          (call-with-fresh-kernel [] (lambda () (check (probe 1) => 'shared)))
          (check (probe 1) => 'shared)))
      (check (probe 1) => 1))
    (test-case "same name replacement retains no old callbacks or extra inverses"
      (let (owner #f)
        (defplugin (replacing ctx) "Replace one contribution repeatedly."
          (set! owner ctx)
          (advise! ctx probe 'same override: (lambda args 'old))
          (for-each (lambda (n)
                      (advise! ctx probe 'same override: (lambda args n)))
                    '(1 2 3 4 5)))
        (call-with-fresh-kernel [replacing]
          (lambda ()
            (check (probe 100) => 5)
            (check (names) => '(same))
            (check (length (slot-ref owner 'receipt)) => 2)
            (unadvise! owner probe 'same)
            (check (probe 100) => 100)
            (check (advised-functions) => '())
            (advise! owner probe 'same override: (lambda args 'new))
            (check (length (slot-ref owner 'receipt)) => 2)
            (check (probe) => 'new))))
      (check (names) => '()))
    (test-case "redefine/set! replace only base; removing advice reveals newest definition"
      (let ((base (open-definition typed)) (owner #f) (saved typed))
        (defplugin (redefining ctx) "Keep advice over a new base."
          (set! owner ctx)
          (advise! ctx typed 'plus around: (lambda (original n) (+ 100 (original n)))))
        (try
         (call-with-fresh-kernel [redefining]
           (lambda ()
             (check (eq? base (open-definition typed)) => #t)
             (redefine (typed (n : :fixnum)) => :fixnum (+ n 10))
             (check (saved 1) => 111)
             (set! typed (lambda (n) (+ n 20)))
             (check (outside 1) => 121)
             (check ((open-definition typed) 1) => 21)
             (unadvise! owner typed 'plus)
             (check (saved 1) => 21)))
         (finally (install-open! typed base)))))
    (test-case "named callbacks stay live; closure expressions capture intentionally"
      (let (base (open-definition callback))
        (set! callback-log [])
        (defplugin (named ctx) "Late binding."
          (advise! ctx probe 'named before: callback)
          (let (captured (open-definition callback))
            (advise! ctx probe 'closure before: (lambda args (apply captured args)))))
        (try
         (call-with-fresh-kernel [named]
           (lambda ()
             (redefine (callback . args) => :void
               (set! callback-log (cons 'new callback-log)))
             (probe 1)
             (check callback-log => '(new (1)))))
         (finally (install-open! callback base)))))
    (test-case "callbacks own effects; around-original restores caller context and task"
      (let ((advisor-ctx #f) (caller-ctx #f) (seen #f) (undone? #f))
        (defplugin (advisor ctx) "Own callback effects, not original execution."
          (set! advisor-ctx ctx)
          (advise! ctx probe 'scope around:
            (lambda (original . args)
              (set! seen (current-context))
              (context-defer! (current-context) (lambda () (set! undone? #t)))
              (apply original args))))
        (defplugin (caller ctx) "Caller context."
          (set! caller-ctx ctx))
        (call-with-fresh-kernel [advisor caller]
          (lambda ()
            (call-with-context caller-ctx (lambda () (check (probe 4) => 4)))
            (check (eq? seen advisor-ctx) => #t)
            (check (eq? base-context caller-ctx) => #t)
            (deactivate-plugin! advisor)
            (check undone? => #t)))))
    (test-case "errors name only failing advice; body errors and quits retain identity"
      (let ((body-error (Error "body" where: 'test)) (base (open-definition probe)))
        (try
         (with-advice around: (lambda (original . args) (apply original args))
           (install-open! probe (lambda args (raise body-error)))
           (check (eq? body-error (caught (lambda () (probe)))) => #t))
         (finally (install-open! probe base))))
      (let ((inner-ctx #f) (outer-ctx #f))
        (defplugin (inner ctx) "Fails."
          (set! inner-ctx ctx)
          (advise! ctx probe 'bad before: (lambda args (error "inner")) depth: 10))
        (defplugin (outer ctx) "Forwards."
          (set! outer-ctx ctx)
          (advise! ctx probe 'outer around: (lambda (original . args) (apply original args))))
        (call-with-fresh-kernel [inner outer]
          (lambda ()
            (let (failure (caught (lambda () (probe 1))))
              (check (advice-error? failure) => #t)
              (check (take (Error-irritants failure) 2) => '(inner bad)))
            (advise! inner-ctx probe 'bad before: (lambda args (signal-quit)) depth: 10)
            (check (caught (lambda () (probe 1))) ? quit-condition?)
            (check (names) => '(outer bad)))))
      (with-advice around: (lambda (original . args)
                             (apply original args) (error "own failure"))
        (check (caught (lambda () (probe 1))) ? advice-error?)))
    (test-case "private module target shares state and reports real metadata"
      (let (context (current-expander-context))
        (defplugin (private-path ctx) "Private advice with an absolute module path."
          (parameterize ((current-expander-context (import-module ':tuna/prelude #f #t)))
            ((eval `(lambda (ctx)
                      (advise! ctx (function ,target-path secret) 'private
                        around: (lambda (original n) (+ 10 (original n))) depth: -2))) ctx)))
        (call-with-fresh-kernel [private-path]
          (lambda ()
            (check (outside-private 1) => 15)
            (check (eq? context (current-expander-context)) => #t)
            (let* ((info (car (advised-functions)))
                   (record (car (function-advice-info-advice info))))
              (check (function-advice-info-name info) => 'secret)
              (check (function-advice-info-source info) ? string?)
              (check (advice-info-owner record) => 'private-path)
              (check (advice-info-name record) => 'private)
              (check (advice-info-kind record) => 'around)
              (check (advice-info-depth record) => -2))
            (parameterize ((current-expander-context (import-module target-path #f #t)))
              (check (eq? token (eval 'token)) => #t)
              (check-exception (eval '(function-advice closed)) syntax-error?)))))
      (check (advised-functions) => '()))))
