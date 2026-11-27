(library (with-editor state)
  (export edit-token tuna-pid make-request request-folder request-wrapper request-path requests canceled-wrappers)
  (import (chezscheme))

  ;; Chez loads a library once per process, so a reload of with-editor
  ;; keeps the token a waiting program's request carries, and which
  ;; buffer each waiting program is answered from.
  (define edit-token
    (let ([bytes (call-with-port (open-file-input-port "/dev/urandom") (lambda (p) (get-bytevector-n p 16)))])
      (apply string-append (map (lambda (b) (format "~(~2,'0x~)" b)) (bytevector->u8-list bytes)))))

  (define tuna-pid (begin (load-shared-object #f) ((foreign-procedure "getpid" () int))))

  (define-record-type request (fields folder wrapper path))

  (define requests (make-eq-hashtable))

  (define canceled-wrappers (make-weak-eq-hashtable)))
