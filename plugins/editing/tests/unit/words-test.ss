;;; The editing plugin's word commands through the real editor loop:
;;; moving over words, killing them onto the kill ring, marking,
;;; transposing and changing their case, and shift selection with them.
(import :std/test
        :tuna/kernel
        :tuna/plugins/buffers/contract
        :tuna/plugins/editing/contract
        :tuna/plugins/commands/plugin
        :tuna/plugins/keys/plugin
        :tuna/plugins/text-store/plugin
        :tuna/plugins/settings/plugin
        :tuna/plugins/buffers/plugin
        :tuna/plugins/editing/plugin
        "../../../../tuna/tests/support/kernel"
        "../../../keys/tests/support/keys"
        (only-in "../../../../tuna/tests/support/string-input" test-messages current-message))
(export words-test)

(def words-plugins
  [commands keys test-messages rope-text-store settings buffers editing])

;; The text, point, the mark, whether the region is active and the
;; message, once every key sent so far has run.
(def (state)
  (call-on-editor-loop
   (lambda ()
     (let (v (selected-view))
       [(text-string (current-text)) (point) (view-mark v) (region-active?) (current-message)]))))

;; Start the editor loop with TEXT in *scratch* and point at POSITION.
(def (start-with! (text : :string) (position : :fixnum)) => :void
  (start-editor-loop!)
  (call-on-editor-loop (lambda () (insert text) (goto-char position))))

;; Point after each of KEYS.
(def (points-after . keys)
  (map (lambda (key) (type! key) (call-on-editor-loop point)) keys))

;; The newest N texts on the kill ring, newest first; this moves the yank
;; pointer.
(def (kills (n : :fixnum)) => :list
  (call-on-editor-loop
   (lambda () (cons (current-kill 0) (map (lambda (_) (current-kill 1)) (iota (fx1- n)))))))

(def words-test
  (test-suite "tuna/plugins/editing/words"
    (test-case "M-f and M-b stop at word ends and starts; punctuation and other non-letters separate words"
      (call-with-fresh-kernel words-plugins
       (lambda ()
         ;; "—" is an em dash; "$5%" is one word, as in Emacs's standard syntax table.
         (start-with! "foo-bar, naïve—café 中文 $5%" 1)
         (check (points-after "M-f" "M-f" "M-f" "M-f" "M-f" "M-f" "M-f")
                => [4 8 15 20 23 27 27])
         (check (current-message) => "")
         (check (points-after "M-b" "C-<left>" "M-<left>" "M-b" "M-b" "M-b" "M-b" "M-b")
                => [24 21 16 10 5 1 1 1])
         (check (points-after "C-<right>" "M-<right>") => [4 8])
         (check (current-message) => ""))))

    (test-case "M-DEL and M-d kill words; consecutive kills make one kill, which C-y yanks back"
      (call-with-fresh-kernel words-plugins
       (lambda ()
         (let (seen [])
           (defplugin (watcher ctx) "Records killed texts."
             (context-add-hook! ctx kill-new-hook 'watcher (lambda (text) (set! seen (cons text seen)))))
           (activate-plugin! watcher)
           (start-with! "one two three four" 19)
           (type! "M-DEL" "C-DEL")
           (check (state) => ["one two " 9 #f #f ""])
           (check (kills 1) => ["three four"])
           (check seen => ["three four" "four"])
           (type! "C-y")
           (check (state) => ["one two three four" 19 9 #f "Mark set"])
           (call-on-editor-loop (lambda () (goto-char 1)))
           (type! "M-d" "C-<delete>")
           (check (state) => [" three four" 1 2 #f ""])
           (check (kills 2) => ["one two" "three four"])
           ;; A kill after another command starts a new one.
           (type! "C-f" "M-d")
           (check (state) => ["  four" 2 2 #f ""])
           (check (kills 3) => ["three" "one two" "three four"])))))

    (test-case "M-d with no word after point kills to the end of the text"
      (call-with-fresh-kernel words-plugins
       (lambda ()
         (start-with! "word  " 5)
         (type! "M-d")
         (check (state) => ["word" 5 #f #f ""]))))

    (test-case "shifted word motions select; an unshifted one ends the selection"
      (call-with-fresh-kernel words-plugins
       (lambda ()
         (start-with! "abc def ghi" 1)
         (type! "M-F")
         (check (state) => ["abc def ghi" 4 1 #t ""])
         (type! "C-S-<right>")
         (check (state) => ["abc def ghi" 8 1 #t ""])
         (type! "C-S-<left>")
         (check (state) => ["abc def ghi" 5 1 #t ""])
         (type! "M-f")
         (check (state) => ["abc def ghi" 8 1 #f ""]))))

    (test-case "M-@ marks the next word, and again the one after; C-w kills them"
      (call-with-fresh-kernel words-plugins
       (lambda ()
         (start-with! "ab cd ef" 1)
         (type! "M-@")
         (check (state) => ["ab cd ef" 1 3 #t "Mark set"])
         (type! "M-@")
         (check (state) => ["ab cd ef" 1 6 #t ""])
         (type! "C-w")
         (check (state) => [" ef" 1 1 #f ""]))))

    (test-case "M-t swaps the words around point and leaves point after them"
      (call-with-fresh-kernel words-plugins
       (lambda ()
         (start-with! "one, two three" 4)
         (type! "M-t")
         (check (state) => ["two, one three" 9 #f #f ""])
         (type! "M-t")
         (check (state) => ["two, three one" 15 #f #f ""])
         (type! "M-t")
         (check (state) => ["two, three one" 15 #f #f "Don't have two things to transpose"]))))

    (test-case "M-u, M-l and M-c change the case from point to the end of the word, moving over it"
      (call-with-fresh-kernel words-plugins
       (lambda ()
         (start-with! "hello wORLD, élan" 1)
         (type! "M-u")
         (check (state) => ["HELLO wORLD, élan" 6 #f #f ""])
         (type! "M-c")
         (check (state) => ["HELLO World, élan" 12 #f #f ""])
         (type! "M-c")
         (check (state) => ["HELLO World, Élan" 18 #f #f ""])
         (type! "C-a" "M-l")
         (check (state) => ["hello World, Élan" 6 #f #f ""])
         ;; Inside a word, only the part after point changes.
         (call-on-editor-loop (lambda () (goto-char 3)))
         (type! "M-c")
         (check (state) => ["heLlo World, Élan" 6 #f #f ""]))))))
