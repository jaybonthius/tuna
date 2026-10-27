;;; The real plugins' stylesheets, started from the starter and demo
;;; configurations: every file loads without a warning, the page lists
;;; them in init.ss order, and every var() without a fallback names a
;;; property some stylesheet on the page defines. A theme
;;; (tests/support/theme-terminal.ss) and init.ss replace real plugins'
;;; files, init.ss wins, and turning the theme off restores the plugins'
;;; own. Each start runs with its XDG directories in a temporary
;;; directory, so no real session is read or written.
(import :std/misc/ports
        :std/source
        :std/test
        :tuna/kernel
        :tuna/boot
        :tuna/plugins/stylesheets/contract
        (only-in :tuna/plugins/help/describe-stylesheets stylesheet-warnings)
        "../../tuna/tests/support/kernel"
        "../support/theme-terminal")
(export stylesheets-test)

(def repository-directory
  (path-normalize (path-expand "../../" (path-expand (this-source-directory)))))

(def theme-module
  (path-expand "tests/support/theme-terminal" repository-directory))

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
  (map (lambda (s) [(stylesheet-owner s) (stylesheet-name s)]) (page-stylesheets)))

;; The stylesheet in slot (OWNER NAME) as (replaced-by path), the path
;; relative to the repository, or to init.ss's directory DIRECTORY.
(def (slot (owner : :symbol) (name : :symbol) (directory : :string))
  (let* ((s (find (lambda (s) (and (eq? (stylesheet-owner s) owner) (eq? (stylesheet-name s) name)))
                  (page-stylesheets)))
         (path (stylesheet-path s)))
    [(stylesheet-replaced-by s)
     (cond
      ((string-prefix? directory path) (substring path (string-length directory) (string-length path)))
      ((string-prefix? repository-directory path)
       (substring path (string-length repository-directory) (string-length path)))
      (else path))]))

;; Completion's semantic tokens, all of them, as init.ss replaces the file.
(def my-completion-tokens
  ":root {
  --completion-muted: GrayText;
  --completion-selected-background: Mark;
  --completion-selected-foreground: CanvasText;
  --completion-selected-border: Mark;
  --completion-focus-ring: Highlight;
  --completion-match-foreground: LinkText;
  --completion-row-radius: 0;
  --completion-row-padding: 0;
  --completion-group-font: inherit;
  --completion-list-max-size: 50dvh;
}
")

(def (check-clean-page)
  (check (filter-map (lambda (s) (stylesheet-warning s)) (page-stylesheets)) => [])
  (check (stylesheet-warnings) => []))

(def starter-page
  '((stylesheets tokens)
    (web-transport tokens) (web-transport rules)
    (terminals tokens) (terminals rules)
    (layout tokens) (layout rules)
    (html-renderer tokens) (html-renderer rules)
    (buttons rules)
    (minibuffer rules)
    (completion-list tokens) (completion-list rules)
    (files rules)
    (echo-area rules)
    (help rules)))

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
                                   '((digit-highlighter rules) (tree-buffer rules) (rows-demo rules) (mixed-demo rules)
                                     (proced tokens) (proced rules))))
          (check-clean-page))))

    (test-case "init.ss and a theme replace real plugins' files; turning the theme off restores them"
      (call-with-isolated-xdg
       (lambda (directory)
         (let ((init (path-expand "init.ss" directory))
               (prefix (string-append (path-expand directory) "/")))
           (write-file-string (path-expand "my-completion.css" directory) my-completion-tokens)
           (write-file-string
            init
            (string-join [(read-file-string (path-expand "starter/init.ss" repository-directory))
                          (string-append "(import \"" theme-module "\")")
                          "(use-plugin theme-terminal)"
                          "(replace-stylesheet 'completion-list 'tokens \"my-completion.css\")"
                          ""]
                         "\n"))
           (call-with-fresh-kernel []
             (lambda ()
               (check (startup-report-problem
                       (start-from-configuration (make-config-choice init "--config")))
                      => #f)
               (check (page) => starter-page)
               (check (slot 'html-renderer 'tokens prefix)
                      => '(theme-terminal "tests/support/theme-terminal/renderer.css"))
               (check (slot 'layout 'rules prefix)
                      => '(theme-terminal "tests/support/theme-terminal/layout.css"))
               (check (slot 'completion-list 'tokens prefix) => '(init "my-completion.css"))
               (check-clean-page)
               (deactivate-plugin! theme-terminal)
               (check (page) => starter-page)
               (check (slot 'html-renderer 'tokens prefix) => '(#f "plugins/renderer/tokens.css"))
               (check (slot 'layout 'rules prefix) => '(#f "plugins/layout/rules.css"))
               (check (slot 'web-transport 'tokens prefix) => '(#f "plugins/web/tokens.css"))
               (check (slot 'completion-list 'tokens prefix) => '(init "my-completion.css"))
               (check-clean-page)))))))))
