;;; JSON lines as Pi frames them: split on LF only, a CR before it
;;; dropped, U+2028 kept inside a line, lines arriving in any pieces and
;;; of any length.
(import :std/test
        :tuna/plugins/pi/jsonl)
(export jsonl-test)

(def (feed (r : jsonl-reader) (text : :string)) => :list
  (jsonl-reader-feed! r (string->utf8 text)))

(def jsonl-test
  (test-suite "tuna/plugins/pi: JSON lines"
    (test-case "lines end at LF only; a CR before it is dropped; U+2028 is text"
      (let (r (new-jsonl-reader))
        (check (feed r "{\"a\":1}\r\n{\"b\":\"x\x2028;y\"}\n") => ["{\"a\":1}" "{\"b\":\"x\x2028;y\"}"])
        (check (feed r "a\rb\n") => ["a\rb"])))

    (test-case "a line split across reads, even inside a character, comes whole"
      (let ((r (new-jsonl-reader))
            (bytes (string->utf8 "{\"é\":\"→\"}\n")))
        (check (jsonl-reader-feed! r bytes 0 3) => [])
        (check (jsonl-reader-feed! r bytes 3 5) => [])
        (check (jsonl-reader-feed! r bytes 5 (u8vector-length bytes)) => ["{\"é\":\"→\"}"])))

    (test-case "a huge line, in many pieces, is one line"
      (let* ((r (new-jsonl-reader))
             (big (make-string 5000000 #\x))
             (bytes (string->utf8 (string-append "\"" big "\"\n")))
             (lines (let lp ((at 0) (out []))
                      (if (>= at (u8vector-length bytes))
                        out
                        (let (end (min (u8vector-length bytes) (+ at 65536)))
                          (lp end (append out (jsonl-reader-feed! r bytes at end))))))))
        (check (length lines) => 1)
        (check (string-length (car lines)) => 5000002)))

    (test-case "a line that is not a JSON object parses to #f; fields read null as #f"
      (check (parse-json-line "not json") => #f)
      (check (parse-json-line "[1,2]") => #f)
      (let (record (parse-json-line "{\"type\":\"x\",\"none\":null,\"n\":3}"))
        (check (json-field record "type") => "x")
        (check (json-field record "none") => #f)
        (check (json-field record "n") => 3)
        (check (json-field "not a record" "type") => #f)))

    (test-case "a record written is one line"
      (let (bytes (json-line-bytes (parse-json-line "{\"text\":\"a\\nb\"}")))
        (check (u8vector-ref bytes (- (u8vector-length bytes) 1)) => 10)
        (check (length (jsonl-reader-feed! (new-jsonl-reader) bytes)) => 1)))))
