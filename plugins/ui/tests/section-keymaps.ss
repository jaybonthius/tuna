(import (tuna) (test) (test-user) (layout) (views) (buffers) (document) (keys) (commands) (hooks) (tables) (modes)
        (ui) (ui-test) (ui-test status))

(define view ui-test:view)

(ui:define-section-kind file-section)

(ui:define-section-kind hunk-section)

(tables:define-table mode-keys "Keys of the test's mode.")

(define ran '())

(define (ran! name) (set! ran (cons name ran)))

(commands:define-command (on-file) "Notes a key on a file." (ran! 'file))

(commands:define-command (on-hunk) "Notes a key on a hunk." (ran! 'hunk))

(commands:define-command (in-mode) "Notes a key of the mode." (ran! 'mode))

(commands:define-command (thing) "A placeholder that sections remap." (ran! 'thing))

(hooks:define-hook test-mode-hook "Called in the test's buffers.")

(modes:define-major-mode test-mode
  (parent ui:section-mode)
  (lighter "Test")
  (keymap mode-keys)
  (hook test-mode-hook))

(keys:bind! mode-keys "x" in-mode)
(keys:bind! mode-keys "y" in-mode)
(keys:bind! mode-keys "z" thing)
(keys:bind! file-section-keys "x" on-file)
(keys:bind! hunk-section-keys "y" on-hunk)
(keys:bind! file-section-keys "y" on-file)
(keys:remap! file-section-keys thing on-file)

(define (hunk heading . lines)
  (apply hunk-section `((type . hunk) (value . ,heading)) heading lines))

(define b
  (buffers:make "*keyed*"
    (ui-test/status:status-datum
      (ui:section '((type . unstaged)) "Unstaged changes (1)"
        (file-section '((type . file) (value . "a.py")) "modified   a.py"
          (hunk "@@ -1,3 +1,3 @@" " one" "-two" "+TWO" " three")))
      (ui:section '((type . staged)) "Staged changes (1)" (ui:section '((type . file) (value . "b.txt")) "modified   b.txt")))))

(buffers:set-silent! b #t)
(modes:set-major-mode test-mode b)
(ui-test:show! b)

(define (find-section . identity) (ui:find-section b identity))

(define (go! . identity) (views:set-point! (view) (ui:section-heading-start (apply find-section identity))))

;; A user clicks what they see, so the chevron is looked for in the drawn heading.
(define (click-chevron! . identity)
  (let* ([at (number->string (ui:section-heading-start (apply find-section identity)))]
         [heading (find (lambda (e) (exists (lambda (s) (equal? at (test-user:element-attribute s "data-at"))) (test-user:elements-with e "data-at")))
                        (ui-test:elements (view) "ui-section-heading"))])
    (test-user:click-element! (car (test-user:elements heading "ui-section-chevron")))))

(define (pressed keys) (set! ran '()) (test-user:press! keys) (reverse ran))

(test "a key bound in a section's keymap acts at point in the section and in the sections it holds, before the mode's"
  (go! '(file . "a.py") '(unstaged . #f))
  (check-equal? '(file) (pressed "x"))
  (go! '(hunk . "@@ -1,3 +1,3 @@") '(file . "a.py") '(unstaged . #f))
  (check-equal? '(file) (pressed "x"))
  (go! '(staged . #f))
  (check-equal? '(mode) (pressed "x")))

(test "the innermost section's keymap is searched first"
  (go! '(hunk . "@@ -1,3 +1,3 @@") '(file . "a.py") '(unstaged . #f))
  (check-equal? '(hunk) (pressed "y"))
  (go! '(file . "a.py") '(unstaged . #f))
  (check-equal? '(file) (pressed "y")))

(test "a section's keymap remaps a command the mode binds, there alone"
  (go! '(hunk . "@@ -1,3 +1,3 @@") '(file . "a.py") '(unstaged . #f))
  (check-equal? '(file) (pressed "z"))
  (go! '(file . "b.txt") '(staged . #f))
  (check-equal? '(thing) (pressed "z")))

(test "a click is looked up in the keymaps of the sections around the clicked place"
  (keys:bind! file-section-keys "<mouse-3>" on-file)
  (go! '(staged . #f))
  (set! ran '())
  (ui-test:click-at! (view) (ui:section-heading-start (find-section '(file . "a.py") '(unstaged . #f))) "<mouse-3>")
  (check-equal? '(file) (reverse ran)))

(test "a section of a kind is a section to every ui command: its type and value, n and p, TAB, levels and a click on its chevron"
  (go! '(unstaged . #f))
  (check-equal? '(file "a.py") (let ([s (begin (test-user:press! "n") (ui:section-at (view)))]) (list (ui:section-type s) (ui:section-value s))))
  (check-equal? '(hunk "@@ -1,3 +1,3 @@") (let ([s (begin (test-user:press! "n") (ui:section-at (view)))]) (list (ui:section-type s) (ui:section-value s))))
  (test-user:press! "p")
  (test-user:press! "TAB")
  (check-equal? '("Head:     main Second commit" "Unstaged changes (1)" "modified   a.py…" "Staged changes (1)" "modified   b.txt")
                (ui-test:visible (view)))
  (click-chevron! '(file . "a.py") '(unstaged . #f))
  (check-equal? #f (ui:section-hidden? (view) (find-section '(file . "a.py") '(unstaged . #f))))
  (test-user:press! "M-1")
  (check-equal? '("Head:     main Second commit" "Unstaged changes (1)…" "Staged changes (1)…") (ui-test:visible (view)))
  (test-user:press! "M-4")
  (check-equal? '((file . "a.py")) (map (lambda (s) (cons (ui:section-type s) (ui:section-value s))) (ui:section-children (find-section '(unstaged . #f)))))
  (check-equal? '("Head:     main Second commit" "Unstaged changes (1)" "modified   a.py" "@@ -1,3 +1,3 @@" " one" "-two" "+TWO" " three"
                  "Staged changes (1)" "modified   b.txt")
                (ui-test:visible (view)))
  (check-equal? 'ui:define-section-kind
                (guard (c [(assertion-violation? c) (condition-who c)]) (file-section '((value . "a.py")) "no type"))))

(test "ui:section-shown is called with the view and the section when a command shows a hidden section, and not when one hides it"
  (let* ([shown '()] [note (lambda (v s) (set! shown (cons (list (eq? v (view)) (ui:section-type s)) shown)))])
    (hooks:add! ui:section-shown note)
    (go! '(file . "a.py") '(unstaged . #f))
    (test-user:press! "TAB")
    (check-equal? '() shown)
    (test-user:press! "TAB")
    (check-equal? '((#t file)) shown)
    (ui:hide-section! (view) (find-section '(unstaged . #f)))
    (ui:show-section! (view) (find-section '(unstaged . #f)))
    (check-equal? '((#t unstaged) (#t file)) shown)
    (ui:show-section! (view) (find-section '(unstaged . #f)))
    (check-equal? 2 (length shown))
    (hooks:remove! ui:section-shown note)))
