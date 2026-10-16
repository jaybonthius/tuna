prelude: :gerbil/core
(import :std/test :std/error :std/list/list :std/source
        (only-in :gerbil/expander current-expander-context import-module)
        (only-in :gerbil/runtime/syntax syntax-error?)
        :tuna/kernel :tuna/lib/advice
        (only-in :tuna/prelude advise! unadvise! advice-for)
        "../support/kernel"
        "../support/open-functions/command-advice"
        "../support/open-functions/command-caller")
(export advice-target-test)

(def advice-target-test
  (test-suite "tuna/lib/advice shared targets"
    (test-case "use-site add/remove/inspect coexist with command record and private helpers"
      (let ((owner #f) (selected (advice-for (command fixture))))
        (defplugin (router-owner ctx) "Exercise all routes."
          (set! owner ctx)
          (advise! ctx (command fixture) 'route
            filter-return: (lambda results (apply values (reverse results))) depth: -3))
        (call-with-fresh-kernel [router-owner]
          (lambda ()
            (check (command-name (make-command 'record)) => 'record)
            (check (call-with-values (lambda () (fixture-result 1 2)) list) => '(2 1))
            (let* ((info (advice-for (command fixture)))
                   (record (car (advice-target-info-advice info))))
              (check (advice-target-info-kind info) => 'command)
              (check (advice-target-info-name info) => 'fixture)
              (check (advice-target-info-source info) => "command-advice fixture")
              (check (eq? (advice-target-info-identity info)
                          (advice-target-info-identity selected)) => #t)
              (check (advice-info-kind record) => 'filter-return)
              (check (advice-info-depth record) => -3)
              (check (advice-info-source record) ? string?))
            (check (advised-functions) => '())
            (unadvise! owner (command fixture) 'route)
            (check (advice-target-info-advice (advice-for (command fixture))) => '())
            (check (fixture-result 3) => 3)
            (install-fixture-advice! owner)
            (check (fixture-result 3) => 13)
            (check (map advice-info-name (advice-target-info-advice (fixture-advice))) => '(compiled))
            (remove-fixture-advice! owner)
            (check (fixture-result 3) => 3)
            ;; Register again so receipt cleanup, not just explicit removal, is proved.
            (install-fixture-advice! owner)))
        (check (fixture-result 3) => 3)
        (check (eq? (advice-target-info-identity selected)
                    (advice-target-info-identity (fixture-advice))) => #t)))
    (test-case "local add/remove/inspect bindings cannot capture source route controls"
      (parameterize ((current-expander-context
                      (import-module
                       (path-expand "../support/open-functions/command-caller.ss"
                                    (this-source-directory)) #f #t)))
        (let* ((forms
                '((lambda (ctx)
                    (let ((add #f) (remove #f) (inspect #f))
                      (advise! ctx (command fixture) 'shadowed
                        around: (lambda (original n) (+ 20 (original n))))))
                  (lambda (ctx)
                    (let ((add #f) (remove #f) (inspect #f))
                      (advice-for (command fixture))))
                  (lambda (ctx)
                    (let ((add #f) (remove #f) (inspect #f))
                      (unadvise! ctx (command fixture) 'shadowed)))))
               (routes (map (lambda (form) (with-catch values (lambda () (eval form)))) forms)))
          (check (map procedure? routes) => '(#t #t #t))
          (when (every procedure? routes)
            (let (owner #f)
              (defplugin (shadowed-source-owner ctx) "Source routes under colliding local bindings."
                (set! owner ctx))
              (call-with-fresh-kernel [shadowed-source-owner]
                (lambda ()
                  ((car routes) owner)
                  (check (fixture-result 2) => 22)
                  (check (map advice-info-name
                              (advice-target-info-advice ((cadr routes) owner))) => '(shadowed))
                  ((caddr routes) owner)
                  (check (fixture-result 2) => 2))))))))
    (test-case "missing commands contract fails clearly for every route"
      (parameterize ((current-expander-context (import-module ':tuna/prelude #f #t)))
        (for-each
         (lambda (form)
           (let (failure (with-catch values (lambda () (eval form) #f)))
             (check failure ? syntax-error?)
             (check (string-contains (error-message failure)
                      "Command advice requires importing command-advice-target without renaming") ? integer?)))
         '((advise! #f (command fixture) 'missing before: (lambda args (void)))
           (unadvise! #f (command fixture) 'missing)
           (advice-for (command fixture))))))
    (test-case "one shared state recomposes multiple bases and absent targets on mutation"
      (let* ((bases [values (lambda (n) (+ n 1))])
             (effective bases)
             (state (new-advice-state 'service 'read #f
                      (lambda (records)
                        (set! effective (map (lambda (base) (compose-advice base records)) bases)))))
             (owner #f)
             (identity (advice-target-info-identity (inspect-advice state))))
        (defplugin (shared-owner ctx) "Replace, remove and retain composition over absence."
          (set! owner ctx)
          (register-advice! ctx state 'plus 'around (lambda (original n) (+ 10 (original n)))))
        (call-with-fresh-kernel [shared-owner]
          (lambda ()
            (check (map (lambda (f) (f 1)) effective) => '(11 12))
            (check (advised-functions) => '())
            (set! bases [])
            (refresh-advice!)
            (check effective => '())
            (check (map advice-info-name (advice-state-records state)) => '(plus))
            (set! bases [(lambda (n) (+ n 100))])
            (refresh-advice!)
            (check ((car effective) 1) => 111)
            (register-advice! owner state 'plus 'around (lambda (original n) (+ 20 (original n))))
            (check ((car effective) 1) => 121)
            (remove-advice! owner state 'plus)
            (check (eq? (car effective) (car bases)) => #t)
            (check (advice-state-records state) => '())
            (register-advice! owner state 'plus 'before (lambda args (void)))))
        (check (eq? (car effective) (car bases)) => #t)
        (check (advice-state-records state) => '())
        (check (eq? identity (advice-target-info-identity (inspect-advice state))) => #t)))
    (test-case "rank refresh and exact owner cleanup reach command and service states"
      (let* ((effective values)
             (state (new-advice-state 'service 'read #f
                      (lambda (records) (set! effective (compose-advice values records))))))
        (defplugin (earlier ctx) "First declaration."
          (advise! ctx (command fixture) 'earlier around: (lambda (original n) (+ 1 (original n))))
          (register-advice! ctx state 'earlier 'around (lambda (original n) (+ 1 (original n)))))
        (defplugin (later ctx) "Second declaration."
          (advise! ctx (command fixture) 'later around: (lambda (original n) (* 2 (original n))))
          (register-advice! ctx state 'later 'around (lambda (original n) (* 2 (original n)))))
        (call-with-fresh-kernel []
          (lambda ()
            (activate-plugin! earlier order: 1)
            (activate-plugin! later order: 2)
            (check (fixture-result 3) => 7)
            (check (effective 3) => 7)
            (set-plugin-order! earlier 3)
            (check (map advice-info-name (advice-target-info-advice (fixture-advice))) => '(earlier later))
            (check (effective 3) => 7)
            (refresh-advice!)
            (check (map advice-info-name (advice-target-info-advice (fixture-advice))) => '(later earlier))
            (check (fixture-result 3) => 8)
            (check (effective 3) => 8)
            (deactivate-plugin! earlier)
            (check (fixture-result 3) => 6)
            (check (effective 3) => 6)
            (deactivate-plugin! later)
            (check (fixture-result 3) => 3)
            (check (eq? effective values) => #t)))))
    (test-case "identical labels are not selection identities"
      (let ((a (new-advice-state 'command 'same #f void))
            (b (new-advice-state 'command 'same #f void)))
        (check (eq? (advice-target-info-identity (inspect-advice a))
                    (advice-target-info-identity (inspect-advice b))) => #f)))))
