;;; Owner-tagged entries for slot-like effects (ADR 2).
;;; A slot's effective value is its highest-priority entry; among equal
;;; priorities the later declared owner wins. Removing an entry touches only that entry, so
;;; plugins can be deactivated in any order.
prelude: :gerbil/core

(import (only-in :gerbil/runtime/hash HashTable))
(export (struct-out owner-order)
        (struct-out entry)
        entry-outranks?
        entry-table
        new-entry-table
        entry-table-add!
        entry-table-remove!
        entry-table-ref
        entry-table-entries
        entry-table-names)

;; Shared by an owner's entries, so configuration reorder needs no restart.
(defclass owner-order ((rank : :fixnum)) final: #t)

;; One contribution to a slot, with its provenance.
(defstruct entry ((owner    : :symbol)
                  (priority : :fixnum)
                  (order    : owner-order)
                  (serial   : :fixnum)
                  (value    : :t)
                  (doc      :? :string)
                  (source   :? :string))
  final: #t)

(def (entry-outranks? (a : entry) (b : entry)) => :boolean
  (or (fx> (entry-priority a) (entry-priority b))
      (and (fx= (entry-priority a) (entry-priority b))
           (or (fx> (owner-order-rank (entry-order a))
                    (owner-order-rank (entry-order b)))
               (and (fx= (owner-order-rank (entry-order a))
                         (owner-order-rank (entry-order b)))
                    (string>? (symbol->string (entry-owner a))
                              (symbol->string (entry-owner b))))))))

;; Slot name -> entries, best first.
(defstruct entry-table ((slots : HashTable))
  final: #t)

(def (new-entry-table) => entry-table
  (make-entry-table (make-hash-table)))

(def (entry-table-add! (table : entry-table) (name : :t) (new : entry)) => :void
  (let (slots (entry-table-slots table))
    (hash-put! slots name
               (let insert ((rest (filter (lambda ((old : entry))
                                           (not (eq? (entry-owner old) (entry-owner new))))
                                         (hash-ref slots name []))))
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
  (match (entry-table-entries table name)
    ([best . _] best)
    (else #f)))

;; Every entry for NAME, effective one first.
(def (entry-table-entries (table : entry-table) (name : :t)) => :list
  (list-sort entry-outranks? (hash-ref (entry-table-slots table) name [])))

;; The names that have entries.
(def (entry-table-names (table : entry-table)) => :list
  (hash-keys (entry-table-slots table)))
