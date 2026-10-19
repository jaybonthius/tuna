;;; The real plugins' stylesheets, started from the starter and demo
;;; configurations: every file loads without a warning, the page lists
;;; them in init.ss order, and every var() without a fallback names a
;;; property some stylesheet on the page defines. Each start runs with its
;;; XDG directories in a temporary directory, so no real session is read
;;; or written.
(import :std/misc/ports
        :std/source
        :std/test
        :tuna/kernel
        :tuna/boot
        :tuna/plugins/stylesheets/contract
        :tuna/plugins/stylesheets-help/plugin
        "../../tuna/tests/support/kernel")
(export stylesheets-test)

(def repository-directory
  (path-expand "../../" (path-expand (this-source-directory))))

(def xdg-variables
  '("XDG_CONFIG_HOME" "XDG_STATE_HOME" "XDG_CACHE_HOME" "XDG_DATA_HOME" "XDG_RUNTIME_DIR"))

;; Run (PROC directory) with every XDG directory inside a fresh temporary
;; directory, and the variables restored afterwards.
(def (call-with-isolated-xdg (proc : :procedure))
  (let ((directory (path-expand (string-append "tuna-stylesheets-test-"
                                               (number->string (random-integer 1000000000)))
                                (getenv "TMPDIR" "/tmp")))
        (saved (map (lambda (name) (cons name (getenv name #f))) xdg-variables)))
    (try
     (for-each (lambda (name)
                 (let (path (path-expand name directory))
                   (create-directory* path)
                   (setenv name path)))
               xdg-variables)
     (proc directory)
     (finally
      (for-each (lambda (b) (if (cdr b) (setenv (car b) (cdr b)) (setenv (car b)))) saved)
      (delete-file-or-directory directory #t)))))

;; Start Tuna from the init.ss at PATH in a fresh kernel and run THUNK.
(def (with-configuration (path : :string) (thunk : :procedure))
  (call-with-isolated-xdg
   (lambda (directory)
     (call-with-fresh-kernel []
       (lambda ()
         (check (startup-report-problem
                 (start-from-configuration (make-config-choice path "--config")))
                => #f)
         (thunk))))))

;; The page as (owner name).
(def (page)
  (map (lambda (s) [(stylesheet-owner s) (stylesheet-name s)]) (stylesheets)))

(def (check-clean-page)
  (check (filter-map (lambda (s) (stylesheet-warning s)) (stylesheets)) => [])
  (check (stylesheet-warnings) => []))

(def starter-page
  '((design-tokens tokens)
    (web-transport tokens) (web-transport rules)
    (layout tokens) (layout rules)
    (html-renderer tokens) (html-renderer rules)
    (buttons rules)
    (minibuffer rules)
    (completion-vertical tokens) (completion-vertical rules)
    (echo-area rules)
    (help-buffer rules)))

(def stylesheets-test
  (test-suite "the real plugins' stylesheets"
    (test-case "the starter's stylesheets load, in init.ss order, with every var() defined"
      (with-configuration (path-expand "starter/init.ss" repository-directory)
        (lambda ()
          (check (page) => starter-page)
          (check-clean-page))))

    (test-case "the demo's stylesheets, fixtures' included, load with every var() defined"
      (with-configuration (path-expand "demo/init.ss" repository-directory)
        (lambda ()
          (check (page) => (append starter-page
                                   '((digit-highlighter rules) (tree-buffer rules))))
          (check-clean-page))))))
