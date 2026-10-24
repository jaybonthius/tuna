;;; The help plugin's describe-stylesheets and reload-stylesheets: the
;;; page in order with owners, files and replacements; the replacement
;;; check; the var() check; rereading; and one echo-area line when a check
;;; fails. The lines about the stylesheets of the plugins help needs
;;; (layout, help-buffer) are left out of what is checked.
prelude: :gerbil/core
(import :std/interface
        :std/misc/ports
        :std/test
        :tuna/kernel
        :tuna/plugins/stylesheets/contract
        :tuna/plugins/commands/contract
        :tuna/plugins/help/contract
        :tuna/plugins/keys/plugin
        :tuna/plugins/text-store/plugin
        :tuna/plugins/settings/plugin
        :tuna/plugins/buffers/plugin
        :tuna/plugins/layout/plugin
        :tuna/plugins/help/plugin
        "../../../../tuna/tests/support/kernel"
        (only-in "../../../../tuna/tests/support/string-input" test-messages current-message)
        "../../../commands/tests/support/toy-commands"
        "../../../session/tests/support/session"
        "../../../stylesheets/tests/support/styled")
(export describe-stylesheets-test)

(def help-plugins
  [test-messages toy-commands keys rope-text-store settings no-session buffers layout help-buffer])

;; A stylesheet file the test writes, and the plugin that adds it.
(def written-file (make-parameter #f))

(defplugin (written ctx) "Adds the written file."
  (add-stylesheet ctx 'rules (written-file)))

(def (with-help (plugins : :list) (body : :procedure)) => :t
  (call-with-fresh-kernel (append help-plugins plugins) body))

(def (call-with-written-file (css : :string) (body : :procedure)) => :t
  (let (path (path-expand (string-append "tuna-describe-stylesheets-"
                                         (number->string (random-integer 1000000000)) ".css")
                          (getenv "TMPDIR" "/tmp")))
    (write-file-string path css)
    (try
     (parameterize ((written-file path)) (body path))
     (finally (when (file-exists? path) (delete-file path))))))

(def (help-lines) => :list
  (check (help-output-title (current-help)) => "Stylesheets")
  (filter (lambda ((line : :string))
            (not (or (string-prefix? "(layout " line) (string-prefix? "(help-buffer " line))))
          (help-output-lines (current-help))))

(def (path-of (owner : :symbol) (name : :symbol)) => :string
  (stylesheet-path (find (lambda (s) (and (eq? (stylesheet-owner s) owner) (eq? (stylesheet-name s) name)))
                         (stylesheets))))

(def (warnings) => :list
  (let (tail (member "Warnings:" (help-lines)))
    (if tail (cdr tail) [])))

(def describe-stylesheets-test
  (test-suite "plugins/help/describe-stylesheets"
    (test-case "the page in order, a variable defined in another sheet, and no message"
      (with-help [styled-a]
        (lambda ()
          (message "")
          (call-command 'describe-stylesheets)
          (check (help-lines)
                 => ["On the page, in order:"
                     (string-append "(styled-a tokens)  " (path-of 'styled-a 'tokens))
                     (string-append "(styled-a rules)  " (path-of 'styled-a 'rules))])
          (check (current-message) => ""))))

    (test-case "replacements, removals, and a replacement of a name its active owner does not add"
      (with-help [styled-a theme]
        (lambda ()
          (call-command 'describe-stylesheets)
          ;; styled-b is off: theme's removal of its rules is dormant.
          (check (help-lines)
                 => ["On the page, in order:"
                     (string-append "(styled-a tokens)  " (path-of 'styled-a 'tokens))
                     (string-append "(styled-a rules)  " (path-of 'styled-a 'rules) "  replaced by theme")
                     "Warnings:"
                     "theme replaces (styled-a unknown), but styled-a adds no stylesheet named unknown"])
          (check (current-message) => "Stylesheets: 1 warning; see *Help*")
          (activate-plugin! styled-b)
          (call-command 'describe-stylesheets)
          (check (member "(styled-b rules)  removed by theme" (help-lines)) ? pair?))))

    (test-case "a var() without a fallback that nothing defines, skipping comments and fallbacks"
      (call-with-written-file
       (string-append "/* var(--commented) */\n"
                      ":root { --defined: 1px; --tight:2px }\n"
                      ".a { margin: var(--defined) var(--tight); padding: var(--undefined);\n"
                      "     color: var(--with-fallback, var(--inner-only)); border: var( --spaced ) }\n"
                      ".b { color: var(--undefined); }\n")
       (lambda (path)
         (with-help [written]
           (lambda ()
             (call-command 'describe-stylesheets)
             (check (warnings)
                    => ["var(--undefined) in (written rules) has no fallback, and no stylesheet defines --undefined"
                        "var(--spaced) in (written rules) has no fallback, and no stylesheet defines --spaced"])
             (check (current-message) => "Stylesheets: 2 warnings; see *Help*"))))))

    (test-case "an unreadable file is reported"
      (with-help [missing-file]
        (lambda ()
          (call-command 'describe-stylesheets)
          (check (length (warnings)) => 1)
          (check (string-prefix? "(missing-file rules): No such file: " (car (warnings))) => #t))))

    (test-case "reload-stylesheets rereads the files and reports a check that now fails"
      (call-with-written-file ".a { color: red; }\n"
       (lambda (path)
         (with-help [written]
           (lambda ()
             (call-command 'reload-stylesheets)
             (check (current-message) => "Stylesheets reread: 0 changed")
             (write-file-string path ".a { color: var(--missing); }\n")
             (call-command 'reload-stylesheets)
             (check (current-message)
                    => "Stylesheets reread: 1 changed; 1 warning, M-x describe-stylesheets lists them")
             (call-command 'describe-stylesheets)
             (check (warnings)
                    => ["var(--missing) in (written rules) has no fallback, and no stylesheet defines --missing"]))))))))
