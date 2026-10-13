;;; Owner-tagged entries for slot-like effects (ADR 2).
;;; A slot's effective value is its highest-priority entry; among equal
;;; priorities the newest wins. Removing an entry touches only that entry, so
;;; plugins can be deactivated in any order.
prelude: :gerbil/core

(import (only-in :gerbil/runtime/hash HashTable))
(export (struct-out entry)
        entry-outranks?
        entry-table
        new-entry-table
        entry-table-add!
        entry-table-remove!
        entry-table-ref
        entry-table-entries
        entry-table-names)

;; One contribution to a slot, with its provenance.
(defstruct entry ((owner    : :symbol)
                  (priority : :fixnum)
                  (serial   : :fixnum)
                  (value    : :t)
                  (doc      :? :string)
                  (source   :? :string))
  final: #t)

(def (entry-outranks? (a : entry) (b : entry)) => :boolean
  (or (fx> (entry-priority a) (entry-priority b))
      (and (fx= (entry-priority a) (entry-priority b))
           (fx> (entry-serial a) (entry-serial b)))))

;; Slot name -> entries, best first.
(defstruct entry-table ((slots : HashTable))
  final: #t)

(def (new-entry-table) => entry-table
  (make-entry-table (make-hash-table)))

(def (entry-table-add! (table : entry-table) (name : :t) (new : entry)) => :void
  (let (slots (entry-table-slots table))
    (hash-put! slots name
               (let insert ((rest (hash-ref slots name [])))
                 (match rest
                   ([] [new])
                   ([first . more]
                    (if (entry-outranks? new first)
                      (cons new rest)
                      (cons first (insert more)))))))))

(def (entry-table-remove! (table : entry-table) (name : :t) (old : entry)) => :void
  (let* ((slots (entry-table-slots table))
         (rest (remq old (hash-ref slots name []))))
    (if (null? rest)
      (hash-remove! slots name)
      (hash-put! slots name rest))))

(def (entry-table-ref (table : entry-table) (name : :t)) => (Maybe entry)
  (match (hash-get (entry-table-slots table) name)
    ([best . _] best)
    (else #f)))

;; Every entry for NAME, effective one first.
(def (entry-table-entries (table : entry-table) (name : :t)) => :list
  (hash-ref (entry-table-slots table) name []))

;; The names that have entries.
(def (entry-table-names (table : entry-table)) => :list
  (hash-keys (entry-table-slots table)))
