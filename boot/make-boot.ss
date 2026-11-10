(define chez-directory (car (command-line-arguments)))
(library-directories
  '(("src" . "build/obj/src") ("lib/chez-lang/src" . "build/obj/lib/chez-lang/src")))
(compile-file-message #f)
(compile-file "boot/start.ss" "build/obj/boot/start.so")

(define (library-names root)
  (let walk ([dir root] [prefix '()])
    (apply append
      (map (lambda (entry)
             (let ([path (string-append dir "/" entry)])
               (cond
                 [(file-directory? path) (walk path (append prefix (list entry)))]
                 [(equal? (path-extension entry) "sls")
                  (list (map string->symbol (append prefix (list (path-root entry)))))]
                 [else '()])))
           (sort string<? (directory-list dir))))))

;; All of chez-lang goes in, because a file's language and the libraries
;; a language uses must load with no source tree on disk.
(define roots (cons '(tuna main) (library-names "lib/chez-lang/src")))

;; library-requirements needs the library's compile-time and run-time
;; information loaded, and lists only direct requirements, so walk them
;; depth first: each library lands after everything it needs. Chez's own
;; libraries have no object file and are left out.
(define ordered
  (let loop ([todo roots] [done '()])
    (cond
      [(null? todo) done]
      [(member (car todo) done) (loop (cdr todo) done)]
      [else
       (let ([lib (car todo)])
         (environment lib)
         (invoke-library lib)
         (let ([done (loop (library-requirements lib) done)])
           (loop (cdr todo)
             (if (library-object-filename lib) (append done (list lib)) done))))])))

;; The base boot files include the compiler, so Tuna can evaluate code
;; live. vfasl starts faster than plain fasl.
(apply make-boot-file "build/boot/fasl/tuna.boot" '("scheme" "petite")
  (append (map library-object-filename ordered) '("build/obj/boot/start.so")))
(vfasl-convert-file (string-append chez-directory "/petite.boot") "build/boot/petite.boot" '())
(vfasl-convert-file (string-append chez-directory "/scheme.boot") "build/boot/scheme.boot" '("petite"))
(vfasl-convert-file "build/boot/fasl/tuna.boot" "build/boot/tuna.boot" '("scheme" "petite"))
