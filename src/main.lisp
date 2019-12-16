(defpackage gir2cl
  (:use :cl)
  (:import-from #:cxml)
  (:import-from #:gir)
  (:import-from #:kebab)
  (:import-from #:simple-date-time)
  (:export
   #:generate))
(in-package :gir2cl)

;; repository
;; |- include
;; |- package
;; |- namespace
;; |-+
;; | |- class
;; | |-+
;; | | |- source-position
;; | | |- method
;; | | |-+
;; | | | |- source-position
;; | | | |- return-value
;; | | | |- parameters
;; | | | |-+
;; | | | | |- instance-parameter
;; | | | | |-+
;; | | | | | |- doc
;; | | | | | |- type
;; | | | | |- parameter
;; | | | | |-+
;; | | | | | |- doc
;; | | | | | |- type

(defun generate (package-name namespace stream gir-pathname)
  "Generates low-level Common Lisp bindings from the GIR filepath
passed in. Returns a list of exported symbols."
  (check-type package-name string)
  (check-type gir-pathname pathname)
  (check-type stream (or stream boolean))

  (let ((*package* (find-package :cl-user))
        (handler (make-instance 'gir-handler :namespace namespace :output-stream stream)))

    (format stream ";;;; Generated by gir2cl on ~a~%~%" (simple-date-time:rfc-2822
                                                         (simple-date-time:now)))
    (format stream "(in-package ~a)~%~%" package-name)
    (format stream "(defparameter *ns* (gir:require-namespace \"~@*~a\"))~%~%"
            namespace)

    (format stream "~(~s~)~%~%"
            '(defclass cl-user::gir-object ()
              ((cl-user::native-pointer :initarg :native-pointer :reader cl-user::native-pointer))))

    (cxml:parse-file gir-pathname handler)

    (cons 'cl-user::gir-object (cons 'cl-user::native-pointer (reverse (all-symbols handler))))))

(defclass gir-class ()
  ((name :type symbol
         :initarg :name
         :reader name)
   (gir-name :type string
             :initarg :gir-name
             :reader gir-name)
   (slots :type list
          :initform (list)
          :accessor slots)
   (parent-clos-class :type symbol
                      :initarg :parent-clos-class
                      :initform nil)
   (constructors :type list
                 :initform (list)
                 :accessor constructors)
   (methods :type list
            :initform (list)
            :accessor methods)))

(defmethod print-object ((class gir-class) stream)
  (with-slots (name slots parent-clos-class)
      class
    (format
     stream
     "~(~s~)"
     `(defclass ,name ,(if parent-clos-class
                           (list parent-clos-class)
                           '(cl-user::gir-object))
        (,@slots)))))

(defclass gir-method ()
  ((name :type symbol
         :initarg :name
         :reader name)
   (gir-name :type string
             :initarg :gir-name)
   (class-name :type string
               :initarg :class-name)
   (parameters :type list
               :initform (list)
               :accessor parameters)))

(defmethod print-object ((method gir-method) stream)
  (with-slots (name gir-name class-name parameters)
      method
    (let ((parameters (reverse parameters)))
      (format
       stream
       "~(~s~)"
       `(defmethod ,name ((,class-name ,class-name) ,@parameters)
          (with-slots (cl-user::native-pointer)
              ,class-name
            (gir:invoke (cl-user::native-pointer ,gir-name) ,@parameters)))))))

(defclass gir-function ()
  ((clos-class-name :type symbol
                    :initarg :clos-class-name)
   (gir-class-name :type string
                   :initarg :gir-class-name)
   (name :type symbol
         :initarg :name)
   (gir-name :type string
             :initarg :gir-name)
   (parameters :type list
               :initform (list)
               :accessor parameters)))

(defmethod name-symbol ((function gir-function))
  "Generates a symbol for the name of the constructor."
  (with-slots (clos-class-name name)
      function
    (intern (format nil "~:@(make-~a-~s~)" clos-class-name name))))

(defmethod print-object ((function gir-function) stream)
  (with-slots (clos-class-name gir-class-name gir-name parameters)
      function
    (let ((parameters (reverse parameters)))

      ;; First format is to inject the GIR class name in its proper
      ;; case. The second is to print the lisp bits in lowercase.
      (format
       stream
       (format
        nil
        "~(~s~)"
        `(defun ,(name-symbol function) (,@parameters)
           (let ((cl-user::pointer (gir:invoke (cl-user::*ns* "~a" ,gir-name) ,@parameters)))
             (make-instance ',clos-class-name :native-pointer cl-user::pointer))))
       gir-class-name))))

(defclass gir-parameter ()
  ((name :type string
         :initarg :name
         :reader name)
   (type :type type
         :initarg :type
         :initform nil
         :accessor gir-type)))

(defmethod print-object ((parameter gir-parameter) stream)
  (with-slots (name)
      parameter
    (format stream "~(~a~)" name)))

(defclass gir-handler (sax:default-handler)
  ((namespace :type string
              :initarg :namespace
              :initform (error "namespace must be specified.")
              :reader namespace)
   (clos-from-gir :type hash-table
                  :initform (make-hash-table :test #'equalp)
                  :accessor clos-from-gir)
   (output-stream :type stream
                  :initarg :output-stream
                  :initform (error "output-stream must be specified."))
   (current-class :type gir-class
                  :accessor current-class)
   (current-constructor :type gir-class
                        :accessor current-constructor)
   (current-method :type gir-method
                   :accessor current-method)
   (current-parameter :type gir-parameter
                      :initform nil
                      :accessor current-parameter)
   (within-interface-element :type boolean
                             :initform nil
                             :accessor within-interface-element)
   (all-symbols :type list
                :initform (list)
                :accessor all-symbols
                :documentation
                "A list of all symbols that are generated.")))

(defmethod sax:start-element ((handler gir-handler) namespace-uri local-name qname attributes)

  (flet ((element-attr (attr-name)
           (sax:attribute-value
            (find attr-name attributes :key #'sax:attribute-local-name :test #'string=))))

    (cond
      ((string= local-name "interface")
       ;; We don't do anything with interfaces, but we must denote
       ;; their traversal to avoid populating invalid constructs.
       (setf (within-interface-element handler) t))

      ((string= local-name "class")
       (let* ((name (element-attr "name"))
              (parent (element-attr "parent"))
              (shadowed (find-symbol (string-upcase (kebab:to-kebab-case name))))
              (acceptable-name (kebab-symbol-from-string
                                (if shadowed (concatenate 'string (namespace handler) name) name)))
              (class (make-instance 'gir-class
                                    :name acceptable-name
                                    :gir-name name
                                    :parent-clos-class (gethash parent (clos-from-gir handler)))))

         (setf (gethash name (clos-from-gir handler)) acceptable-name)
         (setf (current-class handler) class)))

      ((string= local-name "constructor")
       (let* ((name (element-attr "name"))
              (constructor (make-instance 'gir-function
                                          :name (kebab-symbol-from-string name)
                                          :gir-name name
                                          :clos-class-name (name (current-class handler))
                                          :gir-class-name (gir-name (current-class handler)))))

         (setf (current-constructor handler) constructor)))

      ((and (string= local-name "method")
            (not (within-interface-element handler)))
       (let* ((name (element-attr "name"))
              (class-namespaced-name (format nil "~(~a-~a~)"
                                             (name (current-class handler))
                                             name))
              (shadowed (find-symbol (string-upcase (kebab:to-kebab-case class-namespaced-name))))
              (acceptable-name (kebab-symbol-from-string
                                (if shadowed
                                    (concatenate 'string (namespace handler) class-namespaced-name)
                                    class-namespaced-name)))
              (method (make-instance 'gir-method
                                     :name acceptable-name
                                     :gir-name name
                                     :class-name (name (current-class handler)))))

         (setf (current-method handler) method)))

      ((and (find local-name (list "parameter" #|"instance-parameter"|#) :test #'string=)
            (not (within-interface-element handler)))
       (let* ((name (element-attr "name"))
              (parameter (make-instance 'gir-parameter :name (kebab-symbol-from-string name))))

         (setf (current-parameter handler) parameter)))

      ((and (string= local-name "array")
            (current-parameter handler))
       ;; For array parameters, we need only know that they are arrays
       ;; so that we can ellide the subsequent length parameter.
       (setf (gir-type (current-parameter handler)) 'array)))))

(defmethod sax:end-element ((handler gir-handler) namespace-uri local-name qname)
  (cond
    ((string= local-name "interface")
     (setf (within-interface-element handler) nil))

    ((string= local-name "class")
     ;; Write out the current class and its methods

     (with-slots (output-stream current-class all-symbols)
         handler

       (setf all-symbols (cons (name current-class) all-symbols))

       ;; Write everything about the class out to the stream.
       (format output-stream "~a~%~%" current-class)
       (dolist (c (reverse (constructors current-class)))
         (format output-stream "~a~%~%" c))
       (dolist (m (reverse (methods current-class)))
         (format output-stream "~a~%~%" m))

       ;; Clear out the current class
       (setf current-class nil)))

    ((string= local-name "constructor")
     ;; Add the current constructor to the current class
     (with-slots (current-class current-constructor all-symbols)
         handler
       (dolist (p (parameters current-constructor))
         (pushnew p (slots current-class) :key #'name :test #'string=))
       (pushnew current-constructor (constructors current-class))
       (setf all-symbols (cons (name-symbol current-constructor) all-symbols))
       (setf current-constructor nil)))

    ((and (string= local-name "method")
          (not (within-interface-element handler)))
     ;; Add the current method to the current class
     (with-slots (current-class current-method all-symbols)
         handler
       (pushnew current-method (methods current-class))
       (setf all-symbols (cons (name current-method) all-symbols))
       (setf current-method nil)))

    ((and (find local-name (list "parameter" #|"instance-parameter"|#) :test #'string=)
          (not (within-interface-element handler))
          ;; The cl-gobject-introspection library handles passing the
          ;; length of sequences for us. Don't include the parameter
          ;; in our bindings.
          ;; TODO(katco): How does the gir lib check this, and can we use that here?
          (let* ((current-obj (or (and (slot-boundp handler 'current-method) (current-method handler))
                                  (current-constructor handler)))
                 (last-param (when current-obj (car (parameters current-obj)))))
            (if last-param
                (not (eq (gir-type last-param) 'array))
                t)))

     ;; Add parameter to current method
     (with-slots (current-method current-constructor current-parameter)
         handler

       (if (and (slot-boundp handler 'current-method) current-method)
           (pushnew current-parameter (parameters current-method))
           (pushnew current-parameter (parameters current-constructor)))
       (setf current-parameter nil)))))

(defun kebab-symbol-from-string (s)
  (check-type s string)
  (intern (string-upcase (kebab:to-kebab-case s))))