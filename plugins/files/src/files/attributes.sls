(library (files attributes)
  (export read-file-attributes file-attributes? file-type file-system-space
          file-attributes-type file-attributes-size file-attributes-blocks file-attributes-modified
          file-attributes-modified-nanoseconds
          file-attributes-mode file-attributes-links file-attributes-uid file-attributes-gid
          file-attributes-owner file-attributes-group file-attributes-target make-owner-names)
  (import (chezscheme) (files system))

  (define-enumeration file-type (file folder link other) file-types)

  ;; The same symbol in every process and after this library reloads, so
  ;; attributes a job read are known as such on the main thread.
  (define tag (gensym "file-attributes" "q3v8kd1x7m2p0s9w4zj6nb5tyc-0"))

  ;; Each call can wait on a slow or network file system, so it lets other
  ;; threads collect meanwhile and takes no Scheme string.
  (define c-lstat
    (begin
      (load-shared-object #f)
      (foreign-procedure __collect_safe __errno "lstat" (uptr uptr) int)))
  (define c-readlink (foreign-procedure __collect_safe __errno "readlink" (uptr uptr size_t) ssize_t))
  (define c-statvfs (foreign-procedure __collect_safe __errno "statvfs" (uptr uptr) int))
  (define c-getpwuid-r (foreign-procedure __collect_safe "getpwuid_r" (unsigned-32 uptr uptr size_t uptr) int))
  (define c-getgrgid-r (foreign-procedure __collect_safe "getgrgid_r" (unsigned-32 uptr uptr size_t uptr) int))

  ;; Offsets in x86-64 Linux's struct stat and struct statvfs, the only
  ;; layout Tuna is built for.
  (define stat-size 144)
  (define nlink-offset 16)
  (define mode-offset 24)
  (define uid-offset 28)
  (define gid-offset 32)
  (define size-offset 48)
  (define blocks-offset 64)
  (define mtime-offset 88)
  (define mtime-nanoseconds-offset 96)
  (define statvfs-size 112)
  (define frsize-offset 8)
  (define bavail-offset 32)

  (define type-mask #o170000)
  (define link-bits #o120000)
  (define folder-bits #o040000)
  (define file-bits #o100000)

  (define erange 34)

  (define-ftype passwd
    (struct [name uptr] [password uptr] [uid unsigned-32] [gid unsigned-32] [gecos uptr] [home uptr] [shell uptr]))

  (define-ftype group
    (struct [name uptr] [password uptr] [gid unsigned-32] [members uptr]))

  ;; getpwuid and getgrgid return one static entry that two jobs would
  ;; share; a buffer too small for an entry asks for a larger one.
  (define (entry-name lookup id entry-size name-of)
    (let ([entry (foreign-alloc entry-size)] [found (foreign-alloc (foreign-sizeof 'uptr))])
      (dynamic-wind
        void
        (lambda ()
          (let retry ([size 1024])
            (let ([buffer (foreign-alloc size)])
              (let* ([errno (lookup id entry buffer size found)]
                     [name (and (fx= errno 0) (not (fx= (foreign-ref 'uptr found 0) 0))
                                (c-string->string (name-of entry)))])
                (foreign-free buffer)
                (if (fx= errno erange) (retry (fx* size 2)) name)))))
        (lambda () (foreign-free entry) (foreign-free found)))))

  (define (owner-name uid)
    (entry-name c-getpwuid-r uid (ftype-sizeof passwd)
                (lambda (entry) (ftype-ref passwd (name) (make-ftype-pointer passwd entry)))))

  (define (group-name gid)
    (entry-name c-getgrgid-r gid (ftype-sizeof group)
                (lambda (entry) (ftype-ref group (name) (make-ftype-pointer group entry)))))

  ;; A lookup can read the whole user database, so a caller reading many
  ;; files looks each owner and group up once. The names are the caller's,
  ;; not this library's, which keeps no state.
  (define-record-type owner-names
    (sealed #t)
    (fields users groups)
    (protocol (lambda (new) (lambda () (new (make-eqv-hashtable) (make-eqv-hashtable))))))

  (define (cached table lookup id)
    (if (hashtable-contains? table id)
        (hashtable-ref table id #f)
        (let ([name (lookup id)])
          (hashtable-set! table id name)
          name)))

  (define (read-link who path p)
    (let loop ([size 256])
      (or (let ([buffer (foreign-alloc size)])
            (dynamic-wind
              void
              (lambda ()
                (let-values ([(n errno) (c-readlink p buffer size)])
                  (cond
                    [(fx< n 0) (raise-system-failure who path errno)]
                    [(fx= n size) #f]
                    [else
                     (let ([bv (make-bytevector n)])
                       (do ([i 0 (fx+ i 1)]) ((fx= i n))
                         (bytevector-u8-set! bv i (foreign-ref 'unsigned-8 buffer i)))
                       (utf8->string bv))])))
              (lambda () (foreign-free buffer))))
          (loop (fx* size 2)))))

  (define (type-of mode)
    (let ([bits (fxand mode type-mask)])
      (cond
        [(fx= bits file-bits) (file-type file)]
        [(fx= bits folder-bits) (file-type folder)]
        [(fx= bits link-bits) (file-type link)]
        [else (file-type other)])))

  (define read-file-attributes
    (case-lambda
      [(path) (read-attributes path #f)]
      [(path names)
       (unless (owner-names? names)
         (assertion-violation 'read-file-attributes "not owner names" names))
       (read-attributes path names)]))

  (define (read-attributes path names)
    (unless (string? path)
      (assertion-violation 'read-file-attributes "not a string" path))
    (call-with-c-string path
      (lambda (p)
        (let ([buffer (foreign-alloc stat-size)])
          (dynamic-wind
            void
            (lambda ()
              (let-values ([(result errno) (c-lstat p buffer)])
                (unless (fx= result 0)
                  (raise-system-failure 'read-file-attributes path errno)))
              (let* ([mode (foreign-ref 'unsigned-32 buffer mode-offset)]
                     [type (type-of mode)]
                     [uid (foreign-ref 'unsigned-32 buffer uid-offset)]
                     [gid (foreign-ref 'unsigned-32 buffer gid-offset)])
                (vector->immutable-vector
                  (vector tag type
                          (foreign-ref 'integer-64 buffer size-offset)
                          (foreign-ref 'integer-64 buffer blocks-offset)
                          (foreign-ref 'integer-64 buffer mtime-offset)
                          (fxand mode #o7777)
                          (foreign-ref 'unsigned-64 buffer nlink-offset)
                          uid gid
                          (if names (cached (owner-names-users names) owner-name uid) (owner-name uid))
                          (if names (cached (owner-names-groups names) group-name gid) (group-name gid))
                          (and (eq? type (file-type link)) (read-link 'read-file-attributes path p))
                          (foreign-ref 'integer-64 buffer mtime-nanoseconds-offset)))))
            (lambda () (foreign-free buffer)))))))

  (define (file-attributes? v)
    (and (vector? v) (fx= (vector-length v) 13) (eq? (vector-ref v 0) tag)))

  (define-syntax define-accessor
    (syntax-rules ()
      [(_ name index)
       (define (name v)
         (unless (file-attributes? v)
           (assertion-violation 'name "not file attributes" v))
         (vector-ref v index))]))

  (define-accessor file-attributes-type 1)
  (define-accessor file-attributes-size 2)
  (define-accessor file-attributes-blocks 3)
  (define-accessor file-attributes-modified 4)
  (define-accessor file-attributes-mode 5)
  (define-accessor file-attributes-links 6)
  (define-accessor file-attributes-uid 7)
  (define-accessor file-attributes-gid 8)
  (define-accessor file-attributes-owner 9)
  (define-accessor file-attributes-group 10)
  (define-accessor file-attributes-target 11)
  (define-accessor file-attributes-modified-nanoseconds 12)

  (define (file-system-space path)
    (unless (string? path)
      (assertion-violation 'file-system-space "not a string" path))
    (call-with-c-string path
      (lambda (p)
        (let ([buffer (foreign-alloc statvfs-size)])
          (dynamic-wind
            void
            (lambda ()
              (let-values ([(result errno) (c-statvfs p buffer)])
                (unless (fx= result 0)
                  (raise-system-failure 'file-system-space path errno)))
              (* (foreign-ref 'unsigned-64 buffer bavail-offset) (foreign-ref 'unsigned-64 buffer frsize-offset)))
            (lambda () (foreign-free buffer))))))))
