;;;; SPDX-FileCopyrightText: Atlas Engineer LLC
;;;; SPDX-License-Identifier: BSD-3-Clause

(in-package :nyxt)

(define-class history-entry ()
  ((url (quri:uri "")
        :type (or quri:uri string))
   (title "")
   (id ""
       :documentation "The `id' of the buffer that this entry belongs to the branch of.")
   (last-access (local-time:now)
                :type (or local-time:timestamp string))
   ;; TODO: For now we never increment the explicit-visits count.  Maybe we
   ;; could use a new buffer slot to signal that the last load came from an
   ;; explicit request?
   (explicit-visits 0
                    :type integer
                    :documentation "
Number of times the URL was visited by a minibuffer request.  This does not
include implicit visits.")
   (implicit-visits 0
                    :type integer
                    :documentation "
Number of times the URL was visited by following a link on a page.  This does
not include explicit visits."))
  (:accessor-name-transformer #'class*:name-identity)
  (:documentation "
Entry for the global history.
The total number of visit for a given URL is (+ explicit-visits implicit-visits)."))

(defmethod object-string ((entry history-entry))
  (object-string (url entry)))

(defmethod object-display ((entry history-entry))
  (format nil "~a  ~a" (object-display (url entry)) (title entry)))

(defmethod equals ((e1 history-entry) (e2 history-entry))
  ;; We need to compare IDs to preserve history entries of different buffers.
  ;; TODO: Should we?
  (and (string= (id e1) (id e2))
       (quri:uri= (url e1) (url e2))))

(defmethod url ((he history-entry))
  "This accessor ensures we always return a `quri:uri'.
This is useful in cases the URL is originally stored as a string (for instance
when deserializing a `history-entry').

We can't use `initialize-instance :after' to convert the URL because
`s-serialization:deserialize-sexp' sets the slots manually after making the
class."
  (unless (quri:uri-p (slot-value he 'url))
    (setf (slot-value he 'url) (ensure-url (slot-value he 'url))))
  (slot-value he 'url))

(defmethod last-access ((he history-entry))
  "This accessor ensures we always return a `local-time:timestamp'.
This is useful in cases the timestamp is originally stored as a
string (for instance when deserializing a `history-entry').

We can't use `initialize-instance :after' to convert the timestamp
because `s-serialization:deserialize-sexp' sets the slots manually
after making the class."
  (unless (typep (slot-value he 'last-access) 'local-time:timestamp)
    (setf (slot-value he 'last-access)
          (local-time:parse-timestring (slot-value he 'last-access))))
  (slot-value he 'last-access))

(defmethod s-serialization::serialize-sexp-internal ((he history-entry)
                                                     stream
                                                     serialization-state)
  "Serialize `buffer-description' by turning the URL into a string."
  (let ((new-he (make-instance 'history-entry
                               :title (title he)
                               :id (id he)
                               :explicit-visits (explicit-visits he)
                               :implicit-visits (implicit-visits he))))
    (setf (url new-he) (object-string (url he))
          (last-access new-he) (local-time:format-timestring nil (last-access he)))
    (call-next-method new-he stream serialization-state)))

(declaim (ftype (function (quri:uri &key (:title string) (:explicit t)) t) history-add))
(export-always 'history-add)
(defun history-add (uri &key title explicit)
  "Add URL to the global/buffer-local history.
The `implicit-visits' count is incremented unless EXPLICIT is non-nil, in which
case `explicit-visits'."
  ;; It is implied that `history-add' is invoked only in
  ;; `on-signal-notify-uri' in response to
  ;; `buffer-load'. `buffer-load' has its own data syncronization, so
  ;; we imply that history is up-to-date there.  Using
  ;; `with-data-access' is not an option -- it will cause the new
  ;; thread and the thread from `buffer-load' to mutually deadlock.
  (let ((history (or (get-data (history-path (current-buffer)))
                     (htree:make))))
    (unless (url-empty-p uri)
      (let* ((maybe-entry (make-instance 'history-entry
                                         :url uri :id (id (current-buffer))
                                         :title (or title "")))
             (node (htree:find-data maybe-entry history :ensure-p t :test #'equals))
             (entry (htree:data node)))
        (if explicit
            (incf (explicit-visits entry))
            (incf (implicit-visits entry)))
        (setf (last-access entry) (local-time:now))
        (when title
          ;; Always update the title since it may have changed since last visit.
          (setf (title entry) title))
        (setf (htree:data node) entry
              (htree:current history) node
              (current-history-node (current-buffer)) (htree:current history))))
    (setf (get-data (history-path (current-buffer))) history)))

(define-command delete-history-entry ()
  "Delete queried history entries."
  (with-data-access (history (history-path (current-buffer)))
    (let ((entries (prompt-minibuffer
                    :input-prompt "Delete entries"
                    :suggestion-function (history-suggestion-filter)
                    :history (minibuffer-set-url-history *browser*)
                    :multi-selection-p t)))
      (dolist (entry entries)
        (htree:delete-data entry history :test #'equals :rebind-children-p t)))))

(defmethod make-buffer-from-history ((root htree:node) (history htree:history-tree))
  "Create the buffer with the history starting from the ROOT.
Open the latest child of ROOT."
  (let* ((node (let ((latest root))
                 (htree:do-tree (node history)
                   (let ((node-data (htree:data node))
                         (latest-data (htree:data latest)))
                     (when (and (string= (id node-data) (id latest-data))
                                (local-time:timestamp>= (last-access node-data)
                                                        (last-access latest-data)))
                       (setf latest node))))
                 latest))
         (entry (htree:data node))
         (buffer (make-buffer :url (ensure-url (url entry))
                              :load-url-p nil
                              :title (title entry))))
    (setf (slot-value buffer 'load-status) :unloaded
          (current-history-node buffer) node)
    (htree:do-tree (node history)
      (let ((root-id (id (htree:data root)))
            (new-id (id buffer)))
        (with-slots (id) (htree:data node)
          (setf id (case id
                     (root-id new-id)
                     ;; This is to escape collisions of the new buffer ID with old buffer IDs.
                     (new-id root-id)
                     (t id))))))
    buffer))


(defun score-history-entry (entry)
  "Return history ENTRY score.
The score gets higher for more recent entries and if they've been visited a
lot."
  (+ (* 0.1
        ;; Total number of visits.
        (+ (implicit-visits entry)
           (explicit-visits entry)))
     (* 1.0
        ;; Inverse number of hours since the last access.
        (/ 1
           (1+ (/ (local-time:timestamp-difference (local-time:now)
                                                   (last-access entry))
                  (* 60 60)))))))

(defun history-suggestion-filter (&key prefix-urls)
  "Include prefix-urls in front of the history.
This can be useful to, say, prefix the history with the current URL.  At the
moment the PREFIX-URLS are inserted as is, not a `history-entry' objects since
it would not be very useful."
  (with-data-access (hist (history-path (current-buffer)))
      (let* ((history (when hist
                        (sort (htree:all-nodes-data hist)
                              (lambda (x y)
                                (> (score-history-entry x)
                                   (score-history-entry y))))))
          (prefix-urls (delete-if #'uiop:emptyp prefix-urls)))
     (when prefix-urls
       (setf history (append (mapcar #'quri:url-decode prefix-urls) history)))
     (lambda (minibuffer)
       (fuzzy-match (input-buffer minibuffer) history)))))

(defun history-stored-data (path)
  "Return the history data that needs to be serialized.
This data can be used to restore the session later, e.g. when starting a new
instance of Nyxt."
  (list +version+ (get-data path)))

(defmethod store ((profile data-profile) (path history-data-path) &key &allow-other-keys)
  "Store the global/buffer-local history to the PATH."
  (with-data-file (file path
                        :direction :output
                        :if-does-not-exist :create
                        :if-exists :supersede)
    ;; We READ the output of serialize-sexp to make it more human-readable.
    (let ((*package* (find-package :nyxt))
          (*print-length* nil))
      ;; We need to make sure current package is :nyxt so that
      ;; symbols are printed with consistent namespaces.
      (format file
              "~s"
              (with-input-from-string (in (with-output-to-string (out)
                                            (s-serialization:serialize-sexp
                                             (history-stored-data path)
                                             out)))
                (read in))))))

;; REVIEW: This works around the issue of cl-prevalence to deserialize structs
;; with custom constructors: https://github.com/40ants/cl-prevalence/issues/16.
(setf (fdefinition 'quri.uri::make-uri) #'quri.uri::%make-uri)

(defmethod restore ((profile data-profile) (path history-data-path)
                    &key restore-session-p &allow-other-keys)
  "Restore the global/buffer-local history and session from the PATH."
  (handler-case
      (let ((data (with-data-file (file path
                                        :direction :input
                                        :if-does-not-exist nil)
                    (when file
                      ;; We need to make sure current package is :nyxt so that
                      ;; symbols are printed with consistent namespaces.
                      (let ((*package* (find-package :nyxt)))
                        (s-serialization:deserialize-sexp file))))))
        (match data
          (nil nil)
          ((guard (list version history) t)
           (ctypecase history
             (htree:history-tree
              (unless (string= version +version+)
                (log:warn "History version ~s differs from current version ~s"
                          version +version+))
              (echo "Loading history of ~a URLs from ~s."
                    (htree:size history)
                    (expand-path path))
              (setf (get-data path) history)
              (when restore-session-p
                (sera:and-let* ((buffer-histories (buffer-local-histories-table history)))
                  ;; Make the new buffers.
                  (dolist (root (alex:hash-table-values buffer-histories))
                    (make-buffer-from-history root history))
                  ;; Switch to the last active buffer.
                  (when (htree:current history)
                    (switch-buffer
                     :id (id (htree:data (htree:current history))))))))
             (hash-table
              (echo "Importing deprecated global history of ~a URLs from ~s."
                    (hash-table-count history)
                    (expand-path path))
              (unless (get-data path)
                (setf (get-data path) (htree:make)))
              (htree:add-children (alex:hash-table-values history) (get-data path)
                                  :test #'equals))))
          (_ (error "Expected (list version history) structure."))))
    (error (c)
      (echo-warning "Failed to restore history from ~a: ~a"
                    (expand-path path) c))))
