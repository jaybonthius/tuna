(import (tuna) (test) (test-runner) (test-user) (web) (hooks) (options) (tables) (commands) (keys) (keys-test)
        (keys-test completions))

;; A table's entries outlive the form that defines it, so each test
;; defines keymaps of its own names.

(commands:define-command (first-command) "Does nothing." (void))
(commands:define-command (second-command) "Does nothing." (void))
(commands:define-command (third-command) "Does nothing." (void))

(define client 'client)

(define (keymaps-among keymaps among)
  (filter (lambda (k) (memq k among)) keymaps))

(define (with-keymaps-entry entry thunk)
  (hooks:add! keys:find-keymaps entry -50)
  (thunk)
  (hooks:remove! keys:find-keymaps entry))

(test "a key is modifiers C- M- S- s- in that order, then a character or a named key, and shift on a character is in the character"
  (tables:define-table syntax-keymap)
  (for-each
    (lambda (keys) (check-equal? (list keys (void)) (list keys (keys:bind! syntax-keymap keys first-command))))
    '("a" "A" "C-a" "C-A" "M-x" "C-M-x" "s-a" "C-M-s-a" "C--" "M-<" "C->" "é" "≈" "RET" "SPC" "TAB" "ESC" "DEL"
      "<f1>" "<left>" "S-<left>" "C-S-<right>" "M-S-RET" "<printing-char>" "C-x C-f" "C-c p f" "C-x 4 C-f" "C-<"))
  (for-each
    (lambda (keys)
      (check-raises (keys-test:raised-by 'keys:bind! "not a valid key sequence") (keys:bind! syntax-keymap keys first-command)))
    '("" " " "C-" "M-C-x" "S-a" "C-S-a" "S-1" "s-C-a" "C-x  C-f" " C-x" "C-x " "ret" "<>" "<a b>" "<f1" "f1>"
      "ab" "C-ab" "x\x7;" "\x7;" "S-" "C-M-" C-x)))

(test "bind! takes a keymap and a command or keymap, and the other procedures check their keys"
  (tables:define-table checked-keymap)
  (check-raises (keys-test:raised-by 'keys:bind! "neither a command nor a keymap") (keys:bind! checked-keymap "C-x" 'first-command))
  (check-raises (keys-test:raised-by 'keys:bind! "not a keymap") (keys:bind! 'km "C-x" first-command))
  (check-raises (keys-test:raised-by 'keys:press! "neither one valid key nor an event") (keys:press! (test-user:client) "C-x C-f"))
  (check-raises (keys-test:raised-by 'keys:press! "neither one valid key nor an event") (keys:press! (test-user:client) '("<mouse-1>")))
  (check-raises (keys-test:raised-by 'keys:lookup "not a valid key sequence") (keys:lookup client "C-x  C-f"))
  (check-raises (keys-test:raised-by 'keys:lookup "not a valid key sequence") (keys:lookup client 'C-x))
  (check-raises (keys-test:raised-by 'keys:unbind! "not a valid key sequence") (keys:unbind! checked-keymap "C-")))

(test "binding marks each leading part as a prefix, and bindings lists the bindings in the order first bound, without the marks"
  (tables:define-table marked-keymap)
  (keys:bind! marked-keymap "C-x 4 C-f" first-command)
  (keys:bind! marked-keymap "C-x o" second-command)
  (check-equal? (list (cons "C-x" #t) (cons "C-x 4" #t) (cons "C-x 4 C-f" first-command) (cons "C-x o" second-command))
                (tables:entries marked-keymap))
  (check-equal? (list (cons "C-x 4 C-f" first-command) (cons "C-x o" second-command)) (keys:bindings marked-keymap))
  (check-raises (keys-test:raised-by 'keys:bindings "not a keymap") (keys:bindings 'km)))

(test "the binding in effect is the last change: a prefix bound to a command hides the longer bindings, and binding a longer one marks it again"
  (tables:define-table changed-keymap)
  (let ([in (lambda (keys) (keys:lookup-in (list changed-keymap) keys))])
    (keys:bind! changed-keymap "C-x 4 C-f" first-command)
    (keys:bind! changed-keymap "C-x o" second-command)
    (keys:bind! changed-keymap "C-x" third-command)
    (check-equal? third-command (in "C-x"))
    (check-equal? #f (in "C-x o"))
    (keys:bind! changed-keymap "C-x 4 C-f" first-command)
    (check-equal? first-command (in "C-x 4 C-f"))
    (check-equal? second-command (in "C-x o"))
    (check-equal? (list (cons "C-x 4 C-f" first-command) (cons "C-x o" second-command)) (keys:bindings changed-keymap))
    (keys:unbind! changed-keymap "C-x o")
    (check-equal? (list (cons "C-x 4 C-f" first-command)) (keys:bindings changed-keymap))))

(test "a leading part bound to a keymap stays that keymap, which makes it a prefix whose keys are looked up in it"
  (tables:define-table prefixed-keymap)
  (keys:bind! prefixed-keymap "C-c p" keys-test/completions:prefix-map)
  (keys:bind! prefixed-keymap "C-c p x" first-command)
  (check (eq? keys-test/completions:prefix-map (tables:ref prefixed-keymap "C-c p" #f)))
  (check (eq? keys-test/completions:prefix-map (keys:lookup-in (list prefixed-keymap) "C-c p")))
  (check-equal? keys-test/completions:file (keys:lookup-in (list prefixed-keymap) "C-c p f")))

(test "a binding under another module's prefix keymap keeps its prefix when that module unloads, and goes with its own module"
  (load-module! '(keys-test prefix-binder))
  (load-module! '(keys-test under-prefix))
  (let ([under (keys:lookup client "C-c q x")])
    (check (commands:command? under))
    (unload-owner! (module-owner '(keys-test prefix-binder)))
    (check-equal? under (keys:lookup client "C-c q x")))
  (unload-owner! (module-owner '(keys-test under-prefix)))
  (check-equal? #f (keys:lookup client "C-c q x"))
  (check-equal? #f (tables:ref keys:global "C-c q" #f)))

(test "bindings are their binder's changes: unloading a binder takes its bindings back and leaves another's mark of the same prefix"
  (load-module! '(keys-test prefix-binder))
  (keys:bind! keys:global "C-c q m" first-command)
  (check-equal? (current-owner) (tables:owner keys:global "C-c q m"))
  (check-equal? (current-owner) (tables:owner keys:global "C-c q"))
  (unload-owner! (module-owner '(keys-test prefix-binder)))
  (check-equal? (current-owner) (tables:owner keys:global "C-c q"))
  (check-equal? first-command (keys:lookup client "C-c q m"))
  (check-equal? '("C-c q m") (keys:where-is client first-command))
  (keys:unbind! keys:global "C-c q m")
  (keys:unbind! keys:global "C-c q"))

(test "a module's unbinding hides only the bindings of owners ranked below it, so a binding of the test's own stays"
  (keys:bind! keys:global "C-c q n" second-command)
  (load-module! '(keys-test unbinder))
  (check-equal? second-command (tables:ref keys:global "C-c q n" #f))
  (unload-owner! (module-owner '(keys-test unbinder)))
  (check-equal? (current-owner) (tables:owner keys:global "C-c q n"))
  (keys:unbind! keys:global "C-c q n"))

(test "a task spawned as a module's owner binds as that module"
  (let ([owner (module-owner '(keys-test completions))])
    (test-runner:join (call-as-owner owner (lambda () (spawn-task (lambda (restore) (keys:bind! keys:global "C-c q p" first-command))))))
    (check-equal? owner (tables:owner keys:global "C-c q p"))))

(test "the active keymaps are the temporary ones, newest first, then the entries of find-keymaps in the hook's order, then the global keymap"
  (tables:define-table inner-a)
  (tables:define-table inner-b)
  (tables:define-table outer-c)
  (tables:define-table temporary-1)
  (tables:define-table temporary-2)
  (let ([inner (lambda (client posn) (list inner-a inner-b))] [outer (lambda (client posn) (list outer-c))]
        [one (test-user:client)] [two (test-user:open-client)]
        [all (list inner-a inner-b outer-c temporary-1 temporary-2 keys:global)])
    (hooks:add! keys:find-keymaps inner)
    (hooks:add! keys:find-keymaps outer 10)
    (let* ([end1 (keys:push-keymap! one temporary-1 (lambda (found command) #t))]
           [end2 (keys:push-keymap! one temporary-2 (lambda (found command) #t))])
      (check-equal? (list temporary-2 temporary-1 inner-a inner-b outer-c keys:global) (keymaps-among (keys:active-keymaps one) all))
      (check-equal? (list temporary-2 temporary-1) (list-head (keys:active-keymaps one) 2))
      (check-equal? keys:global (car (last-pair (keys:active-keymaps one))))
      (check-equal? (list inner-a inner-b outer-c keys:global) (keymaps-among (keys:active-keymaps two) all))
      (end2)
      (end2)
      (end1)
      (check-equal? (list inner-a inner-b outer-c keys:global) (keymaps-among (keys:active-keymaps one) all)))
    (hooks:remove! keys:find-keymaps inner)
    (hooks:remove! keys:find-keymaps outer)
    (web:close-client! two)))

(test "the first keymap that binds the sequence, or a longer one, decides"
  (tables:define-table deciding-a)
  (tables:define-table deciding-b)
  (keys:bind! deciding-a "C-c x" first-command)
  (keys:bind! deciding-b "C-c" second-command)
  (keys:bind! deciding-b "C-x o" third-command)
  (with-keymaps-entry (lambda (client posn) (list deciding-a deciding-b))
    (lambda ()
      (check (eq? deciding-a (keys:lookup client "C-c")))
      (check-equal? first-command (keys:lookup client "C-c x"))
      (check-equal? third-command (keys:lookup client "C-x o")))))

(test "an entry of find-keymaps that raises or returns what is not a list of keymaps is reported, and the others are searched"
  (tables:define-table searched-keymap)
  (let ([broken (lambda (client posn) (car '()))] [wrong (lambda (client posn) 'a)]
        [right (lambda (client posn) (list searched-keymap))] [found #f])
    (hooks:add! keys:find-keymaps broken 5)
    (hooks:add! keys:find-keymaps wrong 6)
    (hooks:add! keys:find-keymaps right 7)
    (check-equal? '("~s is not a pair" "an entry returned what is not a list of keymaps")
                  (keys-test:report-messages
                    (lambda () (set! found (keymaps-among (keys:active-keymaps client) (list searched-keymap keys:global))))))
    (check-equal? (list searched-keymap keys:global) found)
    (for-each (lambda (entry) (hooks:remove! keys:find-keymaps entry)) (list broken wrong right))))

(test "a warning in an entry of find-keymaps is reported, and the entry goes on"
  (tables:define-table warned-keymap)
  (let* ([found #f]
         [warned (lambda (client posn) (warning 'warned "careful") (list warned-keymap))]
         [reported (begin
                     (hooks:add! keys:find-keymaps warned 5)
                     (keys-test:reports-during (lambda () (set! found (memq warned-keymap (keys:active-keymaps client))))))])
    (hooks:remove! keys:find-keymaps warned)
    (check-equal? 1 (length reported))
    (check (warning? (car reported)))
    (check (pair? found))))

(test "one printing character with no binding in a keymap uses that keymap's <printing-char>, before the keymaps after it"
  (tables:define-table printing-a)
  (tables:define-table printing-b)
  (keys:bind! printing-a "<printing-char>" first-command)
  (keys:bind! printing-a "q" second-command)
  (keys:bind! printing-b "<printing-char>" third-command)
  (keys:bind! printing-b "SPC" third-command)
  (let ([both (list printing-a printing-b)])
    (check-equal? (list first-command first-command second-command third-command #f #f)
                  (map (lambda (k) (keys:lookup-in both k)) '("x" "é" "q" "SPC" "<f1>" "C-x")))
    (keys:unbind! printing-a "<printing-char>")
    (check-equal? third-command (keys:lookup-in both "x"))))

(test "ESC then a key is that key with M-, when ESC is no quit key, binds no command, and nothing binds ESC and the key"
  (tables:define-table meta-a)
  (tables:define-table meta-g)
  (keys:bind! meta-g "M-x" first-command)
  (keys:bind! meta-g "C-M-f" second-command)
  (keys:bind! meta-g "M-g g" third-command)
  (keys:bind! meta-g "C-x x" third-command)
  (let ([both (list meta-a meta-g)])
    (options:with ([keys:quit-keys '("C-g")])
      (check-equal? (list first-command second-command third-command #f #f #f #f)
                    (map (lambda (k) (keys:lookup-in both k)) '("ESC x" "ESC C-f" "ESC g g" "C-x ESC x" "ESC" "ESC ESC" "ESC M-x")))
      (keys:bind! meta-a "ESC x" third-command)
      (check-equal? third-command (keys:lookup-in both "ESC x"))
      (keys:unbind! meta-a "ESC x")
      (keys:bind! meta-a "ESC" first-command)
      (check-equal? #f (keys:lookup-in both "ESC C-f")))
    (keys:unbind! meta-a "ESC")
    (check-equal? #f (keys:lookup-in both "ESC x"))))

(test "a sequence that finds nothing and whose last key has shift is looked up without it, and ESC X is M-X before it is M-x"
  (tables:define-table shift-keymap)
  (keys:bind! shift-keymap "<right>" first-command)
  (keys:bind! shift-keymap "C-f" first-command)
  (keys:bind! shift-keymap "C-n" second-command)
  (keys:bind! shift-keymap "M-x" third-command)
  (keys:bind! shift-keymap "C-x o" third-command)
  (let ([in (lambda (k) (keys:lookup-in (list shift-keymap) k))])
    (options:with ([keys:quit-keys '("C-g")])
      (check-equal? (list first-command first-command second-command third-command third-command third-command #f)
                    (map in '("S-<right>" "C-F" "C-N" "M-X" "ESC X" "C-x O" "C-S-<f1>")))
      (keys:bind! shift-keymap "C-F" second-command)
      (keys:bind! shift-keymap "M-X" first-command)
      (check-equal? second-command (in "C-F"))
      (check-equal? first-command (in "ESC X")))))

(test "the command found is remapped by the first keymap searched that remaps it, and a replacement is not remapped again"
  (tables:define-table remap-a)
  (tables:define-table remap-g)
  (keys:bind! remap-g "<right>" first-command)
  (keys:bind! remap-g "C-f" first-command)
  (keys:bind! remap-a "q" second-command)
  (keys:remap! remap-g first-command second-command)
  (keys:remap! remap-a second-command third-command)
  (let ([both (list remap-a remap-g)])
    (check-equal? (list second-command second-command third-command) (map (lambda (k) (keys:lookup-in both k)) '("<right>" "C-f" "q")))
    (keys:remap! remap-a first-command third-command)
    (check-equal? third-command (keys:lookup-in both "<right>")))
  (check-equal? (list (cons "q" second-command)) (keys:bindings remap-a))
  (check-raises (keys-test:raised-by 'keys:remap! "not a command") (keys:remap! remap-a first-command 'x))
  (check-raises (keys-test:raised-by 'keys:remap! "not a command") (keys:remap! remap-a 'x first-command)))

(test "command-remapping gives the command the client's keymaps remap a command to, or #f"
  (tables:define-table remapping-keymap)
  (keys:remap! remapping-keymap first-command second-command)
  (with-keymaps-entry (lambda (client posn) (list remapping-keymap))
    (lambda ()
      (check-equal? second-command (keys:command-remapping client first-command))
      (check-equal? #f (keys:command-remapping client second-command))))
  (check-raises (keys-test:raised-by 'keys:command-remapping "not a command") (keys:command-remapping client 'x)))

(test "where-is lists the sequences that run a command now, remapping included, shortest first, walking a keymap bound inside itself once"
  (tables:define-table where-a)
  (tables:define-table where-g)
  (keys:bind! where-g "C-n" first-command)
  (keys:bind! where-g "M-g g" first-command)
  (keys:bind! where-g "<right>" second-command)
  (keys:bind! where-a "C-f" second-command)
  (keys:bind! where-a "C-c P" keys-test/completions:prefix-map)
  (keys:remap! where-a second-command first-command)
  (with-keymaps-entry (lambda (client posn) (list where-a where-g))
    (lambda ()
      (check-equal? '("C-f" "C-n" "<right>" "M-g g")
                    (filter (lambda (k) (member k '("C-n" "C-f" "<right>" "M-g g"))) (keys:where-is client first-command)))
      (check-equal? '() (keys:where-is client second-command))
      (check-equal? '("C-c P f") (keys:where-is client keys-test/completions:file))
      (keys:bind! where-a "C-z" where-a)
      (check-equal? '("C-c P d") (keys:where-is client keys-test/completions:dabbrev))))
  (check-raises (keys-test:raised-by 'keys:where-is "not a command") (keys:where-is client 'x)))

(test "active-bindings gives each active keymap with the bindings it decides, through prefix keymaps, remapped, and a posn gives the keymaps at it"
  (tables:define-table decided-d)
  (tables:define-table decided-e)
  (tables:define-table decided-g)
  (keys:bind! decided-d "C-c z a" first-command)
  (keys:bind! decided-d "C-c z p" keys-test/completions:prefix-map)
  (keys:bind! decided-g "C-c z a" second-command)
  (keys:bind! decided-g "C-c z b" second-command)
  (keys:bind! decided-e "C-c z a" keys-test/completions:dabbrev)
  (keys:remap! decided-d second-command third-command)
  (test-user:show! "|text")
  (let ([posn (keys-test:posn-at 0)])
    (with-keymaps-entry (lambda (client posn) (if posn (list decided-e decided-g) (list decided-d decided-g)))
      (lambda ()
        (let ([typed (keys:active-bindings client)] [clicked (keys:active-bindings client posn)])
          (check-equal? (list (cons "C-c z a" first-command) (cons "C-c z p f" keys-test/completions:file)
                              (cons "C-c z p d" keys-test/completions:dabbrev))
                        (cdr (assq decided-d typed)))
          (check-equal? (list (cons "C-c z b" third-command)) (cdr (assq decided-g typed)))
          (check-equal? (list (cons "C-c z a" keys-test/completions:dabbrev)) (cdr (assq decided-e clicked)))
          (check-equal? #f (assq decided-d clicked))
          (check-equal? (list (cons "C-c z b" second-command)) (cdr (assq decided-g clicked)))
          (check-equal? (map car typed) (keys:active-keymaps client))
          (check-equal? typed (keys:active-bindings client #f))
          (check-equal? (keys:active-keymaps client posn) (map car clicked)))))))

(test "a binding of a command whose module has unloaded is not listed by active-bindings"
  (tables:define-table unloaded-keymap)
  (load-module! '(keys-test under-prefix))
  (load-module! '(keys-test prefix-binder))
  (keys:bind! unloaded-keymap "C-c y" (keys:lookup client "C-c q x"))
  (unload-owner! (module-owner '(keys-test under-prefix)))
  (with-keymaps-entry (lambda (client posn) (list unloaded-keymap))
    (lambda () (check-equal? '() (cdr (assq unloaded-keymap (keys:active-bindings client))))))
  (unload-owner! (module-owner '(keys-test prefix-binder))))

(test "lookup-in looks keys up in the keymaps given by press!'s one rule, a prefix keymap included, and checks its arguments"
  (tables:define-table in-first)
  (tables:define-table in-second)
  (tables:define-table in-inner)
  (keys:bind! in-first "k" first-command)
  (keys:bind! in-second "<printing-char>" second-command)
  (keys:bind! in-second "x k" third-command)
  (keys:bind! in-second "C-c" in-inner)
  (keys:bind! in-inner "i" first-command)
  (let ([both (list in-first in-second)])
    (check-equal? (list first-command second-command second-command third-command first-command #f #f)
                  (map (lambda (k) (keys:lookup-in both k)) '("k" "q" "K" "x k" "C-c i" "x z" "M-q")))
    (check-equal? first-command (keys:lookup-in (list in-first) "K"))
    (check (eq? in-second (keys:lookup-in both "x")))
    (check (eq? in-inner (keys:lookup-in both "C-c")))
    (keys:remap! in-second first-command second-command)
    (check-equal? second-command (keys:lookup-in both "k"))
    (check-raises (keys-test:raised-by 'keys:lookup-in "not a list of keymaps") (keys:lookup-in 'x "k"))
    (check-raises (keys-test:raised-by 'keys:lookup-in "not a valid key sequence") (keys:lookup-in both "C-"))))

(test "lookup takes an event, looked up in the keymaps at its position with press!'s fallbacks, for any client"
  (tables:define-table near-keymap)
  (keys:bind! near-keymap "<mouse-9>" first-command)
  (test-user:show! "|text")
  (let ([posn (keys-test:posn-at 1)])
    (with-keymaps-entry (lambda (client posn) (if posn (list near-keymap) '()))
      (lambda ()
        (check-equal? first-command (keys:lookup 'any-client (list "<mouse-9>" posn)))
        (check-equal? first-command (keys:lookup 'any-client (list "<drag-mouse-9>" posn posn)))
        (check-equal? first-command (keys:lookup 'any-client (list "S-<double-mouse-9>" posn)))
        (check-equal? #f (keys:lookup 'any-client "<mouse-9>"))
        (check (memq near-keymap (keys:active-keymaps 'any-client posn)))
        (check (not (memq near-keymap (keys:active-keymaps 'any-client))))))))

(test "sequence-keys gives the keys of the page's example sequences"
  (check-equal? '("C-x" "4" "C-f") (keys:sequence-keys "C-x 4 C-f"))
  (check-equal? '("C--" "SPC") (keys:sequence-keys "C-- SPC")))

(test "the page script is in web's scripts"
  (check-equal? "keys/keys.js" (tables:ref web:scripts 'keys #f)))

(test "binding keys to keys:undefined hides a binding a keymap searched later makes, and M-x offers neither ignore nor undefined"
  (tables:define-table hiding-keymap)
  (tables:define-table hidden-keymap)
  (keys:bind! hiding-keymap "C-n" keys:undefined)
  (keys:bind! hidden-keymap "C-n" first-command)
  (check-equal? keys:undefined (keys:lookup-in (list hiding-keymap hidden-keymap) "C-n"))
  (check-equal? '(() ()) (map (lambda (c) (tables:ref commands:command-modes c #f)) (list keys:ignore keys:undefined))))
