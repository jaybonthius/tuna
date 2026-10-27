;;; Embeds a directory's browser assets, its own files and not its
;;; folders, into the compiled module.
prelude: :gerbil/core

(import :std/source
        (for-syntax :std/misc/ports
                    :std/net/mime/file))
(export embed-directory)

(begin-syntax
  (def (directory-entries (root   : :string)
                          (prefix : :string))
    => :list
    (filter-map (lambda ((name : :string)) => :t
                  (let (path (path-expand name root))
                    (and (eq? (file-info-type (file-info path #f)) 'regular)
                         (cons (string-append prefix "/" name)
                               (cons (mime-file-type path) (read-file-u8vector path))))))
                (directory-files root))))

(defsyntax-case embed-directory ()
  ((_ directory prefix)
   (and (stx-string? #'directory) (stx-string? #'prefix))
   (let (root (path-strip-trailing-directory-separator
               (stx-source-path stx (stx-e #'directory))))
     (with-syntax ((entries (directory-entries root (stx-e #'prefix))))
       #'(list->hash-table 'entries)))))
