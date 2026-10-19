;;; Stylesheets: which CSS files are on the page, in what order, and who
;;; replaced which (docs/briefs/2026-10-stylesheets.md). Gerbil knows only
;;; their identities, paths and order, never colours or rules.
;;;
;;; A stylesheet is a slot named by its owner, a plugin, and a symbol:
;;; (completion-vertical rules). The owner fills it with add-stylesheet;
;;; any plugin, theme or init.ss replaces it with replace-stylesheet, or
;;; removes it by replacing it with #f. The slots are owner-tagged entries
;;; (ADR 2): the owner's own file has priority 0 and replacements priority
;;; 1, so a replacement wins, and among replacements the owner declared
;;; later in init.ss wins. Both forms register through a context, so
;;; turning a plugin off removes what it added and restores what it
;;; replaced.
;;;
;;; Page order is by the owner's place in init.ss, then by registration
;;; within the owner, both read when the list is read. A replacement shows
;;; only while its owner is on and adds a stylesheet of that name; the
;;; registry knows an owner is on only while it has a stylesheet of its own
;;; registered.
;;;
;;; A path resolves against the directory of the file holding the form; in
;;; code without a source file (code evaluated interactively) it must be
;;; absolute. The file is read when the stylesheet is registered and again
;;; by reread-stylesheets!. A file that cannot be read gives the stylesheet
;;; a warning and no text; it never fails the registering plugin.
;;;
;;; This contract exports no service: plugins that style themselves declare
;;; nothing new. The registry is module state, like advice targets
;;; (tuna/lib/advice.ss): Tuna runs one editor per process, and tests turn
;;; every plugin off after each fresh kernel, which empties it.
prelude: :gerbil/core

(import :std/crypto/digest
        :std/encoding/hex
        :std/misc/ports
        :std/source
        :std/string/path
        :tuna/kernel)
(export add-stylesheet
        replace-stylesheet
        stylesheet? stylesheet-owner stylesheet-name stylesheet-path
        stylesheet-text stylesheet-digest stylesheet-replaced-by stylesheet-warning
        stylesheets
        stylesheet-replacement? stylesheet-replacement-owner stylesheet-replacement-name
        stylesheet-replacement-replaced-by stylesheet-replacement-path
        stylesheet-replacement-target
        stylesheet-replacements
        stylesheets-generation
        reread-stylesheets!)

