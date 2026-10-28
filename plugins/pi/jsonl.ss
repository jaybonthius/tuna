;;; JSON lines (JSONL), as Pi's RPC mode frames its records
;;; (agents/research/pi-chat/pi-rpc-and-helper.md §1): one JSON object a
;;; line, ended by LF only; a CR before the LF is dropped; U+2028 and
;;; U+2029 are text, not line ends; a line may be any length. The Pi
;;; helper and the chat both read and write it: Pi's pipes, and the
;;; helper's socket, carry nothing else.
prelude: :gerbil/core

(import (only-in :gerbil/runtime/hash HashTable)
        :std/encoding/json)
(export jsonl-reader
        jsonl-reader?
        new-jsonl-reader
        jsonl-reader-feed!
        parse-json-line
        json-line-bytes
        json-field)

;; The bytes of a line not yet ended: BUFFER up to FILL, holding no LF.
(defclass jsonl-reader ((buffer : :u8vector)
                        (fill : :fixnum))
  final: #t)

(def (new-jsonl-reader) => jsonl-reader
  (jsonl-reader buffer: (make-u8vector 4096 0) fill: 0))

;; R's buffer with room for N more bytes, grown by doubling so a long line
;; costs its length, not its length squared.
(def (reserve! (r : jsonl-reader) (n : :fixnum)) => :void
  (let ((needed (fx+ r.fill n))
        (size (u8vector-length r.buffer)))
    (when (fx> needed size)
      (let (bigger (make-u8vector (let grow ((size (fx* 2 size))) (if (fx>= size needed) size (grow (fx* 2 size)))) 0))
        (subu8vector-move! r.buffer 0 r.fill bigger 0)
        (set! r.buffer bigger)))))

;; The text of BYTES from START to END, a line without its LF, without a
;; CR at its end; bytes that are not UTF-8 become U+FFFD.
(def (line-text (bytes : :u8vector) (start : :fixnum) (end : :fixnum)) => :string
  (let (end (if (and (fx> end start) (fx= (u8vector-ref bytes (fx1- end)) 13)) (fx1- end) end))
    (with-catch (lambda (e) (lenient-utf8 (subu8vector bytes start end)))
                (lambda () (utf8->string (subu8vector bytes start end))))))

(def (lenient-utf8 (bytes : :u8vector)) => :string
  (let ((port (open-input-u8vector [init: bytes char-encoding: 'UTF-8 char-encoding-errors: #f]))
        (out (open-output-string)))
    (let lp ()
      (let (c (read-char port))
        (unless (eof-object? c)
          (write-char c out)
          (lp))))
    (get-output-string out)))

;; Feed R BYTES from START to END: the lines they end, oldest first, each
;; without its LF and CR. What follows the last LF waits for more.
(def (jsonl-reader-feed! (r : jsonl-reader) (bytes : :u8vector)
                         (start : :fixnum := 0) (end : :fixnum := (u8vector-length bytes)))
  => :list
  (let lp ((from start) (lines []))
    (let (lf (let scan ((i from)) (cond ((fx= i end) #f) ((fx= (u8vector-ref bytes i) 10) i) (else (scan (fx1+ i))))))
      (if (not lf)
        (begin
          (reserve! r (fx- end from))
          (subu8vector-move! bytes from end r.buffer r.fill)
          (set! r.fill (fx+ r.fill (fx- end from)))
          (reverse lines))
        (let (line (if (fx= r.fill 0)
                     (line-text bytes from lf)
                     (begin
                       (reserve! r (fx- lf from))
                       (subu8vector-move! bytes from lf r.buffer r.fill)
                       (let (text (line-text r.buffer 0 (fx+ r.fill (fx- lf from))))
                         (set! r.fill 0)
                         text))))
          (lp (fx1+ lf) (cons line lines)))))))

;; LINE as a JSON object, a hash table with string keys; #f when it is
;; not one.
(def (parse-json-line (line : :string)) => (Maybe HashTable)
  (with-catch (lambda (e) #f)
              (lambda ()
                (let (value (parameterize ((current-json-read-options (JSONReadOptions object-as-hash: #t)))
                              (string->json line)))
                  (and (hash-table? value) value)))))

;; OBJECT (a hash table, or what json->string writes) as one JSONL line.
(def (json-line-bytes (object : :t)) => :u8vector
  (string->utf8 (string-append (json->string object) "\n")))

;; Field NAME of RECORD when RECORD is a JSON object; #f when it is not
;; there or is null.
(def (json-field (record : :t) (name : :string)) => :t
  (and (hash-table? record)
       (let (value (hash-ref record name #f))
         (and (not (void? value)) value))))
