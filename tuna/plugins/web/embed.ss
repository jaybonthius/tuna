;;; Embeds a directory of browser assets into the compiled module.
prelude: :gerbil/core

(import :std/source
        (for-syntax :std/misc/ports
                    :std/net/mime/file))
(export embed-directory)

(begin-syntax
  (def (collect-directory-inputs (path : :string)) => :list
    (case (file-info-type (file-info path #f))
      ((regular) [path])
      ((directory)
       (cons path
         (apply append
           (map (lambda ((name : :string)) => :list
                  (collect-directory-inputs (path-expand name path)))
                (directory-files path)))))
      (else
       (error "Embedded assets must be regular files or directories" path))))

  (def (directory-entries (root   : :string)
                          (prefix : :string))
    => :list
    (map (lambda ((path : :string)) => :pair
           (cons (string-append prefix "/"
                   (substring path (fx1+ (string-length root)) (string-length path)))
                 (cons (mime-file-type path) (read-file-u8vector path))))
         (filter (lambda ((path : :string)) => :boolean
                   (eq? (file-info-type (file-info path #f)) 'regular))
                 (collect-directory-inputs root)))))

(defsyntax-case embed-directory ()
  ((_ directory prefix)
   (and (stx-string? #'directory) (stx-string? #'prefix))
   (let (root (path-strip-trailing-directory-separator
               (stx-source-path stx (stx-e #'directory))))
     (with-syntax ((entries (directory-entries root (stx-e #'prefix))))
       #'(list->hash-table 'entries)))))
