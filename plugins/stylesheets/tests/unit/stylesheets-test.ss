;;; The stylesheets registry: adding, replacing, removing, restoring,
;;; dormant replacements, order by rank, unreadable files and rereading.
(import :std/misc/ports
        :std/test
        :tuna/kernel
        :tuna/plugins/stylesheets/contract
        "../../../../tuna/tests/support/kernel"
        "../support/styled")
(export stylesheets-test)

;; The page as (owner name file replaced-by).
(def (page)
  (map (lambda (s)
         [(stylesheet-owner s) (stylesheet-name s)
          (path-strip-directory (stylesheet-path s)) (stylesheet-replaced-by s)])
       (stylesheets)))

(def (replacements)
  (map (lambda (r)
         [(stylesheet-replacement-owner r) (stylesheet-replacement-name r)
          (stylesheet-replacement-replaced-by r) (stylesheet-replacement-target r)])
       (stylesheet-replacements)))

(def (find-stylesheet owner name)
  (find (lambda (s) (and (eq? (stylesheet-owner s) owner) (eq? (stylesheet-name s) name)))
        (stylesheets)))

;; A file the reread test changes, and the plugin that adds it with its
;; context argument and an absolute path.
(def changing-file (make-parameter #f))

(defplugin (changing ctx) "Adds the changing file."
  (add-stylesheet ctx 'rules (changing-file)))

;; Replaces styled-a's rules with styled-b's file, to compete with theme.
(defplugin changing-theme "Replaces styled-a's rules too."
  (replace-stylesheet 'styled-a 'rules "../support/css/b-rules.css"))

(def stylesheets-test
  (test-suite "stylesheets registry"
    (test-case "a plugin's stylesheets are on the page in registration order, with text and digest"
      (call-with-fresh-kernel [styled-a]
        (lambda ()
          (check (page) => '((styled-a tokens "a-tokens.css" #f) (styled-a rules "a-rules.css" #f)))
          (let (s (find-stylesheet 'styled-a 'tokens))
            (check (stylesheet-text s) => ":root {\n  --a-accent: blue;\n}\n")
            (check (string-length (stylesheet-digest s)) => 64)
            (check (stylesheet-warning s) => #f)
            (check (string-prefix? "/" (stylesheet-path s)) => #t))))
      (check (stylesheets) => []))

    (test-case "a replacement wins, #f removes, and turning the theme off restores both"
      (call-with-fresh-kernel [styled-a styled-b theme]
        (lambda ()
          (check (page) => '((styled-a tokens "a-tokens.css" #f)
                             (styled-a rules "theme-a-rules.css" theme)))
          (check (replacements) => '((styled-a rules theme present)
                                     (styled-b rules theme present)
                                     (styled-a unknown theme absent)))
          (deactivate-plugin! theme)
          (check (page) => '((styled-a tokens "a-tokens.css" #f)
                             (styled-a rules "a-rules.css" #f)
                             (styled-b rules "b-rules.css" #f)))
          (check (replacements) => []))))

    (test-case "a replacement whose owner is off is dormant until the owner comes on"
      (call-with-fresh-kernel [theme]
        (lambda ()
          (check (page) => [])
          (check (replacements) => '((styled-a rules theme dormant)
                                     (styled-b rules theme dormant)
                                     (styled-a unknown theme dormant)))
          (activate-plugin! styled-a)
          (check (page) => '((styled-a tokens "a-tokens.css" #f)
                             (styled-a rules "theme-a-rules.css" theme))))))

    (test-case "the page follows the owners' init.ss ranks, read when it is read"
      (call-with-fresh-kernel [styled-a styled-b]
        (lambda ()
          (set-plugin-order! styled-a 2)
          (set-plugin-order! styled-b 1)
          (let (before (stylesheets-generation))
            (check (map car (page)) => '(styled-b styled-a styled-a))
            (set-plugin-order! styled-a 1)
            (set-plugin-order! styled-b 2)
            (check (map car (page)) => '(styled-a styled-a styled-b))
            (check (= (stylesheets-generation) before) => #f)
            (let (after (stylesheets-generation))
              (check (stylesheets-generation) => after))))))

    (test-case "among replacements the later declared owner wins"
      (call-with-fresh-kernel [styled-a theme]
        (lambda ()
          (activate-plugin! changing-theme)
          (set-plugin-order! theme 1)
          (set-plugin-order! changing-theme 2)
          (check (path-strip-directory (stylesheet-path (find-stylesheet 'styled-a 'rules)))
                 => "b-rules.css")
          (set-plugin-order! theme 3)
          (check (stylesheet-replaced-by (find-stylesheet 'styled-a 'rules)) => 'theme))))

    (test-case "a missing file is a warning on its stylesheet, not a failed activation"
      (call-with-fresh-kernel [missing-file]
        (lambda ()
          (check (plugin-active? missing-file) => #t)
          (let (s (find-stylesheet 'missing-file 'rules))
            (check (stylesheet-text s) => #f)
            (check (stylesheet-digest s) => #f)
            (check (string-prefix? "No such file: " (stylesheet-warning s)) => #t)))))

    (test-case "rereading picks up a changed file and changes the generation"
      (let (path (path-expand (string-append "tuna-stylesheet-" (number->string (random-integer 1000000000)) ".css")
                              (getenv "TMPDIR" "/tmp")))
        (write-file-string path ".x { color: red; }\n")
        (try
         (parameterize ((changing-file path))
           (call-with-fresh-kernel [changing]
             (lambda ()
               (let ((digest (stylesheet-digest (find-stylesheet 'changing 'rules)))
                     (generation (stylesheets-generation)))
                 (check (reread-stylesheets!) => 0)
                 (check (stylesheets-generation) => generation)
                 (write-file-string path ".x { color: blue; }\n")
                 (check (reread-stylesheets!) => 1)
                 (let (s (find-stylesheet 'changing 'rules))
                   (check (stylesheet-text s) => ".x { color: blue; }\n")
                   (check (equal? (stylesheet-digest s) digest) => #f))
                 (check (= (stylesheets-generation) generation) => #f)
                 (delete-file path)
                 (check (reread-stylesheets!) => 1)
                 (check (stylesheet-warning (find-stylesheet 'changing 'rules)) ? string?)))))
         (finally (when (file-exists? path) (delete-file path))))))))
