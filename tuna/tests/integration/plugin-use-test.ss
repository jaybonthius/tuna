;;; The configuration gate checks package imports, not runtime callers.
(import :std/misc/ports :std/test
        :tuna/kernel :tuna/boot :tuna/lib/configuration
        (except-in :tuna/configuration activate-plugin!)
        "../support/kernel")
(export plugin-use-test)

(def (with-package (body : :procedure)) => :t
  (let (directory (path-expand (string-append "tuna-declared-use-"
                                (number->string (random-integer 1000000000))) "/tmp"))
    (create-directory* (path-expand "private" directory))
    (try
     (write-file-string (path-expand "gerbil.pkg" directory)
       (string-append "(package: third-party/ledger-" (path-strip-directory directory) ")"))
     ;; Neither the package prefix nor this contract's filename is Tuna's.
     (write-file-string (path-expand "vocabulary.ss" directory)
       "(import :tuna/kernel)\n(export ledger-service token)\n(def token 'token)\n(def ledger-service (new-service 'ledger (lambda (x) #t) tier: 'live doc: \"Ledger\"))")
     (write-file-string (path-expand "private/helper.ss" directory)
       "(import (only-in \"../vocabulary\" token))\n(export helper)\n(def (helper) token)")
     (write-file-string (path-expand "extension.ss" directory)
       "(import :tuna/kernel (only-in \"vocabulary\" ledger-service) \"private/helper\")\n(export wrong correct required provider new-wrong)\n(def (new-wrong) (defplugin made-wrong \"Factory plugin\") made-wrong)\n(defplugin wrong \"Missing ledger\")\n(defplugin correct \"Declared ledger\" optional: [ledger-service] (helper))\n(defplugin required \"Required ledger\" requires: [ledger-service])\n(defplugin provider \"Provided ledger\" provides: [ledger-service] (context-provide! (current-context) ledger-service 'ledger))")
     ;; This module's direct imports contain no service contract.
     (write-file-string (path-expand "indirect.ss" directory)
       "(import :tuna/kernel \"private/helper\")\n(export indirect)\n(defplugin indirect \"Private imports count\" (helper))")
     (body directory)
     (finally (delete-file-or-directory directory #t)))))

(def (write-config (directory : :string) (body : :string)) => :string
  (let (path (path-expand "init.ss" directory))
    (write-file-string path
      (string-append "#lang :tuna/config ; configuration language with a trailing comment\n(import :tuna/kernel (except-in :tuna/configuration activate-plugin!) \"extension\" \"indirect\" \"vocabulary\")\n" body))
    path))

(def (start (path : :string)) => startup-report
  (start-from-configuration (make-config-choice path "--config")))

(def (status (report : startup-report) (name : :string)) => :symbol
  (report-entry-status (find (lambda ((e : report-entry)) (equal? name (report-entry-what e)))
                            (startup-report-entries report))))

(def (contains? (text : :string) (part : :string)) => :boolean
  (and (string-contains text part) #t))

(def (raised-text (body : :procedure)) => (Maybe :string)
  (with-catch exception-summary (lambda () (body) #f)))

(def (with-config (text : :string) (body : :procedure)) => :t
  (with-package
   (lambda (directory)
     (let (path (write-config directory text))
       (call-with-fresh-kernel [] (lambda () (body path)))))))

(def plugin-use-test
  (test-suite "declared imports at configuration activation"
    (test-case "third-party violations fail alone; required optional and provided declarations pass"
      (with-config
       "(use-plugin wrong)\n(use-plugin correct)\n(use-plugin required)\n(use-plugin provider)"
       (lambda ((path : :string))
         (let* ((report (start path)) (text (startup-report-text report)))
           (check (status report "wrong") => 'failed)
           (check (status report "correct") => 'on)
           (check (status report "required") => 'on)
           (check (status report "provider") => 'on)
           (check (contains? text "wrong imports third-party/ledger-") => #t)
           (check (contains? text "/vocabulary but does not declare ledger-service") => #t)))))

    (test-case "private module imports count, including filtered vocabulary-only imports"
      (with-config "(use-plugin indirect)"
        (lambda ((path : :string))
          (check (contains? (check-configuration (make-config-choice path "--config"))
                            "indirect imports third-party/ledger-") => #t)
          (check (status (start path) "indirect") => 'failed))))

    (test-case "init.ss and config blocks are user code and stay exempt"
      (with-config
       "(use-plugin provider)\n(use-plugin correct config: (service-provider ledger-service))\n(service-provider ledger-service)"
       (lambda ((path : :string))
         (check (check-configuration (make-config-choice path "--config")) => #f)
         (let (report (start path))
           (check (status report "config: block of correct") => 'on)
           (check (status report "your own code (plugin init)") => 'on)))))

    (test-case "reload refuses a newly declared invalid plugin"
      (with-config "(use-plugin correct)"
        (lambda ((path : :string))
          (start path)
          (write-file-string path (string-append (read-file-string path) "\n(use-plugin wrong)"))
          (let (text (reload-report-text (reload-configuration!)))
            (check (contains? text "failed   wrong") => #t)
            (check (contains? text "does not declare ledger-service") => #t)))))

    (test-case "evaluated activation uses the gate and a refused swap leaves the owner on"
      (with-config "(use-plugin correct)"
        (lambda ((path : :string))
          (start path)
          (check (contains? (raised-text (lambda () (evaluate-form '(activate-plugin! wrong))))
                            "does not declare ledger-service") => #t)
          (check (contains? (raised-text (lambda () (evaluate-form '(swap-plugins correct indirect))))
                            "does not declare ledger-service") => #t)
          (check (evaluate-form '(plugin-active? correct)) => #t)
          (check (evaluate-form '(plugin-active? wrong)) => #f)
          (check (contains? (raised-text (lambda () (evaluate-form '(activate-plugin! (new-wrong)))))
                            "does not declare ledger-service") => #t)
          (evaluate-forms '((deactivate-plugin! correct) (activate-plugin! correct)))
          (check (evaluate-form '(plugin-active? correct)) => #t)
          (delete-file (path-expand "extension.ss" (path-directory path)))
          (check (contains? (raised-text (lambda () (evaluate-form '(activate-plugin! wrong))))
                            "no source package found for plugin wrong") => #t))))))
