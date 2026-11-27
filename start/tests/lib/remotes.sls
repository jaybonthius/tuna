#!tuna
(import (fixtures))

(define %made '())

(define (commits name)
  (let ([found (assoc name %made)])
    (if found
        (cdr found)
        (let ([made (%make! name)])
          (set! %made (cons (cons name made) %made))
          made))))

(define (url name) (commits name) (fixtures:remote-url name))

(define (main name forms) (list (cons (format "src/~a.sls" name) (fixtures:module-text forms))))

(define (%make! name)
  (case name
    [("compat")
     (list (fixtures:commit! name (main "compat" '((define (who) "upstream compat") (define (buffer) "compat buffer")))))]
    [("compat-fork")
     (list (fixtures:commit! name (main "compat" '((define (who) "bob's compat") (define (buffer) "bob's compat buffer")))))]
    [("consult")
     (list (fixtures:commit! name (main "consult" '((import (compat)) (define (buffer) (compat:buffer))))))]
    [("embark")
     (fixtures:commits! name
       (map (lambda (version)
              (append
                (main "embark" '((import (options)) (define (act) "embark act") (options:define-option integrated #f boolean?)))
                (list (cons "embark-consult/src/embark-consult.sls"
                            (fixtures:module-text
                              `((import (embark) (consult) (options))
                                (define (version) ,version)
                                (options:set! embark:integrated #t)))))))
            '("first" "newest")))]
    [("sources")
     (list (fixtures:commit! name
             (main "sources"
               `((import)
                 (plugin compat (git ,(url "compat")))
                 (plugin consult (git ,(url "consult")))
                 (plugin embark (git ,(url "embark")))
                 (plugin embark-consult (git ,(url "embark")) (dir "embark-consult"))))))]
    [("vertico")
     (let* ([main-commit (fixtures:commit! name (main "vertico" '((import (options)) (options:define-option count 10 fixnum?))))]
            [dev-commit (fixtures:commit! name (main "vertico" '((import (options)) (options:define-option count 20 fixnum?))) "dev")])
       ;; A clone checks out the branch the repository has checked out.
       (fixtures:git! (fixtures:remote-folder name) "checkout" "-q" "main")
       (list main-commit dev-commit))]
    [("spell")
     (fixtures:commits! name
       (map (lambda (folder)
              (main "spell"
                `((import (hooks) (options))
                  (options:define-option language "en" string? "Dictionary used for checking.")
                  (hooks:define-hook checked)
                  (define (dictionary-path) (string-append ,folder (language)))
                  (define (check path) (checked path) (list path (dictionary-path))))))
            '("/usr/share/dict/" "/usr/share/hunspell/")))]
    [("empty")
     (list (fixtures:commit! name (list (cons "src/other.sls" (fixtures:module-text '((define (where) "not the main module")))))))]
    [("flaky")
     (fixtures:commits! name
       (list (main "flaky" '((define (version) 1)))
             (main "flaky" '((define (version) 2) (error 'flaky "broken")))))]
    [("chez-adder")
     (let* ([files (lambda (version)
                     (list (cons "Makefile" "native:\n\t$(SCHEME) -q --script build.ss\n")
                           (cons "build.ss"
                                 (fixtures:forms-text
                                   '((unless (file-directory? "src/adder") (mkdir "src/adder"))
                                     (with-output-to-file "src/adder/built.ss"
                                       (lambda () (write `(define adder-built-with ,(scheme-version))))
                                       'replace))))
                           (cons "src/adder.sls"
                                 (fixtures:forms-text
                                   `((library (adder)
                                       (export adder-sum adder-version adder-built-with)
                                       (import (chezscheme))
                                       (include "adder/built.ss")
                                       (define (adder-sum a b) (+ a b))
                                       (define (adder-version) ,version)))))))]
            [first (fixtures:commit! name (files "1"))]
            [side (fixtures:commit! name (files "2") "side")]
            [third (fixtures:commit! name (files "3") "main")])
       (list first side third))]
    [("chez-twin")
     (list (fixtures:commit! name
             (list (cons "src/adder.sls"
                         (fixtures:forms-text
                           '((library (adder) (export adder-twin) (import (chezscheme)) (define (adder-twin) "twin"))))))))]
    [("chez-extra")
     (list (fixtures:commit! name
             (list (cons "src/extra.sls"
                         (fixtures:forms-text
                           '((library (extra) (export extra) (import (chezscheme)) (define (extra) "extra"))))))))]
    [("chez-modular")
     (list (fixtures:commit! name (main "modular" '((define (name) 'modular)))))]
    [("sum") (list (fixtures:commit! name (adder-user "sum" 0 '((define (total a b) (adder-sum a b))))))]
    [("total") (list (fixtures:commit! name (adder-user "total" 2 '((define (version) (adder-version))))))]
    [("odd") (list (fixtures:commit! name (adder-user "odd" 1 '((define (version) (adder-version))))))]
    [("broken-deps")
     (list (fixtures:commit! name
             (cons (cons "tuna.deps" "(library chez-adder (local \"/tmp\"))\n")
                   (main "broken-deps" '((define (name) 'broken-deps))))))]
    [("uses-extra")
     (list (fixtures:commit! name
             (cons (cons "tuna.deps"
                         (fixtures:forms-text
                           `((library chez-extra (git ,(url "chez-extra")) (commit ,(fixtures:short (car (commits "chez-extra"))))
                               (library-directories ("src" . "build/obj/src")) (build)))))
                   (main "uses-extra" '((define (name) 'uses-extra))))))]
    [else (assertion-violation 'remotes:commits "no such remote" name)]))

(define (adder-line commit)
  `(library chez-adder (git ,(url "chez-adder")) (commit ,(fixtures:short commit))
     (library-directories ("src" . "build/obj/src")) (build "make" "native")))

(define (adder-user name index forms)
  (cons (cons "tuna.deps" (fixtures:forms-text (list (adder-line (list-ref (commits "chez-adder") index)))))
        (main name (cons '(import (adder)) forms))))
