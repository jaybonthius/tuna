(import (tuna) (test) (markdown))

(define reply "## Plan\n\nFirst, **read** the *guide* at [the site](https://tuna.example \"Tuna\") and run `make check`.\nThen ~~skip~~ go on, as https://tuna.example/_docs/read_me says.\n\n- one\n- two, with **bold**\n  - nested *item*\n\n1. Build\n2. Test\n\n> Quoted **text**\n> - and a list\n\n| a | b |\n|---|---|\n| 1 | **2** |\n\n```scheme\n(define (f x) (* x 2))\n```\n\nDone.\n")

(define prefixes (map (lambda (n) (substring reply 0 n)) (iota (+ 1 (string-length reply)))))

(define (visible ds)
  (apply string-append
    (map (lambda (d)
           (cond
             [(string? d) d]
             [(vector? d) ""]
             [(memq (car d) '(markdown:code markdown:code-block)) ""]
             [else (visible (cddr d))]))
         ds)))

(define (marked? s) (exists (lambda (c) (memv c (string->list s))) '(#\* #\` #\~ #\[ #\] #\|)))

(define (kinds ds) (apply append (map (lambda (d) (if (pair? d) (cons (car d) (kinds (cddr d))) '())) ds)))

(define (counts ds)
  (map (lambda (kind) (length (filter (lambda (k) (eq? k kind)) (kinds ds)))) '(markdown:heading markdown:strong markdown:emphasis markdown:strikethrough)))

(test "each prefix of a streamed reply shows no marker of a construct still open, but a table's header row until its delimiter row"
  (let ([marked (filter (lambda (p) (marked? (visible (markdown:unfinished-blocks p)))) prefixes)])
    (check-equal? '(267 277 "| a | b |\n|")
                  (list (string-length (car marked)) (string-length (car (last-pair marked)))
                        (substring reply (- (string-length (car marked)) 1) (string-length (car (last-pair marked))))))))

(test "no block of a prefix holds more headings or emphasis than the same block of the whole reply"
  (check-equal? '(1 4 2 1) (counts (markdown:blocks reply)))
  (let more? ([ps prefixes] [found '()])
    (if (null? ps)
        (check-equal? '() found)
        (more? (cdr ps)
               (if (let loop ([blocks (markdown:unfinished-blocks (car ps))] [finished (markdown:blocks reply)])
                     (and (pair? blocks) (pair? finished)
                          (or (exists > (counts (list (car blocks))) (counts (list (car finished))))
                              (loop (cdr blocks) (cdr finished)))))
                   (cons (car ps) found)
                   found)))))

(test "once all of it has arrived, it reads as the finished text does"
  (check-equal? (markdown:blocks reply) (markdown:unfinished-blocks reply)))

(define (reads text) (markdown:unfinished-blocks text))

(test "the page's examples"
  (check-equal? '((markdown:paragraph ((key . 0)) "Some " (markdown:strong () "bol") "\n")) (reads "Some **bol"))
  (check-equal? '((markdown:paragraph ((key . 0)) "See the spec\n")) (reads "See [the spec](https://spec.comm"))
  (check-equal? '((markdown:paragraph ((key . 0)) "Steps:\n")) (reads "Steps:\n-")))

(test "a code span, emphasis, strong emphasis and strikethrough left open are closed, nested or not; text after an opener's last word waits"
  (check-equal? '((markdown:paragraph ((key . 0)) "Run " (markdown:code () "make che") "\n")) (reads "Run `make che"))
  (check-equal? '((markdown:paragraph ((key . 0)) "a " (markdown:emphasis () "b " (markdown:emphasis () "c " (markdown:strikethrough () "d"))) "\n"))
                (reads "a *b _c ~~d"))
  (check-equal? '((markdown:paragraph ((key . 0)) (markdown:strong () "bold " (markdown:emphasis () "ital")) "\n")) (reads "**bold *ital"))
  (check-equal? '((markdown:paragraph ((key . 0)) (markdown:strong () "bold") "\n")) (reads "**bold "))
  (check-equal? '((markdown:heading ((key . 0) (level . 1)) "Head " (markdown:strong () "in") "\n")) (reads "# Head **in"))
  (check-equal? '((markdown:table ((key . 0) (columns . 2))
                                  (markdown:table-row ((key . 0) (header . #t)) (markdown:table-cell ((key . 0)) "a\n") (markdown:table-cell ((key . 1)) "b\n"))
                                  (markdown:table-row ((key . 1)) (markdown:table-cell ((key . 0)) "x\n") (markdown:table-cell ((key . 1)) (markdown:strong () "y") "\n"))))
                (reads "| a | b |\n|---|---|\n| x | **y")))

(test "an opener with nothing after it yet is left out, as is a lone marker that may start a list item"
  (check-equal? '((markdown:paragraph ((key . 0)) "Some\n")) (reads "Some **"))
  (check-equal? '((markdown:paragraph ((key . 0)) "Para\n")) (reads "Para\n*")))

(test "a link or image whose label, address or title is unfinished is its label, emphasis and all"
  (for-each (lambda (text) (check-equal? '((markdown:paragraph ((key . 0)) "See the spec\n")) (reads text)))
            '("See [the spec" "See [the spec]" "See [the spec]("))
  (check-equal? '((markdown:paragraph ((key . 0)) "See a diagram\n")) (reads "See ![a diagram"))
  (check-equal? '((markdown:paragraph ((key . 0)) "x label\n")) (reads "x [label](http://exa"))
  (check-equal? '((markdown:paragraph ((key . 0)) "label\n")) (reads "[label](https://x.y \"ti"))
  (check-equal? '((markdown:paragraph ((key . 0)) (markdown:strong () "bo") "ld\n")) (reads "[**bo**ld](https://x")))

(test "a last line of one or two - or =, after quote and list markers and indentation, is left out; three make a heading"
  (for-each (lambda (text) (check-equal? '((markdown:paragraph ((key . 0)) "Para\n")) (reads text)))
            '("Para\n-" "Para\n- " "Para\n -" "Para\n=" "Para\n--"))
  (check-equal? '((markdown:list ((key . 0) (ordered . #f) (tight . #t)) (markdown:item ((key . 0)) (markdown:paragraph ((key . 0)) "item\n"))))
                (reads "- item\n  -"))
  (check-equal? '((markdown:quote ((key . 0)) (markdown:paragraph ((key . 0)) "Para\n"))) (reads "> Para\n> -"))
  (check-equal? '((markdown:heading ((key . 0) (level . 2)) "Para\n")) (reads "Para\n---"))
  (check-equal? '((markdown:list ((key . 0) (ordered . #f) (tight . #t)) (markdown:item ((key . 0))))) (reads "-")))

(test "text that ended its paragraph with a blank line, and code, stay as written; markers that open nothing stay too"
  (check-equal? '((markdown:paragraph ((key . 0)) "**bold\n")) (reads "**bold\n\n"))
  (check-equal? '((markdown:code-block ((key . 0) (language . "scheme")) "(define **x\n")) (reads "```scheme\n(define **x"))
  (check-equal? '((markdown:list ((key . 0) (ordered . #f) (tight . #t))
                                 (markdown:item ((key . 0)) (markdown:paragraph ((key . 0)) "a\n") (markdown:code-block ((key . 1) (language . "")) "*x\n"))))
                (reads "- a\n  ```\n  *x"))
  (check-equal? '((markdown:paragraph ((key . 0)) "5 * 3 = snake_case_name\n")) (reads "5 * 3 = snake_case_name"))
  (check-equal? '((markdown:paragraph ((key . 0)) "a*b " (markdown:emphasis () "c") "\n")) (reads "a\\*b *c"))
  (check-equal? '() (reads "")))

(test "an address, bare or in angle brackets, is read whole, as md4c reads it, less the punctuation that ends a sentence"
  (check-equal? '((markdown:paragraph ((key . 0)) "See " (markdown:link ((href . "https://x.example/_private")) "https://x.example/_private")
                                      " and " (markdown:emphasis () "more") "\n"))
                (reads "See https://x.example/_private and *more"))
  (check-equal? '((markdown:paragraph ((key . 0)) "See " (markdown:link ((href . "https://x.example/a_b")) "https://x.example/a_b") " and "
                                      (markdown:link ((href . "http://www.example.com/~user")) "www.example.com/~user") "\n"))
                (reads "See <https://x.example/a_b> and www.example.com/~user"))
  (check-equal? '((markdown:paragraph ((key . 0)) (markdown:strong () (markdown:link ((href . "https://x.example/a_b")) "https://x.example/a_b"))
                                      " and " (markdown:emphasis () "see " (markdown:link ((href . "https://x.example/c_d")) "https://x.example/c_d")) "\n"))
                (reads "**https://x.example/a_b** and _see https://x.example/c_d_"))
  (check-equal? '((markdown:paragraph ((key . 0)) (markdown:strong () (markdown:link ((href . "https://x.example/a_b")) "https://x.example/a_b")) "\n"))
                (reads "**https://x.example/a_b")))

(test "a setext heading's underline and a quote's line of markers alone end the text before them"
  (check-equal? '((markdown:heading ((key . 0) (level . 2)) "**bold\n")) (reads "**bold\n---"))
  (check-equal? '((markdown:quote ((key . 0)) (markdown:paragraph ((key . 0)) "**bold\n"))) (reads "> **bold\n>"))
  (check-equal? '((markdown:quote ((key . 0)) (markdown:paragraph ((key . 0)) "**bold\n"))) (reads "> **bold\n> \n")))

(test "a link's tail is read as md4c reads it: an address in angle brackets holds no <, a title in parentheses no ("
  (check-equal? '((markdown:paragraph ((key . 0)) "[a](<b <c> " (markdown:emphasis () "d") "\n")) (reads "[a](<b <c> *d"))
  (check-equal? '((markdown:paragraph ((key . 0)) "[a](b (c (d) " (markdown:emphasis () "e") "\n")) (reads "[a](b (c (d) *e")))

(test "a link cut to its label is not cut again"
  (check-equal? '((markdown:paragraph ((key . 0)) "[a]\n")) (reads "[[a]](")))

(define (rep s n) (let ([p (open-output-string)]) (do ([i 0 (+ i 1)]) ((= i n)) (put-string p s)) (get-output-string p)))

(define (milliseconds thunk)
  (let ([t0 (current-time 'time-monotonic)])
    (thunk)
    (let ([d (time-difference (current-time 'time-monotonic) t0)])
      (+ (* 1000 (time-second d)) (quotient (time-nanosecond d) 1000000)))))

(test "hostile text takes time in proportion to its length"
  (check-equal? '()
    (filter (lambda (text) (> (milliseconds (lambda () (reads text))) 1000))
            (list (rep "[" 100000) (string-append (rep "_a " 20000) (rep "a* " 20000)) (string-append (rep "[" 20000) "a" (rep "]" 20000) "(")
                  (string-append (rep "[a " 10000) (rep "](c " 10000) "](d") (string-append (rep "[a](<" 20000) ">")))))

(test "only the last block is read again, so earlier blocks keep their keys"
  (check-equal? '((markdown:paragraph ((key . 0)) "First.\n") #(markdown:rule ((key . 1))) (markdown:paragraph ((key . 2)) "Second " (markdown:strong () "b") "\n"))
                (reads "First.\n\n---\n\nSecond **b")))
