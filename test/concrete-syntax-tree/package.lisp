(cl:defpackage #:eclector.concrete-syntax-tree.test
  (:use
   #:common-lisp
   #:fiveam)

  (:export
   #:run-tests))

(cl:in-package #:eclector.concrete-syntax-tree.test)

(def-suite :eclector.concrete-syntax-tree)

(defun run-tests ()
  (run! :eclector.concrete-syntax-tree))
