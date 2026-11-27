(import (tuna) (test) (options) (buffers) (document) (buffers-test md) (buffers-test lists) (buffers-test form) (buffers-test cards) (buffers-test))

(define at buffers-test:at)

(define (fresh-md) (buffers-test:fresh buffers-test:md-datum))

(define (fresh-form) (buffers-test:fresh buffers-test:form-datum))

(test "a file buffer is one root node of text with a stop at every position inside it; its end is an empty line"
  (let ([file (buffers-test:fresh "ab\ncd\n")])
    (check-equal? '(1 2 3 4 5 6 7) (buffers-test:all-stops file))
    (buffers-test:backspace! file 4)
    (check-equal? '(buffers:text () "abcd\n") (buffers-test:root file)))
  (let* ([file (buffers-test:fresh "ab\ncd\n")] [killed (buffers-test:kill! file 2 5)])
    (buffers-test:yank! file 3 killed)
    (check-equal? '(buffers:text () "adb\nc\n") (buffers-test:root file))))

(test "a buffer code built has one stop per character and atom, which next-stop and previous-stop visit alike, and none after its last block"
  (let* ([md (fresh-md)] [stops (buffers-test:all-stops md)])
    (check-equal? buffers-test:md-datum (buffers-test:root md))
    (check-equal? stops (let loop ([p (car (reverse stops))] [acc '()]) (if p (loop (buffers:previous-stop md p) (cons p acc)) acc)))
    (check-equal? (string-length (document:text (buffers:document md))) (length stops))
    (check-equal? (at md "|Alpha") (buffers:next-stop md (at md "Title|\n")))
    (check-equal? (at md "Title|\n") (buffers:previous-stop md (at md "|Alpha")))))

(test "a link's edges are not sticky: each is one stop, outside the link"
  (let ([md (fresh-md)])
    (check-equal? (at md "Alpha |beta") (buffers:next-stop md (at md "Alpha| beta")))
    (check-equal? 'buffers-test/md:para (buffers-test:kind-at md (at md "Alpha |beta")))
    (check-equal? (at md "b|eta") (buffers:next-stop md (at md "Alpha |beta")))
    (check-equal? 'buffers-test/md:para (buffers-test:kind-at md (at md "beta| gamma")))
    (check-equal? (at md "beta |gamma") (buffers:next-stop md (at md "beta| gamma")))))

(test "an atom has one stop before it, and the next stop passes it in one step"
  (let* ([md (fresh-md)] [before-image (at md "Last |@")])
    (check (document:atom? (document:token (buffers:document md) before-image)))
    (check-equal? (+ before-image 1) (buffers:next-stop md before-image))))

(test "stops after a block's last line break: none, except at the root's end and in an inline node, where a line break is text"
  (check-equal? '(2 3 4 7 8 9) (buffers-test:all-stops (buffers-test:fresh (buffers-test/md:doc '() (buffers-test/md:para '() "ab\n") (buffers-test/md:para '() "cd\n")))))
  (check-equal? '(1 2 3 4) (buffers-test:all-stops (buffers-test:fresh "ab\n")))
  (check-equal? '(2 4 5 6) (buffers-test:all-stops (buffers-test:fresh (buffers-test/md:doc '() (buffers-test/md:para '() "x" (buffers-test/cards:field '() "a\n") "\n"))))))

(test "backspace at the start of a block joins it to the one before, as deleting a newline joins two lines"
  (let ([md (fresh-md)])
    (buffers-test:backspace! md (at md "|Alpha"))
    (check-equal? '(buffers-test/md:heading ((level . 1)) "TitleAlpha " (buffers-test/md:link ((href . "https://x")) "beta") " gamma.\n")
                  (car (buffers-test:children md)))))

(test "a region from the middle of a paragraph to the middle of a list's second item joins the item's rest to the paragraph"
  (let ([md (fresh-md)])
    (buffers:replace! md (at md "Al|pha") (at md "tw|o") "")
    (check-equal? '((buffers-test/md:para () "Alo\n") (buffers-test/lists:bulleted () (buffers-test/md:item () "three\n"))) (list-head (cdr (buffers-test:children md)) 2))))

(test "a kill from inside a link to inside an item is open two deep at each end, and its datum closes its open nodes"
  (let* ([md (fresh-md)] [piece (buffers-test:kill! md (at md "be|ta") (at md "on|e"))])
    (check-equal? '((buffers-test/md:para () (buffers-test/md:link ((href . "https://x")) "ta") " gamma.\n") (buffers-test/lists:bulleted () (buffers-test/md:item () "on")))
                  (document:datums piece))
    (check-equal? '(2 2) (list (document:open-start piece) (document:open-end piece)))
    (check-equal? '(buffers-test/md:para () "Alpha " (buffers-test/md:link ((href . "https://x")) "bee\n")) (cadr (buffers-test:children md)))))

(test "yanking a kill splits the paragraph there and joins the kill's open edges to the halves"
  (let* ([md (fresh-md)] [piece (buffers-test:kill! md (at md "Alpha |") (at md "on|e"))])
    (buffers-test:yank! md (at md "Last |@") piece)
    (check-equal? '((buffers-test/md:code ((lang . "scheme")) "(car x)\n") (buffers-test/md:para () "Last " (buffers-test/md:link ((href . "https://x")) "beta") " gamma.\n")
                    (buffers-test/lists:bulleted () (buffers-test/md:item () "on" #(buffers-test/md:image ((src . "a.png"))) " line.\n")))
                  (list-tail (buffers-test:children md) 3))
    (check-equal? "beta gamma.\non" (document:text piece))))

(test "a whole item killed and yanked between two others comes back as an item"
  (let* ([md (fresh-md)] [piece (buffers-test:kill! md (at md "|one") (at md "|two"))])
    (check-equal? '(buffers-test/lists:bulleted () (buffers-test/md:item () "two\n") (buffers-test/md:item () "three\n")) (caddr (buffers-test:children md)))
    (buffers-test:yank! md (at md "|three") piece)
    (check-equal? '(buffers-test/lists:bulleted () (buffers-test/md:item () "two\n") (buffers-test/md:item () "one\n") (buffers-test/md:item () "three\n")) (caddr (buffers-test:children md)))))

(test "a kind whose module is unloaded refuses edits inside its nodes, which can still be deleted whole; loading it again restores it"
  (let ([md (fresh-md)])
    (unload-owner! (module-owner '(buffers-test lists)))
    (check-equal? #f (buffers:kind 'buffers-test/lists:bulleted))
    (check-equal? '(refused "inside a node whose kind is not loaded")
      (buffers-test:refusal (lambda () (buffers:replace! md (at md "t|wo") (at md "t|wo") "x"))))
    (let* ([doc (buffers:document md)] [the-list (document:enclosing doc (document:node-start (document:enclosing doc (at md "t|wo"))))])
      (buffers:replace! md (document:node-start the-list) (document:node-end the-list) ""))
    (check-equal? 4 (length (buffers-test:children md)))
    (load-module! '(buffers-test lists))
    (check (buffers:kind? (buffers:kind 'buffers-test/lists:bulleted)))))

(test "a buffers-test/form: labels have no stops and refuse edits, fields hold one line, and a row's own text is its newline"
  (let* ([form (fresh-form)] [stops (buffers-test:all-stops form)])
    (check-equal? '() (filter (lambda (p) (eq? (buffers-test:kind-at form p) 'buffers-test/form:label)) stops))
    (check-equal? (at form "|John") (car stops))
    (check-equal? '(buffers-test/form:field buffers-test/form:field)
      (list (buffers-test:kind-at form (at form "John|")) (buffers-test:kind-at form (buffers:next-stop form (at form "John|")))))
    (let ([email (buffers:next-stop form (at form "John|"))])
      (buffers:replace! form email email "j@x.org"))
    (check-equal? '(buffers-test/form:row () (buffers-test/form:label () "Name: ") (buffers-test/form:field ((name . name)) "John") (buffers-test/form:label () "  Email: ")
                    (buffers-test/form:field ((name . email)) "j@x.org") "\n")
                  (car (buffers-test:children form))))
  (let ([form (fresh-form)])
    (check-equal? (make-list 4 '(refused "the node refuses the edit"))
      (list (buffers-test:refusal (lambda () (buffers-test:backspace! form (at form "|John"))))
            (buffers-test:refusal (lambda () (buffers-test:delete-forward! form (at form "John|"))))
            (buffers-test:refusal (lambda () (buffers:replace! form (at form "Jo|hn") (at form "fi|rst") "")))
            (buffers-test:refusal (lambda () (buffers:replace! form (at form "Jo|hn") (at form "Jo|hn") "\n")))))
    (check-equal? 0 (buffers:version form))))

(test "a field's text copies flat and yanks into another field; blocks yanked into a field go in as their text, which a field refuses with a newline"
  (let* ([form (fresh-form)] [piece (document:slice (buffers:document form) (at form "|John") (at form "John|"))])
    (check-equal? '(0 0) (list (document:open-start piece) (document:open-end piece)))
    (buffers-test:yank! form (at form "|first") piece)
    (check-equal? '(buffers-test/form:field ((name . notes)) "Johnfirst") (cadddr (cadr (buffers-test:children form)))))
  (let* ([form (fresh-form)] [md (fresh-md)] [piece (buffers-test:kill! md (at md "Alpha |") (at md "on|e"))])
    (check-equal? '(refused "the node refuses the edit") (buffers-test:refusal (lambda () (buffers-test:yank! form (at form "|first") piece)))))
  (let* ([form (fresh-form)] [md (fresh-md)] [piece (buffers-test:kill! md (at md "Alpha |") (at md "gamma|.\n"))])
    (buffers-test:yank! form (at form "|first") piece)
    (check-equal? '(buffers-test/form:field ((name . notes)) "beta gammafirst") (cadddr (cadr (buffers-test:children form))))))

(test "a form's stops end at its button, an atom, and visit each field's characters"
  (let ([form (fresh-form)])
    (check (document:atom? (document:token (buffers:document form) (buffers:next-stop form (at form "first|")))))
    (check-equal? #f (buffers:next-stop form (buffers:next-stop form (at form "first|"))))
    (check-equal? '(name name name name name email notes notes notes notes notes notes button)
      (map (lambda (p)
             (let ([t (document:token (buffers:document form) p)])
               (if (and (document:node? t) (document:atom? t))
                   'button
                   (document:node-attribute (document:enclosing (buffers:document form) p) 'name))))
           (buffers-test:all-stops form)))))

(test "the docs' form has its stops in its fields"
  (let ([form (buffers:make "*form*"
                (buffers-test/form:form '()
                  (buffers-test/form:row '() (buffers-test/form:label '() "Name: ") (buffers-test/form:field '((name . name)) "") "\n")
                  (buffers-test/form:row '() (buffers-test/form:label '() "Notes: ") (buffers-test/form:field '((name . notes)) "") "\n")))])
    (check-equal? '(11 25) (list (buffers:next-stop form 0) (buffers:next-stop form 11)))))

(test "a buffer whose only node is its root finds the stops that the same text has before another node"
  (let ([stop-answers (lambda (b n) (map (lambda (p) (list (buffers:stop b p) (buffers:next-stop b p) (buffers:previous-stop b p))) (iota n)))]
        [random-text (lambda (n) (list->string (map (lambda (i) (string-ref "ab \n" (random 4))) (iota n))))])
    (random-seed 5)
    (check
      (for-all
        (lambda (k)
          (let* ([text (random-text (random 30))]
                 [atom (vector 'document:raw-byte '((byte . 200)))]
                 [bare (buffers-test:fresh (list 'buffers:text '() text atom text))]
                 [other (buffers-test:fresh (list 'buffers:text '() text atom text '(buffers-test/md:link ())))]
                 [n (max 0 (- (document:length (buffers:document bare)) 3))])
            (equal? (stop-answers bare n) (stop-answers other n))))
        (iota 50)))))

(test "a grapheme cluster is one stop unless stop-inside-clusters is set in the buffer"
  (let ([b (buffers-test:fresh (string #\e #\x301 #\x #\newline))])
    (check-equal? '(1 3 4 5) (buffers-test:all-stops b))
    (check-equal? 1 (buffers:stop b 2))
    (buffers:with-buffer b (options:set-local! buffers:stop-inside-clusters #t))
    (check-equal? '(1 2 3 4 5) (buffers:with-buffer b (buffers-test:all-stops b)))))
