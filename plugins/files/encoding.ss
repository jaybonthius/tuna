;;; Bytes of a file to the characters of its text and back, recording what
;;; must be written back the same: a UTF-8 byte-order mark, Windows line
;;; endings used on every line, and the final newline. No encoding is ever
;;; guessed: a file that is not UTF-8 is shown as far as it can be and is
;;; read-only.
prelude: :gerbil/core

(export (struct-out decoded)
        decode-file-bytes
        encode-text
        binary-sniff-size)

;; ENCODING is 'utf-8 for an editable file, or 'utf-16, 'binary or
;; 'invalid-utf-8; LINE-ENDING is 'lf, 'crlf or 'mixed.
(defstruct decoded ((text           : :string)
                    (encoding       : :symbol)
                    (bom?           : :boolean)
                    (line-ending    : :symbol)
                    (final-newline? : :boolean))
  final: #t)

;; How many leading bytes are looked at for a NUL, which makes a file binary.
(def binary-sniff-size 8192)

(def (starts-with? (bytes : :u8vector) . prefix) => :boolean
  (let lp ((i 0) (rest prefix))
    (or (null? rest)
        (and (fx< i (u8vector-length bytes))
             (fx= (u8vector-ref bytes i) (car rest))
             (lp (fx1+ i) (cdr rest))))))

(def (binary? (bytes : :u8vector)) => :boolean
  (let (end (fxmin binary-sniff-size (u8vector-length bytes)))
    (let lp ((i 0))
      (and (fx< i end)
           (or (fx= (u8vector-ref bytes i) 0) (lp (fx1+ i)))))))

;; How BYTES end their lines: 'lf with no CR at all, 'crlf when every LF
;; follows a CR and no CR stands alone, 'mixed otherwise.
(def (line-ending-of (bytes : :u8vector)) => :symbol
  (let ((size (u8vector-length bytes)))
    (let lp ((i 0) (crlf 0) (lf 0) (cr 0))
      (if (fx= i size)
        (cond
         ((and (fx= crlf 0) (fx= cr 0)) 'lf)
         ((and (fx= lf 0) (fx= cr 0)) 'crlf)
         (else 'mixed))
        (let (b (u8vector-ref bytes i))
          (cond
           ((and (fx= b 13) (fx< (fx1+ i) size) (fx= (u8vector-ref bytes (fx1+ i)) 10))
            (lp (fx+ i 2) (fx1+ crlf) lf cr))
           ((fx= b 13) (lp (fx1+ i) crlf lf (fx1+ cr)))
           ((fx= b 10) (lp (fx1+ i) crlf (fx1+ lf) cr))
           (else (lp (fx1+ i) crlf lf cr))))))))

;; BYTES from START without the CR of each CR LF.
(def (without-crs (bytes : :u8vector) (start : :fixnum)) => :u8vector
  (let* ((size (u8vector-length bytes))
         (out (make-u8vector (fx- size start))))
    (let lp ((i start) (j 0))
      (cond
       ((fx= i size) (subu8vector out 0 j))
       ((and (fx= (u8vector-ref bytes i) 13) (fx< (fx1+ i) size) (fx= (u8vector-ref bytes (fx1+ i)) 10))
        (lp (fx1+ i) j))
       (else
        (u8vector-set! out j (u8vector-ref bytes i))
        (lp (fx1+ i) (fx1+ j)))))))

;; BYTES with a CR before each LF.
(def (with-crs (bytes : :u8vector)) => :u8vector
  (let* ((size (u8vector-length bytes))
         (lfs (let lp ((i 0) (n 0))
                (if (fx= i size) n (lp (fx1+ i) (if (fx= (u8vector-ref bytes i) 10) (fx1+ n) n)))))
         (out (make-u8vector (fx+ size lfs))))
    (let lp ((i 0) (j 0))
      (if (fx= i size)
        out
        (let (b (u8vector-ref bytes i))
          (if (fx= b 10)
            (begin (u8vector-set! out j 13) (u8vector-set! out (fx1+ j) 10) (lp (fx1+ i) (fx+ j 2)))
            (begin (u8vector-set! out j b) (lp (fx1+ i) (fx1+ j)))))))))

;; Characters for a file that is not UTF-8, only to be looked at: valid
;; UTF-8 sequences decode, and every other byte, and every control
;; character but tab, LF and CR, shows as U+FFFD.
(def (lenient-text (bytes : :u8vector)) => :string
  (let ((size (u8vector-length bytes))
        (out (open-output-string)))
    (let lp ((i 0))
      (when (fx< i size)
        (let* ((b (u8vector-ref bytes i))
               (length (cond ((fx< b #x80) 1) ((fx<= #xC2 b #xDF) 2) ((fx<= #xE0 b #xEF) 3)
                             ((fx<= #xF0 b #xF4) 4) (else 0)))
               (decoded (and (fx> length 0) (fx<= (fx+ i length) size)
                             (with-catch (lambda (e) #f)
                               (lambda () (utf8->string (subu8vector bytes i (fx+ i length))))))))
          (cond
           ((and decoded (fx= length 1) (fx< b 32) (not (memv b '(9 10 13))))
            (write-char #\xFFFD out) (lp (fx1+ i)))
           (decoded (write-string decoded out) (lp (fx+ i length)))
           (else (write-char #\xFFFD out) (lp (fx1+ i)))))))
    (get-output-string out)))

(def (final-newline? (bytes : :u8vector)) => :boolean
  (let (size (u8vector-length bytes))
    (and (fx> size 0) (fx= (u8vector-ref bytes (fx1- size)) 10))))

;; BYTES, a file's contents, as a text and the format to write it back in.
(def (decode-file-bytes (bytes : :u8vector)) => decoded
  (let (read-only (lambda ((encoding : :symbol))
                    (make-decoded (lenient-text bytes) encoding #f (line-ending-of bytes) (final-newline? bytes))))
    (cond
     ((or (starts-with? bytes #xFF #xFE) (starts-with? bytes #xFE #xFF)) (read-only 'utf-16))
     ((binary? bytes) (read-only 'binary))
     (else
      (let* ((bom? (starts-with? bytes #xEF #xBB #xBF))
             (start (if bom? 3 0))
             (ending (line-ending-of bytes))
             (body (if (eq? ending 'crlf)
                     (without-crs bytes start)
                     (subu8vector bytes start (u8vector-length bytes))))
             (text (with-catch (lambda (e) #f) (lambda () (utf8->string body)))))
        (if text
          (make-decoded text 'utf-8 bom? ending (final-newline? bytes))
          (read-only 'invalid-utf-8)))))))

;; TEXT as the bytes of a file with a byte-order mark if BOM? and the line
;; ending LINE-ENDING.
(def (encode-text (text : :string) (bom? : :boolean) (line-ending : :symbol)) => :u8vector
  (let* ((body (string->utf8 text))
         (body (if (eq? line-ending 'crlf) (with-crs body) body)))
    (if bom? (u8vector-append (u8vector #xEF #xBB #xBF) body) body)))
