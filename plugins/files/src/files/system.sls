(library (files system)
  (export call-with-c-string c-string->string raise-system-failure)
  (import (chezscheme))

  (define (call-with-c-string s proc)
    (let* ([bv (string->utf8 s)]
           [n (bytevector-length bv)]
           [p (foreign-alloc (fx+ n 1))])
      (dynamic-wind
        void
        (lambda ()
          (do ([i 0 (fx+ i 1)]) ((fx= i n))
            (foreign-set! 'unsigned-8 p i (bytevector-u8-ref bv i)))
          (foreign-set! 'unsigned-8 p n 0)
          (proc p))
        (lambda () (foreign-free p)))))

  (define (c-string->string p)
    (let ([n (let loop ([i 0]) (if (fx= (foreign-ref 'unsigned-8 p i) 0) i (loop (fx+ i 1))))])
      (let ([bv (make-bytevector n)])
        (do ([i 0 (fx+ i 1)]) ((fx= i n))
          (bytevector-u8-set! bv i (foreign-ref 'unsigned-8 p i)))
        (utf8->string bv))))

  (define c-strerror-r
    (begin
      (load-shared-object #f)
      (foreign-procedure "strerror_r" (int uptr size_t) uptr)))

  (define enoent 2)

  ;; Worded as Chez's own file procedures word a failure, so the user
  ;; reads one form whichever raised it.
  (define (raise-system-failure who path errno)
    (let ([reason (let ([buffer (foreign-alloc 256)])
                    (dynamic-wind
                      void
                      (lambda () (c-string->string (c-strerror-r errno buffer 256)))
                      (lambda () (foreign-free buffer))))])
      (raise (condition (if (fx= errno enoent) (make-i/o-file-does-not-exist-error path) (make-i/o-filename-error path))
                        (make-who-condition who) (make-format-condition)
                        (make-message-condition "failed for ~a: ~(~a~)")
                        (make-irritants-condition (list path reason)))))))
