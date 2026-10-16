;;; Shared owned composition; each target keeps its own execution/cache boundary.
prelude: :gerbil/core

(import :std/error
        :std/list/list
        (only-in :gerbil/expander import-module current-expander-context)
        :tuna/kernel)
(export open-function new-open-function open-function-base open-function-effective
        open-function-state replace-open-function! resolve-open-function
        advice-state new-advice-state advice-state-records
        register-advice! remove-advice! inspect-advice
        advised-functions compose-advice refresh-advice!
        advice-info advice-info-owner advice-info-name advice-info-kind
        advice-info-depth advice-info-source
        advice-target-info advice-target-info-kind advice-target-info-name
        advice-target-info-source advice-target-info-identity advice-target-info-advice
        advice-error?)

(deferror-class AdviceError () advice-error?)

;; Only read accessors are public. CTX and CALLBACK are installation details.
(defstruct advice-info ((owner : :symbol) (name : :symbol) (kind : :symbol)
                       (depth : :fixnum) (source :? :string)
                       (ctx : context) (callback : :procedure))
  final: #t)
(defstruct advice-target-info ((kind : :symbol) (name : :symbol) (source :? :string)
                              (identity : :t) (advice : :list))
  final: #t)
(defstruct advice-owner ((records : :list)) final: #t)
(defstruct advice-state ((kind : :symbol) (name : :symbol) (source :? :string)
                        (owners : entry-table) (records : :list) (changed : :procedure))
  final: #t)
(defstruct open-function ((base : :procedure) (effective : :procedure)
                         (state : advice-state))
  final: #t)

;; Only installed chains need rank refresh, not all possible functions/targets.
(def active-advice-states [])

;; CHANGED receives the installed outermost-first records on mutation/rank refresh.
;; It rebuilds the target's cache from its current base(s), never from old wrappers.
(def (new-advice-state (kind : :symbol) (name : :symbol) (source :? :string)
                       (changed : :procedure)) => advice-state
  (make-advice-state kind name source (new-entry-table) [] changed))

(def (new-open-function (base : :procedure) (name : :symbol) (source :? :string)) => open-function
  (letrec ((state (new-advice-state 'function name source
                   (lambda (records)
                     (set! (open-function-effective cell)
                       (compose-advice (open-function-base cell) records)))))
           (cell (make-open-function base base state)))
    cell))

(def (ordered-advice (state : advice-state)) => :list
  ;; Earlier declarations are outermost; names break ties within one owner.
  ;; All ordering work happens on changes, never on calls.
  (let* ((entries (reverse (entry-table-entries state.owners 'advice)))
         (owners (map entry-owner entries)))
    (list-sort
     (lambda ((a : advice-info) (b : advice-info))
       (or (fx< a.depth b.depth)
           (and (fx= a.depth b.depth)
                (if (eq? a.owner b.owner)
                  (string<? (symbol->string a.name) (symbol->string b.name))
                  (and (memq b.owner (cdr (memq a.owner owners))) #t)))))
     (append-map (lambda ((e : entry))
                   (advice-owner-records (: (entry-value e) advice-owner)))
                 entries))))

(def (inspect-advice (state : advice-state)) => advice-target-info
  ;; The state is an opaque, stable selection identity, independent of snapshots.
  (make-advice-target-info state.kind state.name state.source state state.records))

(def (advised-functions) => :list
  (map inspect-advice
       (filter (lambda ((state : advice-state)) (eq? state.kind 'function))
               active-advice-states)))

(def (refresh-advice-state! (state : advice-state)) => :void
  (let (records (ordered-advice state))
    (set! state.records records)
    (set! active-advice-states
      (if (null? records) (remq state active-advice-states)
          (if (memq state active-advice-states) active-advice-states
              (cons state active-advice-states))))
    (state.changed records)))

;; Configuration calls this once after a batch of owner declaration-rank updates.
(def (refresh-advice!) => :void
  (for-each refresh-advice-state! active-advice-states))

(def (replace-open-function! (cell : open-function) (replacement : :procedure)) => :void
  (set! cell.base replacement)
  (refresh-advice-state! cell.state))

(def (resolve-open-function (module : :t) (name : :symbol)) => open-function
  ;; The documented enter! path uses the existing module instance, never reloads.
  (parameterize ((current-expander-context (import-module module #f #t)))
    (: (eval (list 'open-function-cell name)) open-function)))

(def (find-advice-owner (state : advice-state) (ctx : context)) => (Maybe advice-owner)
  (let (found (find (lambda ((e : entry))
                     (eq? (entry-owner e) (context-plugin-name ctx)))
                   (entry-table-entries state.owners 'advice)))
    (and found (: (entry-value found) advice-owner))))

(def (register-advice! (ctx : context) (state : advice-state)
                       (name : :symbol) (kind : :symbol) (callback : :procedure)
                       depth: (depth : :fixnum := 0)
                       source: (source :? :string := #f)) => :void
  (unless (memq kind '(before after around override filter-args filter-return
                      before-while before-until after-while after-until))
    (error "Unknown advice kind" kind))
  (let* ((bucket (or (find-advice-owner state ctx)
                     (let (new (make-advice-owner []))
                       ;; Receipt order matters: remove the entry, then recompose.
                       ;; One pair per owner/target; replacements add no inverses.
                       (context-defer! ctx (lambda () (refresh-advice-state! state)))
                       (context-add-entry! ctx state.owners 'advice new)
                       new)))
         (record (make-advice-info (context-plugin-name ctx) name kind depth source ctx callback)))
    (set! (advice-owner-records bucket)
      (cons record (filter (lambda ((old : advice-info)) (not (eq? old.name name)))
                           (advice-owner-records bucket))))
    (refresh-advice-state! state)))

(def (remove-advice! (ctx : context) (state : advice-state) (name : :symbol)) => :void
  (let (bucket (find-advice-owner state ctx))
    (when bucket
      (set! (advice-owner-records bucket)
        (filter (lambda ((old : advice-info)) (not (eq? old.name name)))
                (advice-owner-records bucket)))
      (refresh-advice-state! state))))

(def (raise-advice-failure (record : advice-info) (cause : :t)) => :void
  (raise (AdviceError "Advice failed (owner, name, cause)"
                      irritants: [record.owner record.name cause] where: 'advise!)))

;; Catch only callback failures, never normal-return continuations or the base.
(def (call-advice (record : advice-info) (args : :list)) => :values
  (with-catch
   (lambda (e) (if (quit-condition? e) (raise e) (raise-advice-failure record e)))
   (lambda ()
     (call-with-context record.ctx (lambda () (apply record.callback args))))))

(def (call-advice-predicate (record : advice-info) (args : :list)) => :t
  (call-with-values (lambda () (call-advice record args))
    (lambda results
      (unless (and (pair? results) (null? (cdr results)))
        (raise-advice-failure record "Predicate advice must return exactly one value"))
      (car results))))

(def (compose-layer (record : advice-info) (inner : :procedure)) => :procedure
  (case record.kind
    ((before)
     (lambda args
       (call-with-values (lambda () (call-advice record args))
         (lambda ignored (apply inner args)))))
    ((after)
     (lambda args
       (call-with-values (lambda () (apply inner args))
         (lambda results
           (call-with-values (lambda () (call-advice record args))
             (lambda ignored (apply values results)))))))
    ((around)
     (lambda args
       (let ((caller (current-context)) (inner-failures []))
         (with-catch
          (lambda (e)
            (if (or (quit-condition? e) (memq e inner-failures))
              (raise e) (raise-advice-failure record e)))
          (lambda ()
            (call-with-context record.ctx
              (lambda ()
                (apply record.callback
                  (lambda original-args
                    (with-catch
                     (lambda (e) (set! inner-failures (cons e inner-failures)) (raise e))
                     (lambda ()
                       ;; ORIGINAL retains the caller's registration context and task.
                       (call-with-context caller (lambda () (apply inner original-args))))))
                  args))))))))
    ((override) (lambda args (call-advice record args)))
    ((filter-args)
     (lambda args
       (let (filtered (call-advice-predicate record [args]))
         (unless (list? filtered)
           (raise-advice-failure record "filter-args must return one argument list"))
         (apply inner filtered))))
    ((filter-return)
     ;; Each returned value becomes one callback argument; any output arity is valid.
     (lambda args
       (call-with-values (lambda () (apply inner args))
         (lambda results (call-advice record results)))))
    ((before-while before-until)
     ;; The callback is a single-value predicate; the selected inner result is unrestricted.
     (lambda args
       (let (result (call-advice-predicate record args))
         (if (if (eq? record.kind 'before-while) result (not result))
           (apply inner args) result))))
    ((after-while after-until)
     ;; INNER is a single-value predicate; the selected callback result is unrestricted.
     (lambda args
       (call-with-values (lambda () (apply inner args))
         (lambda results
           (unless (and (pair? results) (null? (cdr results)))
             (error "Conditional advice requires exactly one inner value" record.kind))
           (let (result (car results))
             (if (if (eq? record.kind 'after-while) result (not result))
               (call-advice record args) result))))))
    (else (error "Unknown advice kind" record.kind))))

;; RECORDS are outermost first. An empty chain is exactly BASE, not a wrapper.
(def (compose-advice (base : :procedure) (records : :list)) => :procedure
  (foldr (lambda ((record : advice-info) (inner : :procedure))
           (compose-layer record inner))
         base records))
