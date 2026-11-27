(import (tuna) (test) (test-user) (test-runner) (options) (tables) (keys) (commands) (buffers) (document) (views) (layout) (files)
        (kill-ring) (editing) (minibuffer) (completion) (completion-list) (echo-area) (buffer-picker) (file-picker)
        (command-picker) (help) (actions) (actions-test acting))

(define (home-file name) (string-append (getenv "HOME") "/" name))

(define (write-file! name text)
  (call-with-output-file (home-file name) (lambda (p) (put-string p text)) 'replace))

(mkdir (home-file "src"))
(write-file! "src/notes.txt" "notes\n")
(write-file! "src/text.txt" "text\n")

(define (switching-to typed)
  (test-user:press! "C-x b")
  (test-user:type! typed)
  (actions-test/acting:settled))

;; C-x C-w's command goes on after the file is written, so a test that
;; quits later would quit it too; this one waits for it to end.
(define (writing) (actions-test/acting:start! (lambda () (commands:run files:write-file))))

(define (finished r) (test-runner:wait-until (lambda () (not (actions-test/acting:waiting? r)))))

(test "C-. reads an action in the selected candidate's category, quits the read and answers the action's read with the candidate"
  (buffers:make "foo.scm" "")
  (buffers:make "foo" "")
  (switching-to "foo")
  (check-equal? '("foo.scm" "foo") (actions-test/acting:texts))
  (test-user:press! "C-n")
  (let ([s (actions-test/acting:session)])
    (check-equal? "foo" (actions-test/acting:selected-text))
    (check-equal? completion:buffer-category (completion:category s (completion:selected s))))
  (test-user:press! "C-.")
  (check-equal? "Act on foo: " (actions-test/acting:action-prompt))
  (check-equal? '(quit) (actions-test/acting:press! "k"))
  (check-equal? #f (member "foo" (actions-test/acting:names)))
  (check (member "foo.scm" (actions-test/acting:names)))
  (check-equal? #f (actions-test/acting:prompt))
  (check-equal? #f (echo-area:current-message)))

(test "C-u before C-. keeps the read open"
  (switching-to "foo")
  (check-equal? "foo.scm" (actions-test/acting:selected-text))
  (test-user:press! "C-u C-.")
  (check-equal? '() (actions-test/acting:press! "k"))
  (check-equal? #f (member "foo.scm" (actions-test/acting:names)))
  (check-equal? "foo" (actions-test/acting:input))
  (check-equal? '(quit) (actions-test/acting:press! "C-g")))

(test "with actions:quit-after-action? off an action keeps the read, and C-u before C-. quits it"
  (options:set! actions:quit-after-action? #f)
  (check-equal? #f (actions:quit-after-action?))
  (buffers:make "bar" "")
  (switching-to "bar")
  (test-user:press! "C-.")
  (check-equal? '() (actions-test/acting:press! "k"))
  (check-equal? "bar" (actions-test/acting:input))
  (buffers:make "baz" "")
  (test-user:press! "M-DEL")
  (test-user:type! "baz")
  (actions-test/acting:settled)
  (test-user:press! "C-u C-.")
  (check-equal? '(quit) (actions-test/acting:press! "k"))
  (check-equal? #f (member "baz" (actions-test/acting:names)))
  (check-equal? #f (actions-test/acting:prompt))
  (options:unset! actions:quit-after-action?))

(test "a file name's target is its folder and name as the input holds it once chosen, and f visits it"
  (test-user:press! "C-x C-f")
  (test-user:type! "src/te")
  (actions-test/acting:settled)
  (check-equal? '("text.txt") (actions-test/acting:texts))
  (let* ([s (actions-test/acting:session)] [m (completion:selected s)])
    (check-equal? "~/src/text.txt" (completion:whole-text s m))
    (check-equal? completion:file-category (completion:category s m)))
  (test-user:press! "C-.")
  (check-equal? '(quit) (actions-test/acting:press! "f"))
  (actions-test/acting:wait-for-file)
  (check-equal? (home-file "src/text.txt") (files:path (views:buffer (actions-test/acting:view)))))

(test "h describes a command chosen in M-x"
  (test-user:press! "M-x")
  (test-user:type! "describe-com")
  (actions-test/acting:settled)
  (check-equal? "help:describe-command" (actions-test/acting:selected-text))
  (test-user:press! "C-.")
  (check-equal? '(quit) (actions-test/acting:press! "h"))
  (check-equal? "help:describe-command" (actions-test/acting:help-title)))

(test "C-; and C-. RET choose the read's target as RET does"
  (buffers:make "notes" "")
  (switching-to "notes")
  (check-equal? '() (actions-test/acting:press! "C-;"))
  (check-equal? "notes" (buffers:name (views:buffer (actions-test/acting:view))))
  (check-equal? #f (actions-test/acting:prompt))
  (layout:switch-to-buffer (buffers:find "*scratch*"))
  (switching-to "notes")
  (test-user:press! "C-.")
  (check-equal? '() (actions-test/acting:press! "RET"))
  (check-equal? "notes" (buffers:name (views:buffer (actions-test/acting:view)))))

(test "in a read, a category's RET binding does not replace the read's choice: C-; in C-x C-w writes the buffer and visits nothing"
  (keys:bind! completion:file-action-keymap "RET" file-picker:find-file)
  (let ([draft (buffers:make "draft" "text\n")])
    (layout:switch-to-buffer draft)
    (let ([r (writing)])
      (minibuffer:set-input! (actions-test/acting:prompt) "~/src/draft.txt")
      (actions-test/acting:settled)
      (check-equal? '() (actions-test/acting:press! "C-;"))
      (finished r))
    (check-equal? "draft.txt" (buffers:name (views:buffer (actions-test/acting:view))))
    (check-equal? (home-file "src/draft.txt") (files:path draft)))
  (let ([other (buffers:make "other" "text\n")])
    (layout:switch-to-buffer other)
    (let ([r (writing)])
      (minibuffer:set-input! (actions-test/acting:prompt) "~/src/notes.txt")
      (actions-test/acting:settled)
      (test-user:press! "C-;")
      (test-user:press! "y")
      (finished r))
    (check-equal? "notes.txt" (buffers:name (views:buffer (actions-test/acting:view))))
    (check-equal? (home-file "src/notes.txt") (files:path other)))
  (keys:unbind! completion:file-action-keymap "RET"))

(test "actions:default-actions gives C-; another command for a category, and C-u before C-; keeps the read for it"
  (buffers:make "memo" "")
  (tables:set! actions:default-actions completion:buffer-category buffer-picker:kill-buffer)
  (switching-to "memo")
  (check-equal? '(quit) (actions-test/acting:press! "C-;"))
  (check-equal? #f (member "memo" (actions-test/acting:names)))
  (buffers:make "kept" "")
  (switching-to "kept")
  (check-equal? '() (actions-test/acting:press! "C-u C-;"))
  (check-equal? #f (member "kept" (actions-test/acting:names)))
  (check (actions-test/acting:prompt))
  (check-equal? '(quit) (actions-test/acting:press! "C-g"))
  (tables:remove! actions:default-actions completion:buffer-category))

(test "a key bound to no action raises, a quit key says Quit, and the read stays in both"
  (switching-to "")
  (test-user:press! "C-.")
  (check-equal? '("z is not an action") (actions-test/acting:press! "z"))
  (test-user:press! "C-.")
  (check-equal? '(quit) (actions-test/acting:press! "C-g"))
  (check-equal? "Quit" (echo-area:current-message))
  (check (actions-test/acting:prompt))
  (check-equal? '(quit) (actions-test/acting:press! "C-g")))

(test "outside a read, with nothing at point, there is no target"
  (actions-test/acting:show! (buffers:make "empty" ""))
  (check-equal? '("No target found") (actions-test/acting:press! "C-.")))

(test "every target has the general actions: w copies the whole text of a candidate with no category, and of a location"
  (let ([r (actions-test/acting:start! (lambda () (completion:read "Pick: " (list (completion:source (candidates (vector "one")))))))])
    (test-user:press! "C-.")
    (check-equal? '() (actions-test/acting:press! "w"))
    (check-equal? 'quit (actions-test/acting:result r))
    (check-equal? '("one") (kill-ring:current)))
  (let ([r (actions-test/acting:start!
             (lambda ()
               (completion:read "Loc: "
                 (list (completion:source (candidates (vector (cons "a.txt:1" (cons* "a.txt" 1 0))))
                                          (category completion:location-category))))))])
    (test-user:press! "C-.")
    (check-equal? "Act on a.txt:1: " (actions-test/acting:action-prompt))
    (check-equal? '() (actions-test/acting:press! "w"))
    (check-equal? 'quit (actions-test/acting:result r))
    (check-equal? '("a.txt:1") (kill-ring:current))))

(test "i inserts the target's whole text at point in the view the read was started from"
  (let ([page (buffers:make "page" "<>")])
    (layout:switch-to-buffer page)
    (views:set-point! (actions-test/acting:view) 2)
    (test-user:press! "C-x C-f")
    (test-user:type! "src/te")
    (actions-test/acting:settled)
    (test-user:press! "C-.")
    (check-equal? '(quit) (actions-test/acting:press! "i"))
    (test-runner:wait-until (lambda () (not (string=? "<>" (actions-test/acting:text page)))))
    (check-equal? "page" (buffers:name (views:buffer (actions-test/acting:view))))
    (check-equal? "<~/src/text.txt>" (actions-test/acting:text page))
    (check-equal? 16 (views:point (actions-test/acting:view)))))

(test "a category keymap's binding of two keys is reached by typing both"
  (keys:bind! completion:buffer-action-keymap "x k" buffer-picker:kill-buffer)
  (buffers:make "gone" "")
  (switching-to "gone")
  (test-user:press! "C-. x")
  (check-equal? '(quit) (actions-test/acting:press! "k"))
  (check-equal? #f (member "gone" (actions-test/acting:names)))
  (switching-to "")
  (test-user:press! "C-. x")
  (check-equal? '("x z is not an action") (actions-test/acting:press! "z"))
  (check-equal? '(quit) (actions-test/acting:press! "C-g"))
  (keys:unbind! completion:buffer-action-keymap "x k"))

(test "completion:answer-input! answers a prompt with its input, and a read with the candidate its input names; a read that needs a candidate stays when none is named"
  (let ([r (actions-test/acting:start! (lambda () (minibuffer:read "Name: ")))])
    (minibuffer:set-input! (actions-test/acting:prompt) "x")
    (completion:answer-input! (actions-test/acting:prompt))
    (test-user:settle)
    (check-equal? "x" (actions-test/acting:result r)))
  (let ([r (actions-test/acting:start! (lambda () (buffer-picker:read-buffer "Buffer: ")))])
    (minibuffer:set-input! (actions-test/acting:prompt) "*scratch*")
    (completion:answer-input! (actions-test/acting:prompt))
    (test-user:settle)
    (check-equal? (buffers:find "*scratch*") (actions-test/acting:result r)))
  (let ([r (actions-test/acting:start! (lambda () (buffer-picker:read-buffer "Buffer: ")))])
    (minibuffer:set-input! (actions-test/acting:prompt) "nothing")
    (completion:answer-input! (actions-test/acting:prompt))
    (test-user:settle)
    (check (actions-test/acting:waiting? r))
    (test-user:press! "C-g")
    (check-equal? 'quit (actions-test/acting:result r))))

(keys:bind! completion:buffer-action-keymap "p" actions-test/acting:show-prefix)

(buffers:make "prefixed" "")

(define (prefix-of keys)
  (switching-to "prefixed")
  (test-user:press! "C-.")
  (check-equal? '(quit) (actions-test/acting:press! keys))
  (echo-area:current-message))

(test "keys typed between C-. and the action's key give it a prefix argument"
  (check-equal? "#f prefixed" (prefix-of "p"))
  (check-equal? "(4) prefixed" (prefix-of "C-u p"))
  (check-equal? "(16) prefixed" (prefix-of "C-u C-u p"))
  (check-equal? "2 prefixed" (prefix-of "C-u 2 p"))
  (check-equal? "23 prefixed" (prefix-of "M-2 3 p"))
  (check-equal? "- prefixed" (prefix-of "M-- p"))
  (check-equal? "-4 prefixed" (prefix-of "C-u - 4 p")))

(test "bare digits and - after C-. type the prefix argument, and K finds k's binding"
  (check-equal? "2 prefixed" (prefix-of "2 p"))
  (check-equal? "23 prefixed" (prefix-of "2 3 p"))
  (check-equal? "- prefixed" (prefix-of "- p"))
  (check-equal? "2 prefixed" (prefix-of "C-u 2 p"))
  (check-equal? "#f prefixed" (prefix-of "P")))

(test "a category keymap's binding of a digit comes before the general one"
  (keys:bind! completion:buffer-action-keymap "5" actions-test/acting:show-prefix)
  (check-equal? "#f prefixed" (prefix-of "5"))
  (keys:unbind! completion:buffer-action-keymap "5"))

(commands:define-command (say-prefix)
  "Says the prefix argument."
  (echo-area:message! "~s" (commands:prefix-argument)))

(keys:bind! keys:global "C-c p" say-prefix)

(test "C-u before C-. keeps the read and a C-u after it is the action's own; no prefix reaches a later command"
  (switching-to "prefixed")
  (test-user:press! "C-u C-. C-u")
  (check-equal? '() (actions-test/acting:press! "p"))
  (check-equal? "(4) prefixed" (echo-area:current-message))
  (check (actions-test/acting:prompt))
  (check-equal? '(quit) (actions-test/acting:press! "C-g"))
  (test-user:press! "C-c p")
  (check-equal? "#f" (echo-area:current-message)))

(commands:define-command (other-kill [b (buffer-picker:read-buffer "Buffer: ")])
  "Says B's name."
  (echo-area:message! "Not killing ~a" (buffers:name b)))

(test "an action's key runs the command a remap gives in its place"
  (keys:remap! keys:global buffer-picker:kill-buffer other-kill)
  (switching-to "prefixed")
  (test-user:press! "C-.")
  (check-equal? '(quit) (actions-test/acting:press! "k"))
  (check-equal? "Not killing prefixed" (echo-area:current-message))
  (check (member "prefixed" (actions-test/acting:names)))
  (tables:remove! keys:global buffer-picker:kill-buffer))

(test "with empty input and nothing selected the target is the read's default: C-. k in C-x k kills the current buffer"
  (options:set! completion:read-preselect 'none)
  (layout:switch-to-buffer (buffers:make "current" ""))
  (test-user:press! "C-x k")
  (actions-test/acting:settled)
  (check-equal? "" (actions-test/acting:input))
  (check-equal? #f (completion:selected (actions-test/acting:session)))
  (test-user:press! "C-.")
  (check-equal? "Act on current: " (actions-test/acting:action-prompt))
  (check-equal? '(quit) (actions-test/acting:press! "k"))
  (check-equal? #f (member "current" (actions-test/acting:names)))
  (options:unset! completion:read-preselect))

(test "an action that keeps the read runs in the view the read was started from, and the read keeps the selection"
  (let ([shown (buffers:make "shown" "")] [before (actions-test/acting:view)])
    (switching-to "shown")
    (test-user:press! "C-u C-.")
    (check-equal? '() (actions-test/acting:press! "b"))
    (check-equal? "shown" (actions-test/acting:input))
    (check-equal? "shown" (buffers:name (views:buffer before)))
    (check-equal? (actions-test/acting:view) (minibuffer:prompt-view (actions-test/acting:prompt)))
    (check-equal? '(quit) (actions-test/acting:press! "C-g")))
  (let ([two (buffers:make "two" "ab\n")])
    (layout:switch-to-buffer two)
    (views:set-point! (actions-test/acting:view) 1)
    (views:add-cursor! (actions-test/acting:view) 2)
    (switching-to "shown")
    (test-user:press! "C-u C-.")
    (check-equal? '() (actions-test/acting:press! "i"))
    (check-equal? "shown" (actions-test/acting:input))
    (check-equal? "shownashownb\n" (actions-test/acting:text two))
    (check-equal? '(quit) (actions-test/acting:press! "C-g"))
    (switching-to "shown")
    (test-user:press! "C-.")
    (check-equal? '(quit) (actions-test/acting:press! "i"))
    (check-equal? "shownshownashownshownb\n" (actions-test/acting:text two))))

(commands:define-command (warn-then [b (buffer-picker:read-buffer "B: ")])
  "Warns, then says B's name."
  (raise-continuable (condition (make-warning) (make-message-condition "careful")))
  (echo-area:message! "after ~a" (buffers:name b)))

(test "a warning an action raises is reported and the action goes on, whether it quits the read or keeps it"
  (keys:bind! completion:buffer-action-keymap "v" warn-then)
  (buffers:make "warned" "")
  (switching-to "warned")
  (test-user:press! "C-.")
  (check-equal? '(quit "careful") (actions-test/acting:press! "v"))
  (check-equal? "after warned" (echo-area:current-message))
  (switching-to "warned")
  (test-user:press! "C-u C-.")
  (check-equal? '("careful") (actions-test/acting:press! "v"))
  (check-equal? "after warned" (echo-area:current-message))
  (check-equal? (actions-test/acting:view) (minibuffer:prompt-view (actions-test/acting:prompt)))
  (check-equal? '(quit) (actions-test/acting:press! "C-g"))
  (keys:unbind! completion:buffer-action-keymap "v"))

(test "with nothing selected, a read whose sources share a category targets its input: a folder's name, a file not made yet"
  (test-user:press! "C-x C-f")
  (minibuffer:set-input! (actions-test/acting:prompt) "~/src/")
  (actions-test/acting:settled)
  (check-equal? #f (completion:selected (actions-test/acting:session)))
  (test-user:press! "C-.")
  (check-equal? "Act on ~/src/: " (actions-test/acting:action-prompt))
  (check-equal? '(quit) (actions-test/acting:press! "C-g"))
  (test-user:type! "new.txt")
  (actions-test/acting:settled)
  (check-equal? #f (completion:selected (actions-test/acting:session)))
  (test-user:press! "C-.")
  (check-equal? '(quit) (actions-test/acting:press! "f"))
  (actions-test/acting:wait-for-file)
  (check-equal? (home-file "src/new.txt") (files:path (views:buffer (actions-test/acting:view)))))

(test "C-; with nothing selected answers as RET does"
  (let ([r (actions-test/acting:start!
             (lambda ()
               (completion:read-or-input "Fruit: "
                 (list (completion:source (candidates (vector "apple")) (category completion:file-category))))))])
    (test-user:type! "kiwi")
    (actions-test/acting:settled)
    (check-equal? '() (actions-test/acting:press! "C-;"))
    (check-equal? "kiwi" (actions-test/acting:result r))))

(test "a read whose sources' categories differ has no target while nothing is selected"
  (let ([r (actions-test/acting:start!
             (lambda ()
               (completion:read "Pick: "
                 (list (completion:source (candidates (vector "one")) (category completion:file-category))
                       (completion:source (candidates (vector "two")) (category completion:buffer-category))))))])
    (test-user:type! "zzz")
    (actions-test/acting:settled)
    (check-equal? (list completion:file-category completion:buffer-category)
                  (completion:session-categories (actions-test/acting:session)))
    (check-equal? '("No target found") (actions-test/acting:press! "C-."))
    (test-user:press! "C-g")
    (check-equal? 'quit (actions-test/acting:result r))))

(define (read-action-by-name read-action keymaps text)
  (values
    (completion:read (string-append "Act on " text ": ")
      (list (completion:source
              (candidates
                (list->vector
                  (map (lambda (b) (cons (symbol->string (commands:command-name (cdr b))) (cdr b)))
                       (filter (lambda (b) (commands:command? (cdr b)))
                               (apply append (map keys:bindings keymaps)))))))))
    #f))

(test "advice on actions:read-action can choose the action with a read of the keymaps' bindings"
  (advice-add! actions:read-action read-action-by-name)
  (switching-to "prefixed")
  (let ([outer (actions-test/acting:prompt)])
    (test-user:press! "C-.")
    (check (not (eq? outer (actions-test/acting:prompt)))))
  (test-user:type! "actions-test/acting:show-pre")
  (actions-test/acting:settled)
  (check-equal? '(quit)
    (actions-test/acting:reports-during
      (lambda ()
        (test-user:press! "RET")
        (test-runner:wait-until (lambda () (echo-area:current-message))))))
  (check-equal? "#f prefixed" (echo-area:current-message))
  (advice-remove! actions:read-action read-action-by-name))

(completion:define-category fruit-category "Fruit names.")

(tables:define-table fruit-action-keymap "The actions on fruit names.")

(commands:define-command (eat-fruit
                           [fruit (completion:read "Eat: "
                                    (list (completion:source (candidates (vector "apple" "pear"))
                                                             (category fruit-category))))])
  "Eats FRUIT."
  (echo-area:message! "Ate ~a" fruit))

(test "a plugin's own category has a keymap of its actions"
  (tables:set! completion:action-keymaps fruit-category (list fruit-action-keymap))
  (keys:bind! fruit-action-keymap "e" eat-fruit)
  (let ([r (actions-test/acting:start!
             (lambda ()
               (completion:read "Fruit: "
                 (list (completion:source (candidates (vector "apple" "pear")) (category fruit-category))))))])
    (test-user:type! "pe")
    (test-user:press! "C-.")
    (check-equal? '() (actions-test/acting:press! "e"))
    (check-equal? "Ate pear" (echo-area:current-message))
    (check-equal? 'quit (actions-test/acting:result r))))
