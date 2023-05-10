(cl:in-package #:eclector.parse-result)

;;; Instances wrap an "inner", ordinary labeled objects (that is
;;; whatever the next MAKE-LABELED-OBJECT method for the current
;;; client returns) so that a parse result can be associated with the
;;; labeled object in addition to the final object which the inner
;;; labeled object stores. An additional "outer" labeled object is
;;; stored in case additional methods on MAKE-LABELED-OBJECT in turn
;;; wrap the %WRAPPER instance in some other object (which is the case
;;; by default; see the "Fixup work tree" section in
;;; reader/labeled-objects.lisp).
(defstruct (%wrapper (:constructor %make-wrapper (inner))
                     (:predicate nil)
                     (:copier nil))
  (inner (error "required") :read-only t)
  (outer)
  (parse-result nil))

;;; A binding with value NIL is established in the RAD-MAYBE-NOTHING
;;; method specialized to PARSE-RESULT-CLIENT. The value of the
;;; binding is changed to a %WRAPPER object in a MAKE-LABELED-OBJECT
;;; below.
(defvar *wrapper*)

(defmethod eclector.reader:make-labeled-object ((client parse-result-client)
                                                input-stream
                                                (label integer)
                                                parent)
  (declare (ignore input-stream parent))
  ;; Wrap inner labeled object.
  (let ((labeled-object (call-next-method)))
    (setf *wrapper* (%make-wrapper labeled-object))))

(defmethod eclector.reader:make-labeled-object :around ((client parse-result-client)
                                                        input-stream
                                                        (label integer)
                                                        parent)
  (declare (ignore input-stream parent))
  ;; Remember outermost labeled object in wrapper.
  (let ((labeled-object (call-next-method)))
    (setf (%wrapper-outer *wrapper*) labeled-object)
    labeled-object))

(defmethod eclector.reader:labeled-object-state ((client parse-result-client)
                                                 (labeled-object %wrapper))
  ;; Get state from inner labeled object and return the associated
  ;; parse result as an additional value.
  (let* ((inner-labeled-object (%wrapper-inner labeled-object))
         (parse-result (%wrapper-parse-result labeled-object)))
    (multiple-value-bind (state object)
        (eclector.reader:labeled-object-state client inner-labeled-object)
      (values state object parse-result))))

(defmethod eclector.reader:finalize-labeled-object ((client parse-result-client)
                                                    (labeled-object %wrapper)
                                                    object)
  ;; Delegate everything to the inner labeled object.
  (let* ((inner-labeled-object (%wrapper-inner labeled-object))
         (new-state (nth-value
                     1 (eclector.reader:finalize-labeled-object
                        client inner-labeled-object object))))
    (values labeled-object new-state)))

(defmethod eclector.reader:reference-labeled-object ((client parse-result-client)
                                                     input-stream
                                                     (labeled-object %wrapper))
  ;; Stash LABELED-OBJECT for MAKE-EXPRESSION-RESULT, delegate
  ;; everything else to the inner labeled object.
  (setf *wrapper* labeled-object)
  (let* ((inner-labeled-object (%wrapper-inner labeled-object))
         (result (eclector.reader:reference-labeled-object
                  client input-stream inner-labeled-object)))
    (if (eq result inner-labeled-object)
        labeled-object
        result)))

(defmethod make-expression-result :around ((client parse-result-client)
                                           result
                                           (children list)
                                           source)
  (declare (ignore result))
  ;; This is the complicated one.  In case MAKE-LABELED-OBJECT or
  ;; REFERENCE-LABELED-OBJECT was called in the READ call for which we
  ;; construct the expression result, *WRAPPER* is bound to a %WRAPPER
  ;; instance.
  (let ((wrapper *wrapper*))
    (if (null wrapper)
        (call-next-method) ; no definition or reference, nothing to do
        (let* ((inner-labeled-object (%wrapper-inner wrapper))
               (state (eclector.reader:labeled-object-state
                       client inner-labeled-object)))
          (cond ((not (find state '(:final :final/circular))) ; inner not finalized
                 (call-next-method))
                ((not (null (%wrapper-parse-result wrapper))) ; parse result in labeled object
                 (make-expression-result client **reference** wrapper source))
                ((not (null children)) ; inner finalized, no parse result, child
                 ;; CHILDREN can have multiple elements if we skipped
                 ;; over some material before reading an object.  The
                 ;; object will be the final child.
                 (setf (%wrapper-parse-result wrapper)
                       (alexandria:lastcar children))
                 ;; The outermost wrapping labeled object may have
                 ;; more information regarding when to fix things up.
                 (let ((outer (%wrapper-outer wrapper)))
                   (when (eclector.reader:fixup-graph-p client outer)
                     ;; Fix up the graph of parse results.
                     (eclector.reader:fixup-graph
                      client outer
                      :object-key (lambda (client labeled-object)
                                    (declare (ignore client))
                                    (%wrapper-parse-result labeled-object)))))
                 (make-expression-result client **definition** wrapper source))
                (t ; inner finalized, no parse result, but also no child
                 ;; This can happen when the clients chooses to
                 ;; recover for input like #1=.  In that case, no
                 ;; child parse results will be recorded.  This is
                 ;; fine however, since the next method will simply
                 ;; produce a parse result for the replacement value
                 ;; which is the value of RESULT.
                 (call-next-method)))))))

(defmethod make-expression-result ((client parse-result-client)
                                   (result (eql **definition**))
                                   children
                                   source)
  (declare (ignore source))
  ;; In a slight abuse of the protocol, CHILDREN is the labeled object
  ;; being defined and the third return value of the
  ;; LABELED-OBJECT-STATE call is the parse result of the labeled
  ;; object.
  (nth-value 2 (eclector.reader:labeled-object-state client children)))

(defmethod make-expression-result ((client parse-result-client)
                                   (result (eql **reference**))
                                   children
                                   source)
  (declare (ignore source))
  ;; In a slight abuse of the protocol, CHILDREN is the labeled object
  ;; being defined and the third return value of the
  ;; LABELED-OBJECT-STATE call is the parse result of the labeled
  ;; object.
  (nth-value 2 (eclector.reader:labeled-object-state client children)))

(defmethod eclector.reader:fixup-graph-p ((client parse-result-client)
                                          (root-labeled-object %wrapper))
  (let ((inner-labeled-object (%wrapper-inner root-labeled-object)))
    (eclector.reader:fixup-graph-p client inner-labeled-object)))
