(import (tuna) (test) (test-user) (test-runner) (tables) (keys) (commands) (layout) (views) (minibuffer) (completion) (completion-list) (editing)
        (completion-test sessions))

(define (raised? who message)
  (lambda (c)
    (and (who-condition? c) (eq? who (condition-who c))
         (message-condition? c) (string=? message (condition-message c)))))

(define (quit! r)
  (test-user:press! "C-g")
  (check-raises cancelled? (completion-test/sessions:result r)))

(define (reading sources) (completion-test/sessions:start! (lambda () (completion:read "? " sources #f))))

(define (titles s) (map (lambda (m) (completion:title s m)) (completion-test/sessions:matches s)))

(define (selected) (completion-test/sessions:selected-text (completion-test/sessions:session)))

(define (fruit-title text value) (if (memv (string-ref text 0) '(#\a #\b)) "Early" "Late"))

(define fruit
  (completion:source
    (candidates (vector "cherry" "apple" "date" "banana" "avocado"))
    (group fruit-title)
    (styles (list completion:substring))))

(test "a group clause's titles bring each group's matches together, groups in the order of their first match"
  (let* ([r (reading (list fruit))] [s (completion-test/sessions:session)])
    (check-equal? '("date" "cherry" "apple" "banana" "avocado") (completion-test/sessions:texts s))
    (check-equal? '("Late" "Late" "Early" "Early" "Early") (titles s))
    (check (eq? (car (titles s)) (cadr (titles s))))
    (test-user:type! "a")
    (check-equal? '("date" "apple" "banana" "avocado") (completion-test/sessions:texts s))
    (quit! r)))

(test "with an in-order source, the groups come in the order of the candidates"
  (let* ([r (reading (list (completion:source (candidates (vector "b1" "a1" "b2" "c1" "a2")) (in-order)
                             (group (lambda (text value) (string (string-ref text 0)))))))]
         [s (completion-test/sessions:session)])
    (check-equal? '("b1" "b2" "a1" "a2" "c1") (completion-test/sessions:texts s))
    (check-equal? '("b" "b" "a" "a" "c") (titles s))
    (quit! r)))

(test "a row procedure gives the text a row shows under its title, and spans are found in that text"
  (let* ([lines (completion:source
                  (candidates (vector (cons "notes.txt:1:needle" 1) (cons "notes.txt:2:hay" 2) (cons "todo.txt:1:needle" 3)))
                  (in-order)
                  (styles (list completion:any-order))
                  (group (lambda (text value) (substring text 0 (- (string-length text) (if (= value 2) 6 9))))
                         (lambda (text value) (substring text (- (string-length text) (if (= value 2) 5 8)) (string-length text)))))]
         [r (reading (list lines))]
         [s (completion-test/sessions:session)])
    (test-user:type! "need")
    (check-equal? '(("notes.txt" "1:needle" ((2 6 completion.match-0))) ("todo.txt" "1:needle" ((2 6 completion.match-0))))
      (map (lambda (m) (list (completion:title s m) (completion:row-text s m) (completion:spans s m))) (completion-test/sessions:matches s)))
    (quit! r)))

(test "a read whose group title procedure returns what is not a string raises"
  (let ([r (reading (list (completion:source (candidates (vector "a")) (group (lambda (t v) 'x)))))])
    (check-raises (raised? 'completion:source "a group's title procedure returned what is not a string") (completion-test/sessions:result r))))

(test "M-} and M-{ select the first match of the next and the previous group, stopping at the ends; a source without groups is one"
  (let ([r (reading (list fruit (completion:source (candidates (vector "fig" "grape")) (title "More"))))])
    (check-equal? "date" (selected))
    (test-user:press! "M-}")
    (check-equal? "apple" (selected))
    (test-user:press! "M-}")
    (check-equal? "fig" (selected))
    (test-user:press! "M-}")
    (check-equal? "fig" (selected))
    (test-user:press! "M-{")
    (check-equal? "apple" (selected))
    (test-user:press! "C-u 2 M-{")
    (check-equal? "date" (selected))
    (test-user:press! "C-u 2 M-}")
    (check-equal? "fig" (selected))
    (quit! r)))

(test "a negative count moves between groups the other way"
  (let ([r (reading (list (completion:source (candidates (vector "apple" "apricot" "banana" "blueberry" "cherry")) (in-order)
                            (group (lambda (text value) (string (string-ref text 0)))))))])
    (test-user:press! "M-} M-}")
    (check-equal? "cherry" (selected))
    (test-user:press! "C-u - M-}")
    (check-equal? "banana" (selected))
    (test-user:press! "M-- M-{")
    (check-equal? "cherry" (selected))
    (quit! r)))

(test "across a group of a million, M-} and M-{ land on the groups' first matches"
  (let* ([million (completion:source
                    (candidates (let ([v (make-vector 1000000)])
                                  (do ([i 0 (+ i 1)]) ((= i 1000000) v) (vector-set! v i (number->string i)))))
                    (in-order)
                    (group (lambda (text value) (if (string=? text "999999") "small" "big"))))]
         [r (reading (list million))]
         [s (completion-test/sessions:session)])
    (completion-test/sessions:wait-matches s)
    (check-equal? 1000000 (completion:matches-count (completion:session-matches s)))
    (check-equal? "0" (selected))
    (test-user:press! "M-}")
    (check-equal? "999999" (selected))
    (test-user:press! "M-{")
    (check-equal? "0" (selected))
    (quit! r)))

(define buffers-like (completion:source (candidates (vector "notes" "todo")) (title "Buffers") (narrow #\b)))

(define files-like (completion:source (candidates (vector "notes.txt" "init.ss")) (title "Files") (narrow #\f)))

(define (narrowable) (completion-test/sessions:start! (lambda () (completion:read-or-input "? " (list buffers-like files-like) #f))))

(test "a narrow character then SPC shows only its sources and clears the input; the read answers with their candidates"
  (let* ([r (narrowable)] [s (completion-test/sessions:session)])
    (check-equal? '("todo" "notes" "init.ss" "notes.txt") (completion-test/sessions:texts s))
    (check-equal? #f (completion:narrowed s))
    (test-user:type! "f ")
    (check-equal? "" (completion-test/sessions:input))
    (check-equal? '("init.ss" "notes.txt") (completion-test/sessions:texts s))
    (check-equal? "Files" (completion:narrowed s))
    (test-user:type! "no")
    (check-equal? '("notes.txt") (completion-test/sessions:texts s))
    (test-user:press! "RET")
    (check-equal? "notes.txt" (completion-test/sessions:result r))))

(test "a narrowed read lists only its sources' candidates, and DEL on its empty input widens"
  (let* ([r (narrowable)] [s (completion-test/sessions:session)])
    (test-user:type! "b ")
    (check-equal? '("todo" "notes") (completion-test/sessions:texts s))
    (test-user:type! "init.ss")
    (check-equal? '() (completion-test/sessions:texts s))
    (test-user:press! "DEL DEL DEL DEL DEL DEL DEL")
    (check-equal? "" (completion-test/sessions:input))
    (check-equal? "Buffers" (completion:narrowed s))
    (test-user:press! "DEL")
    (check-equal? #f (completion:narrowed s))
    (check-equal? '("todo" "notes" "init.ss" "notes.txt") (completion-test/sessions:texts s))
    (quit! r)))

(test "SPC after a character that is no narrow character, or after more than one, types a space"
  (let* ([r (narrowable)] [s (completion-test/sessions:session)])
    (test-user:type! "x ")
    (check-equal? "x " (completion-test/sessions:input))
    (test-user:press! "C-a C-k")
    (test-user:type! "bb ")
    (check-equal? "bb " (completion-test/sessions:input))
    (check-equal? #f (completion:narrowed s))
    (quit! r)))

(test "narrow-by-input on an input that is no narrow character is refused"
  (keys:bind! keys:global "C-c b" completion:narrow-by-input)
  (let ([r (narrowable)])
    (check-equal? '("the input is not one narrow character")
      (map condition-message (test-runner:reports-during (lambda () (test-user:press! "C-c b")))))
    (quit! r))
  (keys:unbind! keys:global "C-c b"))

(test "a read of one source cannot be narrowed: its narrow character then SPC types a space"
  (let ([r (reading (list buffers-like))])
    (test-user:type! "b sc")
    (check-equal? "b sc" (completion-test/sessions:input))
    (check-equal? #f (completion:narrowed (completion-test/sessions:session)))
    (check-equal? '() (completion:narrow-characters (completion-test/sessions:session)))
    (quit! r)))

(test "completion:narrowing-keymap is empty by default, so no prefix narrows"
  (check-equal? '() (tables:entries completion:narrowing-keymap))
  (let ([r (narrowable)])
    (test-user:type! "<f")
    (check-equal? "<f" (completion-test/sessions:input))
    (check-equal? #f (completion:narrowed (completion-test/sessions:session)))
    (quit! r)))

(test "a prefix bound to completion:narrow-key-keymap narrows by the next character and keeps the input; one no source has widens"
  (keys:bind! completion:narrowing-keymap "<" completion:narrow-key-keymap)
  (let* ([r (narrowable)] [s (completion-test/sessions:session)])
    (test-user:type! "not")
    (test-user:press! "< f")
    (check-equal? (list "not" "Files" '("notes.txt")) (list (completion-test/sessions:input) (completion:narrowed s) (completion-test/sessions:texts s)))
    (test-user:press! "< <")
    (check-equal? (list "not" #f) (list (completion-test/sessions:input) (completion:narrowed s)))
    (test-user:press! "< b")
    (test-user:type! " ini")
    (test-user:press! "< x")
    (check-equal? (list "not ini" #f) (list (completion-test/sessions:input) (completion:narrowed s)))
    (test-user:press! "< f")
    (check-equal? '((#\b . "Buffers") (#\f . "Files")) (completion:narrow-characters s))
    (check-equal? '("not a character" "no character was typed")
      (map condition-message
           (test-runner:reports-during
             (lambda ()
               (for-each (lambda (arg) (views:call-with-view (layout:selected-view) (lambda () (commands:run completion:narrow arg))))
                 '("b" #f))))))
    (check-equal? "Files" (completion:narrowed s))
    (quit! r))
  (let ([r (reading (list fruit))])
    (test-user:type! "<a")
    (check-equal? "<a" (completion-test/sessions:input))
    (quit! r))
  (keys:unbind! completion:narrowing-keymap "<"))

(test "a read's categories are its sources', and a narrowed read's those of the sources it shows"
  (let ([r (narrowable)])
    (check-equal? '(#f #f) (completion:session-categories (completion-test/sessions:session)))
    (quit! r))
  (let* ([r (completion-test/sessions:start!
              (lambda ()
                (completion:read-or-input "? "
                  (list (completion:source (candidates (vector "notes" "todo")) (title "Buffers") (narrow #\b) (category completion:location-category))
                        (completion:source (candidates (vector "notes.txt")) (title "Files") (narrow #\f) (category completion:file-category)))
                  #f)))]
         [s (completion-test/sessions:session)])
    (check-equal? (list completion:location-category completion:file-category) (completion:session-categories s))
    (test-user:type! "f ")
    (check-equal? (list completion:file-category) (completion:session-categories s))
    (quit! r)))
