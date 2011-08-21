;;;; cl-messagepack.lisp

(in-package #:cl-messagepack)

(declaim (optimize (debug 3)))

(eval-when (:compile-toplevel :load-toplevel :execute)
  (defun mkstr (&rest args)
    (format nil "~{~a~}" args))
  (defun mksymb (&rest args)
    (intern (apply #'mkstr args))))

(defmacro signed-unsigned-convertors (size)
  (let ((speed (if (< size 32) 3 0)))
    `(progn
       (defun ,(mksymb 'sb size '-> 'ub size) (sb)
         (declare (optimize (debug 0) (safety 0) (speed ,speed))
                  (type (integer ,(- (expt 2 (1- size))) ,(1- (expt 2 (1- size)))) sb))
         (if (< sb 0)
             (ldb (byte ,size 0) sb)
             sb))
       (defun ,(mksymb 'ub size '-> 'sb size) (sb)
         (declare (optimize (debug 0) (safety 0) (speed ,speed))
                  (type (mod ,(expt 2 size)) sb))
         (if (logbitp (1- ,size) sb)
             (- (1+ (logxor (1- (expt 2 ,size)) sb)))
             sb)))))

(signed-unsigned-convertors 8)
(signed-unsigned-convertors 16)
(signed-unsigned-convertors 32)
(signed-unsigned-convertors 64)

(defun write-hex (data)
  (let (line)
    (loop
       for i from 0 to (1- (length data))
       do (push (elt data i) line)
       when (= (length line) 16)
       do
         (format t "~{~2,'0x ~}~%" (nreverse line))
         (setf line nil))
    (when line
      (format t "~{~2,'0x ~}~%" (nreverse line)))))

(defun encode (data)
  (flexi-streams:with-output-to-sequence (stream)
    (encode-implementation data stream)))

(defun make-hash (data)
  (let ((result (make-hash-table)))
    (dolist (kv data)
      (cond ((consp (cdr kv))
             (setf (gethash (first kv) result) (second kv)))
            (t
             (setf (gethash (car kv) result) (cdr kv)))))
    result))

(defun is-byte-array (data-type)
  (and (vectorp data-type)
       (equal '(unsigned-byte 8) (array-element-type data-type))))

(defun encode-implementation (data stream)
  (cond ((floatp data) (encode-float data stream))
        ((numberp data) (encode-integer data stream))
        ((null data) (write-byte #xc0 stream))
        ((eq data t) (write-byte #xc3 stream))
        ((stringp data)
         (encode-string data stream))
        ((is-byte-array data)
         (encode-raw-bytes data stream))
        ((or (consp data) (vectorp data))
         (encode-array data stream))
        ((hash-table-p data)
         (encode-hash data stream))
        ((symbolp data)
         (encode-string (symbol-name data) stream))
        (t (error "Cannot encode data."))))

(defun encode-string (data stream)
  (encode-raw-bytes (babel:string-to-octets data) stream))

#+sbcl (defun sbcl-encode-float (data stream)
         (cond ((equal (type-of data) 'single-float)
                (write-byte #xca stream)
                (store-big-endian (sb-kernel:single-float-bits data) stream 4))
               ((equal (type-of data) 'double-float)
                (write-byte #xcb stream)
                (store-big-endian (sb-kernel:double-float-high-bits data) stream 4)
                (store-big-endian (sb-kernel:double-float-low-bits data) stream 4)))
         t)

(defun encode-float (data stream)
  (or #+sbcl (sbcl-encode-float data stream)
      (error "No floating point support yet.")))

(defun encode-each (data stream)
  (cond ((hash-table-p data)
         (with-hash-table-iterator (itr data)
           (multiple-value-bind (present key value) (itr)
             (when present
               (encode-implementation key stream)
               (encode-implementation value stream)))))
        ((or (vectorp data) (consp data))
         (mapc (lambda (subdata)
                 (encode-implementation subdata stream))
               (coerce data 'list)))
        (t (error "Not sequence or hash table."))))

(defun encode-sequence (data stream
                        short-prefix short-length
                        typecode-16 typecode-32)
  (let ((len (if (hash-table-p data)
                 (hash-table-count data)
                 (length data))))
    (cond ((<= 0 len short-length)
           (write-byte (+ short-prefix len) stream)
           (encode-each data stream))
          ((<= 0 len 65535)
           (write-byte typecode-16 stream)
           (store-big-endian len stream 2)
           (encode-each data stream))
          ((<= 0 len (1- (expt 2 32)))
           (write-byte typecode-32 stream)
           (store-big-endian len stream 4)
           (encode-each data stream)))))

(defun encode-hash (data stream)
  (encode-sequence data stream #x80 15 #xdc #xdd))

(defun encode-array (data stream)
  (encode-sequence data stream #x90 15 #xdc #xdd))

(defun encode-raw-bytes (data stream)
  (encode-sequence data stream #xa0 31 #xda #xdb))

(defun encode-integer (data stream)
  (cond ((<= 0 data 127) (write-byte data stream))
        ((<= -32 data -1) (write-byte (sb8->ub8 data) stream))
        ((<= 0 data 255)
         (write-byte #xcc stream)
         (write-byte data stream))
        ((<= 0 data 65535)
         (write-byte #xcd stream)
         (store-big-endian data stream 2))
        ((<= 0 data (1- (expt 2 32)))
         (write-byte #xce stream)
         (store-big-endian data stream 4))
        ((<= 0 data (1- (expt 2 64)))
         (write-byte #xcf stream)
         (store-big-endian data stream 8))
        ((<= -128 data 127)
         (write-byte #xd0 stream)
         (write-byte (sb8->ub8 data) stream))
        ((<= -32768 data 32767)
         (write-byte #xd1 stream)
         (write-byte (sb16->ub16 data) stream))
        ((<= (- (expt 2 31)) data (1- (expt 2 31)))
         (write-byte #xd2 stream)
         (write-byte (sb32->ub32 data) stream))
        ((<= (- (expt 2 63)) data (1- (expt 2 63)))
         (write-byte #xd3 stream)
         (write-byte (sb64->ub64 data) stream))
        (t (error "Integer too large or too small."))))

(defun store-big-endian (number stream byte-count)
  (let (byte-list)
    (loop
       while (> number 0)
       do
         (push (rem number 256)
               byte-list)
         (setf number (ash number -8)))
    (loop
       while (< (length byte-list) byte-count)
       do (push 0 byte-list))
    (when (> (length byte-list) byte-count)
      (error "Number too large."))
    (write-sequence byte-list stream)))