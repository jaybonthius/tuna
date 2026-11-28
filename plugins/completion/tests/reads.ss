(import (tuna) (test) (test-user) (saved) (options) (hooks) (kill-ring) (buffers) (document) (views) (minibuffer) (completion) (completion-list) (editing)
        (completion-test sessions))

(saved:define-saved fruit-history '() list?)

(define fruits (vector "apple" "apricot" "banana" "blueberry" "cherry" "Cranberry"))

(define (fruit-source) (completion:source (candidates fruits)))

(define (read-fruit) (completion:read "Fruit: " (list (fruit-source)) fruit-history))

(define (read-fruit-or-input) (completion:read-or-input "Fruit: " (list (fruit-source)) fruit-history))

(define (selected) (completion-test/sessions:selected-text (completion-test/sessions:session)))

(define (texts) (completion-test/sessions:texts (completion-test/sessions:session)))

(define (quit! r)
  (test-user:press! "C-g")
  (check-raises cancelled? (completion-test/sessions:result r)))

(test "a read lists every candidate by history, then length, then alphabet, and selects the first"
  (saved:set! fruit-history '())
  (let ([r (completion-test/sessions:start! read-fruit)])
    (check-equal? '("apple" "banana" "cherry" "apricot" "Cranberry" "blueberry") (texts))
    (check-equal? "apple" (selected))
    (quit! r)))

(test "typing narrows the matches and selects the first of them"
  (let ([r (completion-test/sessions:start! read-fruit)])
    (test-user:type! "ap")
    (check-equal? '("apple" "apricot") (texts))
    (check-equal? "apple" (selected))
    (quit! r)))

(test "C-n and C-p move the selection and stop at the ends; M-< and M-> select the first and the last"
  (let ([r (completion-test/sessions:start! read-fruit)])
    (test-user:type! "ap")
    (test-user:press! "C-n")
    (check-equal? "apricot" (selected))
    (test-user:press! "C-n")
    (check-equal? "apricot" (selected))
    (test-user:press! "C-p")
    (check-equal? "apple" (selected))
    (test-user:press! "C-p")
    (check-equal? "apple" (selected))
    (test-user:press! "M->")
    (check-equal? "apricot" (selected))
    (test-user:press! "M-<")
    (check-equal? "apple" (selected))
    (quit! r)))

(test "a numeric argument moves that many matches"
  (let ([r (completion-test/sessions:start! read-fruit)])
    (test-user:press! "M-5 C-n")
    (check-equal? "blueberry" (selected))
    (test-user:press! "C-u 3 C-p")
    (check-equal? "cherry" (selected))
    (test-user:press! "C-u - 1 C-n")
    (check-equal? "banana" (selected))
    (quit! r)))

(test "C-v and M-v select a page of rows on, stopping at the ends; with none selected C-v counts from before the first"
  (options:set! completion-list:lines 15)
  (let ([r (completion-test/sessions:start!
             (lambda ()
               (completion:read "Row: "
                 (list (completion:source (candidates (list->vector (map (lambda (i) (format "row ~2,'0d" i)) (iota 40)))) (in-order)))
                 #f)))])
    (test-user:press! "C-v")
    (check-equal? "row 15" (selected))
    (test-user:press! "C-v C-v")
    (check-equal? "row 39" (selected))
    (test-user:press! "M-v")
    (check-equal? "row 24" (selected))
    (test-user:press! "M-v M-v")
    (check-equal? "row 00" (selected))
    (completion:select! (completion-test/sessions:session) #f)
    (test-user:press! "C-v")
    (check-equal? "row 14" (selected))
    (quit! r))
  (options:unset! completion-list:lines))

(test "in a read that takes any input, C-p and M-< on the first match keep it selected, and M-RET answers with the input"
  (let ([r (completion-test/sessions:start! read-fruit-or-input)])
    (test-user:type! "app")
    (test-user:press! "C-p")
    (check-equal? "apple" (selected))
    (test-user:press! "M-<")
    (check-equal? "apple" (selected))
    (test-user:press! "M-RET")
    (check-equal? "app" (completion-test/sessions:result r))))

(test "TAB makes the input the selected match's text, and the matches narrow to it"
  (let ([r (completion-test/sessions:start! read-fruit)])
    (test-user:type! "ap")
    (test-user:press! "C-n TAB")
    (check-equal? "apricot" (completion-test/sessions:input))
    (check-equal? '("apricot") (texts))
    (quit! r)))

(test "RET answers with the selected match, which goes first in the history and so first in the next read"
  (saved:set! fruit-history '())
  (let ([r (completion-test/sessions:start! read-fruit)])
    (test-user:type! "ap")
    (test-user:press! "C-n RET")
    (check-equal? "apricot" (completion-test/sessions:result r))
    (check-equal? '("apricot") (fruit-history)))
  (let ([r (completion-test/sessions:start! read-fruit)])
    (check-equal? '("apricot" "apple" "banana" "cherry" "Cranberry" "blueberry") (texts))
    (quit! r)))

(test "a read refuses an input that names no candidate with [No match], and M-RET answers with one that names one"
  (let ([r (completion-test/sessions:start!
             (lambda () (completion:read "Fruit: " (list (completion:source (candidates (vector "apple" (cons "pear" 'fruit))))) fruit-history)))])
    (test-user:type! "zzz")
    (test-user:press! "RET")
    (check-equal? 'waiting (completion-test/sessions:result r))
    (check-equal? "zzz" (completion-test/sessions:input))
    (check-equal? " [No match]" (completion-test/sessions:prompt-message))
    (test-user:press! "C-a C-k")
    (test-user:type! "app")
    (test-user:press! "M-RET")
    (check-equal? 'waiting (completion-test/sessions:result r))
    (check-equal? " [No match]" (completion-test/sessions:prompt-message))
    (test-user:press! "C-a C-k")
    (test-user:type! "pear")
    (test-user:press! "M-RET")
    (check-equal? 'fruit (completion-test/sessions:result r))))

(test "a read that takes any input answers RET with an input that names no candidate, as the string"
  (let ([r (completion-test/sessions:start! read-fruit-or-input)])
    (test-user:type! "applex")
    (check-equal? '() (texts))
    (test-user:press! "RET")
    (check-equal? "applex" (completion-test/sessions:result r)))
  (let ([r (completion-test/sessions:start! read-fruit-or-input)])
    (test-user:type! "xyz")
    (test-user:press! "M-RET")
    (check-equal? "xyz" (completion-test/sessions:result r))))

(test "the default sorts first and is selected, then the history newest first, and RET on an empty input answers with it"
  (saved:set! fruit-history '("cherry" "apple"))
  (let ([r (completion-test/sessions:start!
             (lambda () (completion:read-or-input "Fruit: " (list (fruit-source)) fruit-history "banana")))])
    (check-equal? '("banana" "cherry" "apple" "apricot" "Cranberry" "blueberry") (texts))
    (check-equal? "banana" (selected))
    (check-equal? "banana" (completion:session-default (completion-test/sessions:session)))
    (test-user:press! "RET")
    (check-equal? "banana" (completion-test/sessions:result r))
    (check-equal? '("banana" "cherry" "apple") (fruit-history))))

(test "in a read of several sources the source whose first match is the default comes first, so RET on an empty input chooses the row selected; once the default no longer matches, the sources keep their order"
  (let ([r (completion-test/sessions:start!
             (lambda ()
               (completion:read "Food: "
                 (list (completion:source (candidates (vector "carrot" "cabbage")) (title "Vegetables") (in-order))
                       (completion:source (candidates (vector "cherry" "banana")) (title "Fruit") (in-order)))
                 #f "banana")))])
    (check-equal? '("banana" "cherry" "carrot" "cabbage") (texts))
    (check-equal? "banana" (selected))
    (test-user:type! "c")
    (check-equal? '("carrot" "cabbage" "cherry") (texts))
    (test-user:press! "DEL RET")
    (check-equal? "banana" (completion-test/sessions:result r))))

(test "M-w puts the selected match on the kill ring and leaves the read open"
  (let ([r (completion-test/sessions:start! read-fruit)])
    (test-user:type! "ap")
    (test-user:press! "C-n M-w")
    (check-equal? "apricot" (kill-ring:text (kill-ring:current)))
    (check-equal? 'waiting (completion-test/sessions:result r))
    (quit! r)))

(test "a source's rank replaces the order by history, in-order keeps the candidates' order, and each source keeps its title"
  (let ([r (completion-test/sessions:start!
             (lambda ()
               (completion:read "? "
                 (list (completion:source (candidates (vector "b" "a" "c")) (rank (vector 2 0 1)) (title "Ranked"))
                       (completion:source (candidates (vector "zz" "yy" "xx")) (in-order) (title "In order")))
                 fruit-history)))])
    (let ([s (completion-test/sessions:session)])
      (check-equal? '(("a" "Ranked") ("c" "Ranked") ("b" "Ranked") ("zz" "In order") ("yy" "In order") ("xx" "In order"))
        (map (lambda (m) (list (completion:text s m) (completion:title s m))) (completion-test/sessions:matches s))))
    (quit! r)))

(test "TAB with none selected makes the input the longest common start of the matches, counted in characters"
  (let ([r (completion-test/sessions:start!
             (lambda ()
               (minibuffer:call-with-setup (lambda (p) (minibuffer:set-input! p "pre"))
                 (lambda () (completion:read "? " (list (completion:source (candidates (vector "prefix-one" "prefix-two" "other")))) #f)))))])
    (completion:select! (completion-test/sessions:session) #f)
    (test-user:press! "TAB")
    (check-equal? "prefix-" (completion-test/sessions:input))
    (quit! r))
  (for-each
    (lambda (candidates)
      (let ([r (completion-test/sessions:start!
                 (lambda () (completion:read "? " (list (completion:source (candidates candidates) (styles (list completion:substring)))) #f)))])
        (test-user:type! "abc")
        (check-equal? (vector->list candidates) (texts))
        (completion:select! (completion-test/sessions:session) #f)
        (test-user:press! "TAB")
        (check-equal? "abc" (completion-test/sessions:input))
        (quit! r)))
    (list (vector "ééXabc" "ééYabc") (vector "xxXabc" "xxYabc"))))

(test "a read selects the first match; a move keeps the selected candidate while it matches, until the input changes"
  (let ([r (completion-test/sessions:start! (lambda () (completion:read "? " (list (completion:source (candidates (vector "ab" "abc" "abcd")) (styles (list completion:substring)))) #f)))])
    (let ([s (completion-test/sessions:session)])
      (check-equal? "ab" (selected))
      (test-user:press! "C-n C-n")
      (check-equal? "abcd" (selected))
      (completion:input-changed! s)
      (check-equal? "abcd" (selected))
      (test-user:type! "c")
      (check-equal? "abc" (selected))
      (check-raises (lambda (e) (and (who-condition? e) (eq? 'completion:select! (condition-who e))))
        (completion:select! s 99)))
    (quit! r)))

(test "with completion:read-preselect none a read selects nothing until a move"
  (saved:set! fruit-history '())
  (options:set! completion:read-preselect 'none)
  (let ([r (completion-test/sessions:start! read-fruit)])
    (check-equal? #f (selected))
    (test-user:press! "C-n")
    (check-equal? "apple" (selected))
    (quit! r))
  (options:unset! completion:read-preselect))

(test "started, updated and ended follow a read; a change of the selection runs updated"
  (let* ([log '()]
         [note (lambda (what) (lambda (s) (set! log (cons (list what (completion:session-input s)) log))))]
         [on-started (note 'started)] [on-updated (note 'updated)] [on-ended (note 'ended)])
    (hooks:add! completion:started on-started)
    (hooks:add! completion:updated on-updated)
    (hooks:add! completion:ended on-ended)
    (let ([r (completion-test/sessions:start! (lambda () (completion:read "? " (list (completion:source (candidates (vector "ab" "cd")))) #f)))])
      (test-user:type! "a")
      (test-user:press! "C-n RET")
      (check-equal? "ab" (completion-test/sessions:result r)))
    (hooks:remove! completion:started on-started)
    (hooks:remove! completion:updated on-updated)
    (hooks:remove! completion:ended on-ended)
    (check-equal? '((started "") (updated "") (updated "a") (updated "a") (ended "ab")) (reverse log))))

(test "completion:session-prompt gives a read's prompt"
  (let ([r (completion-test/sessions:start! read-fruit)])
    (check (eq? (completion-test/sessions:prompt) (completion:session-prompt (completion-test/sessions:session))))
    (quit! r)))

(test "completion:start runs a session over any text: its bounds give the input, the caller reports edits, and exit calls accept"
  (let* ([tags (buffers:make (buffers:free-name "*tags*") "lisp")]
         [tags-view (views:make tags)]
         [saved-tag #f]
         [s (completion:start tags-view (list (completion:source (candidates (vector "lisp" "list" "listen" "scheme"))))
              (lambda () (values 1 (- (document:length (buffers:document tags)) 1)))
              (lambda (session match) (when match (set! saved-tag (completion:value session match))))
              'none)])
    (check-equal? '("lisp") (completion-test/sessions:texts s))
    (check-equal? #f (completion:selected s))
    (check-equal? #f (completion:session-prompt s))
    (check (eq? tags-view (completion:session-view s)))
    (buffers:replace! tags 4 5 "t")
    (completion:input-changed! s)
    (check-equal? '("list" "listen") (completion-test/sessions:texts s))
    (completion:select! s (completion:matches-ref (completion:session-matches s) 1))
    (views:call-with-view tags-view completion:exit)
    (check-equal? "listen" saved-tag)
    (check-equal? "listen" (completion-test/sessions:buffer-text tags))
    (completion:end! s)
    (completion:end! s)
    (views:drop! tags-view)
    (buffers:kill! tags)))

(define rows-source
  (completion:source (candidates (list->vector (map (lambda (i) (format "row ~2,'0d" i)) (iota 40)))) (in-order)))

(test "M-w saves the selected match's text; with none selected the input, or the read's default when the input is empty"
  (let ([r (completion-test/sessions:start! (lambda () (completion:read "? " (list rows-source) #f "row 07")))])
    (test-user:press! "C-n M-w")
    (check-equal? "row 00" (kill-ring:text (kill-ring:current)))
    (completion:select! (completion-test/sessions:session) #f)
    (test-user:press! "M-w")
    (check-equal? "row 07" (kill-ring:text (kill-ring:current)))
    (test-user:type! "row 3")
    (completion:select! (completion-test/sessions:session) #f)
    (test-user:press! "M-w")
    (check-equal? "row 3" (kill-ring:text (kill-ring:current)))
    (quit! r)))

(test "M-w saves a match's whole text: the base a stream emits is part of it, a prefix its split keeps is not"
  (let ([r (completion-test/sessions:start!
             (lambda ()
               (completion:read "? " (list (completion:source (candidates (vector "main" "more")) (split (lambda (input) (min 4 (string-length input)))))) #f)))])
    (test-user:type! "lib/ma")
    (test-user:press! "M-w")
    (check-equal? "main" (kill-ring:text (kill-ring:current)))
    (check-equal? "main" (completion:whole-text (completion-test/sessions:session) (completion:selected (completion-test/sessions:session))))
    (quit! r))
  (let* ([folder (lambda (emit)
                   (lambda (prefix)
                     (unless (eof-object? prefix)
                       (emit 'clear)
                       (emit (list 'base (string-length prefix)))
                       (emit (vector "main" "more"))
                       (emit 'done))))]
         [r (completion-test/sessions:start!
              (lambda () (completion:read "? " (list (completion:source (stream folder) (split (lambda (input) (min 4 (string-length input)))))) #f)))])
    (test-user:type! "lib/ma")
    (completion-test/sessions:wait-matches (completion-test/sessions:session))
    (test-user:press! "M-w")
    (check-equal? "lib/main" (kill-ring:text (kill-ring:current)))
    (quit! r)))

(test "with a region in the input, M-w saves the region"
  (let ([r (completion-test/sessions:start! read-fruit)])
    (test-user:type! "app")
    (test-user:press! "C-a C-SPC C-f C-f M-w")
    (check-equal? "ap" (kill-ring:text (kill-ring:current)))
    (quit! r)))