;; One registration of a slot: who made it, its file, and what reading the
;; file gave. PATH is #f for a removal.
(defstruct registration ((by      : :symbol)
                         (path    :? :string)
                         (text    :? :string)
                         (digest  :? :string)
                         (warning :? :string))
  final: #t)

;; A stylesheet on the page. TEXT and DIGEST are #f when its file could not
;; be read, and WARNING says why. REPLACED-BY names the plugin whose
;; replacement is in effect, or is #f for the owner's own file.
(defstruct stylesheet ((owner       : :symbol)
                       (name        : :symbol)
                       (path        : :string)
                       (text        :? :string)
                       (digest      :? :string)
                       (replaced-by :? :symbol)
                       (warning     :? :string))
  final: #t)

;; A replacement in effect for its slot. PATH is #f for a removal. TARGET
;; is present when OWNER adds a stylesheet NAME, absent when OWNER is on
;; but adds none of that name, and dormant when OWNER is off.
(defstruct stylesheet-replacement ((owner       : :symbol)
                                   (name        : :symbol)
                                   (replaced-by : :symbol)
                                   (path        :? :string)
                                   (target      : :symbol))
  final: #t)

;; (owner . name) -> registrations.
(def slots (new-entry-table))

;; 'owners -> one entry per owner with a stylesheet of its own; its
;; entries sort by init.ss rank.
(def owners (new-entry-table))

(def generation 0)
;; The registrations on the page when the generation was last read.
(def generation-shown [])

(def (read-registration! (r : registration)) => :boolean
  (let* ((path (registration-path r))
         (text (and path (file-exists? path)
                    (with-catch (lambda (e) #f) (lambda () (read-file-string path)))))
         (warning (cond
                   ((not path) #f)
                   ((not (file-exists? path)) (string-append "No such file: " path))
                   ((not text) (string-append "Cannot read " path))
                   (else #f)))
         (changed? (not (and (equal? text (registration-text r))
                             (equal? warning (registration-warning r))))))
    (when changed?
      (set! (registration-text r) text)
      (set! (registration-digest r) (and text (hex-encode (sha256 (string->utf8 text)))))
      (set! (registration-warning r) warning))
    changed?))

(def (resolve-path (path :? :string) (directory :? :string)) => (Maybe :string)
  (cond
   ((not path) #f)
   ((path-absolute? path) path)
   (directory (path-expand path directory))
   (else (error "A stylesheet path in code without a source file must be absolute" path))))

(def (register-stylesheet! (ctx : context) (owner : :symbol) (name : :symbol)
                           (path :? :string) (directory :? :string))
  => :void
  (let* ((by (context-plugin-name ctx))
         (r (make-registration by (resolve-path path directory) #f #f #f)))
    (read-registration! r)
    (if (eq? owner by)
      (begin
        (context-add-entry! ctx owners 'owners #t)
        (context-add-entry! ctx slots (cons owner name) r))
      (context-add-entry! ctx slots (cons owner name) r priority: 1))
    (void)))

(def (add-stylesheet! (ctx : context) (name : :symbol) (path : :string) (directory :? :string))
  => :void
  (register-stylesheet! ctx (context-plugin-name ctx) name path directory))

(def (replace-stylesheet! (ctx : context) (owner : :symbol) (name : :symbol)
                          (path :? :string) (directory :? :string))
  => :void
  (when (eq? owner (context-plugin-name ctx))
    (error "A plugin adds its own stylesheets with add-stylesheet" owner name))
  (register-stylesheet! ctx owner name path directory))

(begin-syntax
  ;; The directory of the file holding STX, or #f without one.
  (def (form-directory stx)
    (let (file (stx-source-file stx))
      (and (string? file) (path-expand (path-directory file))))))

;; (add-stylesheet 'rules "rules.css") in a plugin body or init.ss, or
;; (add-stylesheet ctx 'rules "rules.css") in a callback.
(defsyntax (add-stylesheet stx)
  (syntax-case stx ()
    ((_ ctx name path)
     (with-syntax ((directory (form-directory stx)))
       #'(add-stylesheet! ctx name path 'directory)))
    ((_ name path)
     (with-syntax ((directory (form-directory stx)))
       #'(add-stylesheet! (current-context) name path 'directory)))))

;; (replace-stylesheet 'layout 'rules "layout.css"), #f for the path to
;; remove it, or with a leading context argument in a callback.
(defsyntax (replace-stylesheet stx)
  (syntax-case stx ()
    ((_ ctx owner name path)
     (with-syntax ((directory (form-directory stx)))
       #'(replace-stylesheet! ctx owner name path 'directory)))
    ((_ owner name path)
     (with-syntax ((directory (form-directory stx)))
       #'(replace-stylesheet! (current-context) owner name path 'directory)))))

;; Owners with a stylesheet of their own, in init.ss order.
(def (owner-order) => :list
  (map entry-owner (reverse (entry-table-entries owners 'owners))))

(def (own-entry (key : :pair)) => (Maybe entry)
  (find (lambda ((e : entry)) (eq? (entry-owner e) (car key)))
        (entry-table-entries slots key)))

;; The registrations on the page, in order, as (key . registration).
(def (shown-registrations) => :list
  (let (keys (entry-table-names slots))
    (apply append
      (map (lambda ((owner : :symbol))
             (let* ((own (filter-map (lambda ((key : :pair))
                                       (and (eq? (car key) owner)
                                            (let (e (own-entry key)) (and e (cons key e)))))
                                     keys))
                    (ordered (list-sort (lambda ((a : :pair) (b : :pair))
                                          (fx< (entry-serial (cdr a)) (entry-serial (cdr b))))
                                        own)))
               (filter-map (lambda ((pair : :pair))
                             (let* ((key (car pair))
                                    (r (: (entry-value (: (entry-table-ref slots key) entry)) registration)))
                               (and (registration-path r) (cons key r))))
                           ordered)))
           (owner-order)))))

;; The stylesheets on the page, in page order.
(def (stylesheets) => :list
  (map (lambda ((pair : :pair))
         (let ((key (car pair))
               (r (: (cdr pair) registration)))
           (make-stylesheet (car key) (cdr key) (: (registration-path r) :string)
                            (registration-text r) (registration-digest r)
                            (and (not (eq? (registration-by r) (car key))) (registration-by r))
                            (registration-warning r))))
       (shown-registrations)))

;; Every replacement in effect, in registration order.
(def (stylesheet-replacements) => :list
  (let (active (owner-order))
    (map cdr
         (list-sort
          (lambda ((a : :pair) (b : :pair)) (fx< (car a) (car b)))
          (filter-map
           (lambda ((key : :pair))
             (let* ((best (: (entry-table-ref slots key) entry))
                    (r (: (entry-value best) registration)))
               (and (not (eq? (registration-by r) (car key)))
                    (cons (entry-serial best)
                          (make-stylesheet-replacement
                           (car key) (cdr key) (registration-by r) (registration-path r)
                           (cond ((own-entry key) 'present)
                                 ((memq (car key) active) 'absent)
                                 (else 'dormant)))))))
           (entry-table-names slots))))))

;; A number that changes whenever the stylesheets on the page, their order
;; or their text change, compared with the last time it was read.
(def (stylesheets-generation) => :fixnum
  (let (shown (map cdr (shown-registrations)))
    (unless (and (fx= (length shown) (length generation-shown))
                 (andmap eq? shown generation-shown))
      (set! generation-shown shown)
      (set! generation (fx1+ generation)))
    (:- generation :fixnum)))

;; Read every registered file again. Returns how many changed.
(def (reread-stylesheets!) => :fixnum
  (let (changed 0)
    (for-each (lambda (key)
                (for-each (lambda ((e : entry))
                            (when (read-registration! (: (entry-value e) registration))
                              (set! changed (fx1+ changed))))
                          (entry-table-entries slots key)))
              (entry-table-names slots))
    (when (fx> changed 0)
      (set! generation (fx1+ generation)))
    (:- changed :fixnum)))
