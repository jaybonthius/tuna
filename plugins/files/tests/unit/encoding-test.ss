;;; Bytes to text and back (files plugin, encoding.ss).
(import :std/test
        :tuna/plugins/files/encoding)
(export encoding-test)

(def (bytes . parts)
  (apply u8vector-append
         (map (lambda (part) (if (string? part) (string->utf8 part) (apply u8vector part))) parts)))

;; Decode BYTES and encode the text back as decoded says.
(def (round-trip (in : :u8vector)) => :u8vector
  (let (d (decode-file-bytes in))
    (encode-text (decoded-text d) (decoded-bom? d) (decoded-line-ending d))))

(def encoding-test
  (test-suite "tuna/plugins/files: encodings"
    (test-case "plain UTF-8 with a final newline"
      (let (d (decode-file-bytes (bytes "héllo\nworld\n")))
        (check (decoded-text d) => "héllo\nworld\n")
        (check (decoded-encoding d) => 'utf-8)
        (check (decoded-bom? d) => #f)
        (check (decoded-line-ending d) => 'lf)
        (check (decoded-final-newline? d) => #t)))
    (test-case "a byte-order mark is recorded, hidden and written back"
      (let* ((in (bytes '(#xEF #xBB #xBF) "a\nb"))
             (d (decode-file-bytes in)))
        (check (decoded-text d) => "a\nb")
        (check (decoded-bom? d) => #t)
        (check (decoded-final-newline? d) => #f)
        (check (round-trip in) => in)))
    (test-case "Windows line endings on every line show as lines and are written back"
      (let* ((in (bytes "one\r\ntwo\r\n"))
             (d (decode-file-bytes in)))
        (check (decoded-text d) => "one\ntwo\n")
        (check (decoded-line-ending d) => 'crlf)
        (check (round-trip in) => in)
        (check (encode-text "one\ntwo\nthree" #f 'crlf) => (bytes "one\r\ntwo\r\nthree"))))
    (test-case "mixed line endings stay as they are"
      (let* ((in (bytes "a\r\nb\nc\rd"))
             (d (decode-file-bytes in)))
        (check (decoded-line-ending d) => 'mixed)
        (check (decoded-text d) => "a\r\nb\nc\rd")
        (check (round-trip in) => in)))
    (test-case "a missing final newline stays missing; an empty file stays empty"
      (check (round-trip (bytes "last line")) => (bytes "last line"))
      (check (round-trip (bytes)) => (bytes)))
    (test-case "invalid UTF-8, UTF-16 and binary are read-only and show replacement characters"
      (let (d (decode-file-bytes (bytes "ok " '(#xFF) " é")))
        (check (decoded-encoding d) => 'invalid-utf-8)
        (check (decoded-text d) => "ok \xFFFD; é"))
      (check (decoded-encoding (decode-file-bytes (bytes '(#xFF #xFE 65 0)))) => 'utf-16)
      (let (d (decode-file-bytes (bytes "ELF" '(0 1 2) "x")))
        (check (decoded-encoding d) => 'binary)
        (check (decoded-text d) => "ELF\xFFFD;\xFFFD;\xFFFD;x")))))
