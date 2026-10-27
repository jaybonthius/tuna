;;; Links in a terminal's output: URLs and file references found in a line,
;;; put into a row's runs, and where a link leads.
(import :std/test
        :tuna/plugins/terminal/links)
(export links-test)

(def (no-files path) #f)

(def links-test
  (test-suite "tuna/plugins/terminal: links"
    (test-case "URLs end before sentence punctuation and unbalanced parentheses"
      (check (find-links "see https://example.com/a. (https://x.org/b) http://w.io/a_(b)c, done" #t #f no-files)
             => [[4 25 "https://example.com/a"] [28 43 "https://x.org/b"] [45 63 "http://w.io/a_(b)c"]])
      (check (find-links "https://example.com" #f #f no-files) => []))

    (test-case "file references link only to files that exist, with their line and column"
      (let (resolve (lambda (path) (and (member path ["src/a.ss" "./b.c"]) (string-append "/repo/" path))))
        (check (find-links "error at src/a.ss:12:3: oops, see ./b.c:7 and x/missing.ss:1" #f #t resolve)
               => [[9 22 "fileref:/repo/src/a.ss:12:3"] [34 41 "fileref:/repo/./b.c:7"]])
        (check (find-links "at /abs/f.ss:3 ok" #f #t (lambda (path) (and (equal? path "/abs/f.ss") path)))
               => [[3 14 "fileref:/abs/f.ss:3"]])
        ;; A URL is not also a file reference.
        (check (map caddr (find-links "https://h/src/a.ss:1" #t #t resolve)) => ["https://h/src/a.ss:1"])))

    (test-case "a link splits the runs it covers part of; an OSC 8 link stays"
      (let (runs (vector (vector 0 10 "go x.org/y" "terminal-bold" #f #f)
                         (vector 12 3 "osc" "" #f "https://osc")))
        (check (link-runs runs [[3 10 "fileref:/x.org/y"] [12 15 "https://other"]])
               => (vector (vector 0 3 "go " "terminal-bold" #f #f)
                          (vector 3 7 "x.org/y" "terminal-bold" #f "fileref:/x.org/y")
                          (vector 12 3 "osc" "" #f "https://osc")))))

    (test-case "where a link leads"
      (check (web-link? "https://a") => #t)
      (check (web-link? "javascript:alert(1)") => #f)
      (check (link-file-target "fileref:/repo/a.ss:12:3" "/home/" "box") => ["/repo/a.ss" 12 3])
      (check (link-file-target "file://box/tmp/a%20b" "/home/" "box") => ["/tmp/a b" #f #f])
      (check (link-file-target "file://elsewhere/tmp/a" "/home/" "box") => #f)
      (check (link-file-target "src/a.ss:4" "/repo/" "box") => ["/repo/src/a.ss" 4 #f])
      (check (link-file-target "mailto:me@x" "/repo/" "box") => #f))))
