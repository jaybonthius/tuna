(import (tuna) (test) (test-user) (keys) (commands) (tables) (ask) (completion))

(load-module! '(file-picker))

(test "loading file-picker fills ask:file-name-reader, binds C-x C-f and gives files partial; unloading takes them back, and loading again gives them again"
  (let ([before (map (lambda (key) (keys:lookup (test-user:client) key)) '("C-x C-f" "C-x 4 f"))])
    (check (for-all commands:command? before))
    (unload-owner! (module-owner '(file-picker)))
    (check-raises (lambda (c) (and (who-condition? c) (eq? 'ask:file-name-reader (condition-who c))))
                  ((ask:file-name-reader) "File: "))
    (check-equal? '(#f #f) (map (lambda (key) (keys:lookup (test-user:client) key)) '("C-x C-f" "C-x 4 f")))
    (check-equal? #f (tables:ref completion:category-styles completion:file-category #f))
    (let ([unfilled (ask:file-name-reader)])
      (load-module! '(file-picker))
      (check (not (eq? unfilled (ask:file-name-reader)))))
    (check-equal? (map commands:command-name before)
                  (map (lambda (key) (commands:command-name (keys:lookup (test-user:client) key))) '("C-x C-f" "C-x 4 f")))
    (check (pair? (tables:ref completion:category-styles completion:file-category #f)))))
