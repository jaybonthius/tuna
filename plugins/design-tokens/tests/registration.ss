(import (tuna) (test) (web) (tables) (design-tokens) (faces))

(define (names) (map car (tables:entries web:stylesheets)))

(test "the plugin's only work is registering its stylesheet, which every page links before the faces' rules"
  (check-equal? "design-tokens/design-tokens.css" (tables:ref web:stylesheets 'design-tokens #f))
  (check (eq? (module-owner '(design-tokens)) (tables:owner web:stylesheets 'design-tokens)))
  (let ([order (names)])
    (check (< (length (memq 'faces order)) (length (memq 'design-tokens order))))))

(test "a theme is a plugin that registers its file as theme; the user's tweaks are a file of their own, after it; turning the theme off takes its file back"
  (load-module! '(design-tokens-test dusk))
  (call-with-output-file (string-append (getenv "HOME") "/.config/tuna/user.css")
    (lambda (p) (put-string p ":root { --tuna-region: #264f78; }\n")) 'replace)
  (tables:set! web:stylesheets 'user "user.css")
  (check-equal? "dusk/dusk.css" (tables:ref web:stylesheets 'theme #f))
  (let ([order (names)])
    (check (< (length (memq 'user order)) (length (memq 'theme order)) (length (memq 'faces order)))))
  (unload-owner! (module-owner '(design-tokens-test dusk)))
  (check-equal? #f (tables:ref web:stylesheets 'theme #f))
  (tables:remove! web:stylesheets 'user))

(test "an unload takes the instance's entry back, and a new instance registers its own"
  (let ([old (module-owner '(design-tokens))])
    (unload-owner! old)
    (check-equal? #f (tables:ref web:stylesheets 'design-tokens #f))
    (load-module! '(design-tokens))
    (check-equal? #f (owner-live? old))
    (check (eq? (module-owner '(design-tokens)) (tables:owner web:stylesheets 'design-tokens)))
    (check-equal? "design-tokens/design-tokens.css" (tables:ref web:stylesheets 'design-tokens #f))))
