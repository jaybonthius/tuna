;;; Temporary folders of files for the files plugin's tests.
(export call-with-folder
        put-bytes!
        put-string!
        bytes-of
        string-of
        folder-names)

;; Call PROC with a new empty folder's name, ending in "/", and remove the
;; folder and everything in it afterwards.
(def (call-with-folder (proc : :procedure)) => :t
  (let (folder (string-append (create-temporary-directory "/tmp/tuna-files-test") "/"))
    (try
     (proc folder)
     (finally (remove-tree folder)))))

(def (remove-tree (path : :string)) => :void
  (let (info (file-info path #f))
    (if (eq? (file-info-type info) 'directory)
      (begin
        (for-each (lambda ((name : :string))
                    (unless (member name '("." ".."))
                      (remove-tree (path-expand name path))))
                  (directory-files [path: path ignore-hidden: #f]))
        (delete-directory path))
      (delete-file path))))

(def (put-bytes! (path : :string) (bytes : :u8vector)) => :void
  (call-with-output-file path (lambda (port) (write-subu8vector bytes 0 (u8vector-length bytes) port))))

(def (put-string! (path : :string) (text : :string)) => :void
  (put-bytes! path (string->utf8 text)))

(def (bytes-of (path : :string)) => :u8vector
  (call-with-input-file path
    (lambda (port)
      (let lp ((chunks []))
        (let* ((chunk (make-u8vector 4096))
               (n (read-subu8vector chunk 0 4096 port)))
          (if (fx= n 0)
            (apply u8vector-append (reverse chunks))
            (lp (cons (subu8vector chunk 0 n) chunks))))))))

(def (string-of (path : :string)) => :string
  (utf8->string (bytes-of path)))

;; The names in FOLDER, sorted, hidden ones included.
(def (folder-names (folder : :string)) => :list
  (list-sort string<?
             (filter (lambda ((name : :string)) (not (member name '("." ".."))))
                     (directory-files [path: folder ignore-hidden: #f]))))
