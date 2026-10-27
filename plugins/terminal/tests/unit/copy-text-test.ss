;;; Copy mode's text: rows as lines, where a row and a cell are in it, and
;;; copying without the line ends that only wrap.
(import :std/test
        :tuna/plugins/buffers/contract
        :tuna/plugins/terminal/copy-text)
(export copy-text-test)

(def (run (column : :fixnum) (text : :string) (classes : :string := "") (link :? :string := #f))
  (vector column (string-length text) text classes #f link))

(def copy-text-test
  (test-suite "tuna/plugins/terminal: copy mode's text"
    (test-case "each row is a line as the screen shows it, colours and links as spans"
      (let (c (rows->copy-text [(cons (vector (run 0 "ab") (run 4 "cd" "terminal-fg-1 terminal-bold")) #f)
                                (cons (vector (run 2 "see" "" "https://x.org")) #f)
                                (cons (vector) #f)]))
        (check (copy-text-text c) => "ab  cd\n  see\n")
        (check (copy-text-row-starts c) => (vector 1 8 14))
        (check (map (lambda (s) [(span-start s) (span-end s) (span-value s)]) (copy-text-spans c))
               => [[5 7 'terminal-fg-1] [10 13 'terminal-link]])
        (check (copy-text-link-at c 11) => "https://x.org")
        (check (copy-text-link-at c 9) => #f)
        (check (copy-text-row-of c 9) => 1)
        (check (copy-text-position c 1 2) => 10)
        ;; Past the end of its row, a position stays in the row.
        (check (copy-text-position c 0 99) => 7)))

    (test-case "copying drops the line ends that only wrap, and trailing spaces"
      (let (c (rows->copy-text [(cons (vector (run 0 "hello wor")) #t)
                                (cons (vector (run 0 "ld  ")) #f)
                                (cons (vector (run 0 "next")) #f)]))
        (check (copy-text-text c) => "hello wor\nld  \nnext")
        (check (copy-text-clean c 1 (fx1+ (string-length (copy-text-text c)))) => "hello world\nnext")
        (check (copy-text-clean c 7 13) => "world")))

    (test-case "a cell is found in a row's text past wide characters"
      ;; A wide character takes two cells and is one character.
      (let (runs (vector (vector 0 4 "a\x4e2d;b" "" #f #f) (vector 6 1 "z" "" #f #f)))
        (check (row-text runs) => "a\x4e2d;b  z")
        (check (cell->index runs 0) => 0)
        (check (cell->index runs 1) => 1)
        (check (cell->index runs 2) => 1)
        (check (cell->index runs 3) => 2)
        (check (cell->index runs 5) => 4)
        (check (cell->index runs 6) => 5)
        (check (cell->index runs 9) => 8)))))
