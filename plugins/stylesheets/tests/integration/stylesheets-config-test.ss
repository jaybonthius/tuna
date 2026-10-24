;;; Stylesheets from init.ss: the user's own code adds and replaces
;;; stylesheets with paths relative to init.ss, wins over themes, and a
;;; reload that reorders the declarations reorders the page.
(import :std/misc/ports
        :std/source
        :std/test
        :tuna/kernel
        :tuna/boot
        (except-in :tuna/configuration activate-plugin!)
        :tuna/plugins/stylesheets/contract
        "../../../../tuna/tests/support/kernel")
(export stylesheets-config-test)

(def styled-module
  (path-expand "../support/styled" (path-expand (this-source-directory))))

(def (call-with-temporary-directory proc)
  (let (directory (path-expand (string-append "tuna-stylesheets-test-"
                                              (number->string (random-integer 1000000000)))
                               (getenv "TMPDIR" "/tmp")))
    (create-directory* directory)
    (try
     (proc directory)
     (finally (delete-file-or-directory directory #t)))))

;; Write DIRECTORY/init.ss: the language line, the imports, then LINES.
(def (write-init (directory : :string) . lines) => :string
  (let (path (path-expand "init.ss" directory))
    (write-file-string
     path
     (string-join (append ["#lang :tuna/config"
                           (string-append "(import :tuna/plugins/stylesheets/contract \""
                                          styled-module "\")")]
                          lines)
                  "\n"))
    path))

;; The page as (owner name file replaced-by).
(def (page)
  (map (lambda (s)
         [(stylesheet-owner s) (stylesheet-name s)
          (path-strip-directory (stylesheet-path s)) (stylesheet-replaced-by s)])
       (page-stylesheets)))

(def stylesheets-config-test
  (test-suite "stylesheets from init.ss"
    (test-case "init.ss adds and replaces stylesheets relative to itself, after every plugin and theme"
      (call-with-temporary-directory
       (lambda (directory)
         (write-file-string (path-expand "mine.css" directory) ".mine { color: red; }\n")
         (write-file-string (path-expand "my-rules.css" directory) ".a { color: orange; }\n")
         (let (path (write-init directory
                                "(use-plugin styled-a)"
                                "(use-plugin theme)"
                                "(use-plugin styled-b)"
                                "(add-stylesheet 'mine \"mine.css\")"
                                "(replace-stylesheet 'styled-a 'rules \"my-rules.css\")"))
           (call-with-fresh-kernel []
             (lambda ()
               (check (startup-report-problem
                       (start-from-configuration (make-config-choice path "--config")))
                      => #f)
               (check (page) => '((styled-a tokens "a-tokens.css" #f)
                                  (styled-a rules "my-rules.css" init)
                                  (init mine "mine.css" #f)))
               (let (mine (find (lambda (s) (eq? (stylesheet-name s) 'mine)) (page-stylesheets)))
                 (check (stylesheet-path mine) => (path-expand "mine.css" directory))
                 (check (stylesheet-text mine) => ".mine { color: red; }\n"))))))))

    (test-case "a reload that reorders init.ss reorders the page"
      (call-with-temporary-directory
       (lambda (directory)
         (let (path (write-init directory "(use-plugin styled-a)" "(use-plugin styled-b)"))
           (call-with-fresh-kernel []
             (lambda ()
               (start-from-configuration (make-config-choice path "--config"))
               (check (map car (page)) => '(styled-a styled-a styled-b))
               (let (generation (stylesheets-generation))
                 (write-init directory "(use-plugin styled-b)" "(use-plugin styled-a)")
                 (check (reload-succeeded? (reload-configuration!)) => #t)
                 (check (map car (page)) => '(styled-b styled-a styled-a))
                 (check (= (stylesheets-generation) generation) => #f))))))))

    (test-case "evaluated code without a source file needs an absolute path"
      (call-with-temporary-directory
       (lambda (directory)
         (let ((path (write-init directory))
               (css (path-expand "evaluated.css" directory)))
           (write-file-string css ".e { color: red; }\n")
           (call-with-fresh-kernel []
             (lambda ()
               (start-from-configuration (make-config-choice path "--config"))
               (check-exception (evaluate-form '(add-stylesheet 'evaluated "evaluated.css")) error?)
               (evaluate-form `(add-stylesheet 'evaluated ,css))
               (check (page) => '((session-owner evaluated "evaluated.css" #f)))))))))))
