;;
;; Common KDEBUG code knowledge source
;;

;;
;; The syscall-name-map events connect the names of system calls with the codes
;; coming from the kernel.  We include rules here to remember that name mapping
;; and record it in the blackboard.
;;
(defrule remember-syscall-name "Remember the entries from the name mapping that pass by"
    (syscall-name-map (class ?class&4|1) (subclass 12) (code ?code) (name ?name))
    =>
    (assert (system-call-has-name (class ?class) (code ?code) (name ?name)))
)
(defrule name-unknown-syscalls "Name the unnamed, in case we never got the table"
    (kdebug (class ?class&4|1)
            (subclass 12)
            (code ?code&~368))
    (not (system-call-has-name (class ?class) (code ?code)))
    =>
    (assert (system-call-has-name (class ?class) (code ?code) (name (str-cat "unknown " ?code))))
)

;;
;; Core Profile callstack fix up
;;
;; Core Profile callstacks need a little bit of fix up with the help of Core Symbolication
;; and files that reside on the host.  When we detect a unique CP callstack, we fix
;; it up and remember it so that rules which need the true backtrace will have access
;; to it.
;;
(defrule fix-callstack "Fix observed raw CP callstacks"
    (or (kdebug (cp-user-callstack ?raw))
        (kdebug (cp-kernel-callstack ?raw))
        (time-sample (cp-user-callstack ?raw))
        (time-sample (cp-kernel-callstack ?raw))        
    )
    (not (fixed-cp-backtrace (cp-backtrace ?raw)))
    =>
    (assert (fixed-cp-backtrace (cp-backtrace ?raw) (backtrace (callstack-fixup-oracle ?raw))))
)

;;
;; Learn about threads
;;
(defrule learn-threads-by-obj "Detected a core-obj in kdebug that can confirm the mapping"
    (or (kdebug (thread ?thread-obj&~sentinel))   ;; we trust the tap has a legit pid/tid pair
        (time-sample (thread ?thread-obj&~sentinel))
    )
    (not (thread-instance (instance ?thread-obj)))
    =>
    (bind ?tid (tid-from-thread ?thread-obj))
    (bind ?proc-obj (process-from-thread ?thread-obj))
    (bind ?pid (pid-from-process ?proc-obj))
    (assert (thread-instance (tid ?tid) (pid ?pid) (instance ?thread-obj) (process ?proc-obj)))
    (assert (thread (tid ?tid)))
    (assert (process (pid ?pid) (instance ?proc-obj)))
)


;;;
;;; System call entry/exit decoding
;;;
;;; We track when a thread is running a system call, and when it has just finished
;;; a system call.  We'll leave the thread-finished-system-call facts around long enough
;;; for the modelers to see them, but they'll get removed when the next system
;;; call for that thread starts.
;;;
(defrule thread-started-syscall "Detected a system call started"
    (kdebug (class ?class&4|1)
            (subclass 12)
            (code ?code&~368)
            (function 1)
            (thread ?thread)
            (arg1 ?arg1)
            (arg2 ?arg2)
            (arg3 ?arg3)
            (arg4 ?arg4)
            (time ?t)
            (cp-user-callstack ?raw))
    (thread-instance (instance ?thread) (tid ?tid))
    (fixed-cp-backtrace (cp-backtrace ?raw) (backtrace ?backtrace))
    (system-call-has-name (class ?class) (code ?code) (name ?name))
    =>
    (assert (thread-running-system-call (start-time ?t) (tid ?tid) (name ?name) (args ?arg1 ?arg2 ?arg3 ?arg4) (backtrace ?backtrace)))
)
(defrule thread-finished-syscall "Detected the end of a system call"
    (logical (kdebug (class ?class&4|1)
            (subclass 12)
            (code ?code&~368)
            (function 2)
            (thread ?thread)
            (arg1 ?error)
            (arg2 ?return-lsb)
            (arg3 ?return-msb)
            (time ?t)
            (cp-user-callstack ?raw))
    )
    (thread-instance (instance ?thread) (tid ?tid))
    (system-call-has-name (class ?class) (code ?code) (name ?name))
    ?s <- (thread-running-system-call (start-time ?start-time) (tid ?tid) (name ?name) (args $?args))
    ; use either the start backtrace if that's available, or end backtrace if that's available
    (or (thread-running-system-call (tid ?tid) (name ?name) (backtrace ?backtrace&~sentinel))
        (and (thread-running-system-call (tid ?tid) (name ?name) (backtrace sentinel))
             (fixed-cp-backtrace (cp-backtrace ?raw) (backtrace ?backtrace))
        )
    )
    =>
    (retract ?s)
    (assert (thread-finished-system-call (start-time ?start-time)
                                        (duration (- ?t ?start-time))
                                        (end-time ?t)
                                        (tid ?tid)
                                        (args $?args)
                                        (name ?name)
                                        (return (make-int64 ?return-msb ?return-lsb))
                                        (error ?error)
                                        (backtrace ?backtrace)))
)

(defrule thread-terminated-in-syscall
    (logical (thread-terminated (tid ?tid)))
    ?s <- (thread-running-system-call (start-time ?start-time) (tid ?tid) (name ?name) (args $?args) (backtrace ?backtrace))    
    (system-call-has-name (class ?class) (code ?code) (name ?name))
    (clock (trace-relative ?t))
    =>
    (retract ?s)
    (assert (thread-finished-system-call (start-time ?start-time)
                                        (duration (- ?t ?start-time))
                                        (end-time ?t)
                                        (tid ?tid)
                                        (args $?args)
                                        (name ?name)
                                        (backtrace ?backtrace)))
)

(defrule thread-finished-call-unknown-start
    (logical (kdebug (class ?class&4|1)
            (subclass 12)
            (code ?code&~368)
            (function 2)
            (thread ?thread)
            (arg1 ?error)
            (arg2 ?return)
            (time ?t)
            (cp-user-callstack ?raw))
    )
    (system-call-has-name (class ?class) (code ?code) (name ?name))
    (thread-instance (instance ?thread) (tid ?tid))
    (not (thread-running-system-call (tid ?tid) (name ?name)))
    (not (thread-finished-system-call (tid ?tid) (end-time ?t)))  ;; don't double count
    (fixed-cp-backtrace (cp-backtrace ?raw) (backtrace ?backtrace))
    =>
    (assert (thread-finished-system-call (start-time ?t)
                                        (duration 0)
                                        (end-time ?t)
                                        (tid ?tid)
                                        (args 0 0 0 0)
                                        (name ?name)
                                        (return ?return)
                                        (error ?error)
                                        (backtrace ?backtrace)))
    (log-narrative "System call %XRSystemCallNameTypeID% ended on thread %XRThreadTypeID% but no start was traced." ?name ?thread)
)

;;
;; Make some basic annotations on the system call finish events
;;
(defrule note-missing-start
    (logical ?f <- (thread-finished-system-call (duration 0)))
    (not (finished-call-has-no-start (fact ?f)))
    =>
    (assert (finished-call-has-no-start (fact ?f)))
)

;;;
;;; Scheduler decoding
;;;
(deffunction is-preempt-reason (?reason) "Test if the scheduler reason code is a type of preemption"
    (or (bit-test ?reason 0) (bit-test ?reason 4))
)
(defrule preemption-detected
    (logical (kdebug (class 1) (subclass 64) (code 0|2) ;; MACH_SCHED or MACH_STACKHANDOFF
             (thread ?thread)
             (arg1 ?reason) (arg2 ?new-tid) (arg3 ?old-priority) (arg4 ?new-priority)
             (core-index ?cpu))
    )
    (thread-instance (instance ?thread) (tid ?old-tid&~?new-tid))
    (test (is-preempt-reason ?reason))  ;; AST_PREEMPT or AST_YIELD bit
    =>
    (assert (thread-preempted (tid ?old-tid) (cpu ?cpu) (priority ?old-priority) (winning-priority ?new-priority)
            (kind (if (bit-test ?reason 4) then yielded else forced)) (winning-tid ?new-tid)))
    (assert (thread-scheduled-on (tid ?new-tid) (cpu ?cpu) (priority ?new-priority)))
)
(defrule normal-schedule-on
    (logical (kdebug (class 1) (subclass 64) (code 0|2) ;; MACH_SCHED or MACH_STACKHANDOFF
             (thread ?thread)
             (arg1 ?reason) (arg2 ?new-tid) (arg3 ?old-priority) (arg4 ?new-priority)
             (core-index ?cpu))
    )
    (thread-instance (instance ?thread) (tid ?old-tid&~?new-tid))
    (test (not (is-preempt-reason ?reason)) )  ;; AST_PREEMPT bit and AST_YIELD are clear
    =>
    (assert (thread-scheduled-on (tid ?new-tid) (cpu ?cpu) (priority ?new-priority)))
)

(defrule thread-thottled
    (logical (kdebug (class 1) (subclass 64) (code 0|2) ;; MACH_SCHED or MACH_STACKHANDOFF
             (thread ?thread)
             (arg1 ?reason) (arg2 ?tid) (arg3 ?old-priority) (arg4 ?new-priority)
             (core-index ?cpu))
    )
    (test (bit-test ?reason 6)) ;; AST_LEDGER bit
    =>
    (assert (thread-priority-change (tid ?tid) (old-priority ?old-priority) (new-priority ?new-priority)))
)
(defrule thread-block-detected
    (logical (kdebug (class 1) (subclass 64) (code 15)  ;; MACH_BLOCKED
             (thread ?thread)
             (core-index ?cpu))
    )
    (thread-instance (instance ?thread) (tid ?tid))
    =>
    (assert (thread-blocked (tid ?tid) (cpu ?cpu) (kind explicit)))
)
(defrule thread-made-runnable-detected
    (logical (kdebug (class 1) (subclass 64) (code 6)  ;; MACH_MAKE_RUNNABLE
             (arg1 ?tid)
             (arg2 ?priority)
             (arg3 ?wait-result)
             (arg4 ?new-run-count) (thread ?thread) (core-index ?cpu))
    )
    =>
    (assert (thread-made-runnable (tid ?tid) (priority ?priority) (wait-result ?wait-result) 
                                  (new-run-count ?new-run-count) (from-thread ?thread) (from-cpu ?cpu)))
)

;; If a CPU idles, then the thread running on it must have blocked
(defrule thread-was-on-an-idled-CPU
    (logical (kdebug (class 1) (subclass 64) (code 9) (function 1) ;; MACH_IDLE (start)
             (arg1 ?tid&~0)
             (core-index ?cpu))
    )
    =>
    (assert (thread-blocked (tid ?tid) (cpu ?cpu) (kind by-idle)))
    (assert (cpu-idled (cpu ?cpu) (tid ?tid)))    
)

;; Sometimes the CPU going into idle, for kernel threads, does not contain a thread in arg1
(defrule thread-was-on-an-idled-CPU-inferred
    (logical (kdebug (class 1) (subclass 64) (code 9) (function 1) ;; MACH_IDLE (start)
             (arg1 0)
             (core-index ?cpu) (thread ?thread))
             
    )
    (thread-instance (instance ?thread) (tid ?tid))
    =>
    (assert (thread-blocked (tid ?tid) (cpu ?cpu) (kind inferred)))
    (assert (cpu-idled (cpu ?cpu) (tid ?tid)))
)

;; Special wait kdebug event
(defrule thread-wait-detected
    (logical (kdebug (class 1) (subclass 64) (code 16)  ;; MACH_WAIT
             (arg1 ?event) (arg2 ?interruptible) (arg3 ?deadline)
             (thread ?thread)
             (core-index ?cpu))
    )
    (thread-instance (instance ?thread) (tid ?tid))
    =>
    (assert (thread-wait (tid ?tid) (cpu ?cpu) (event ?event)
                         (interruptible (switch ?interruptible (case 0 then uninterruptible) (case 1 then interruptible) (case 2 then abort-safe))))
    )
)
;; For CPU waking events, we ignore them if they've chosen a different thread
;; because we get a subsequent stack hand off event
(defrule thread-chosen-for-waking-cpu
    (logical (kdebug (class 1) (subclass 64) (code 9) (function 2) ;; MACH_IDLE (end)
             (arg1 ?tid&~0) (arg3 0|?tid)
             (core-index ?cpu))
    )
    =>
    (assert (thread-scheduled-on (tid ?tid) (cpu ?cpu)))
    (assert (cpu-wake (cpu ?cpu) (tid ?tid)))
)

;;; 
;;; CPU/interrupt modeling
;;;
(defrule cpu-running-interrupt-handler
    (kdebug (time ?time) (class 1) (subclass 0x5) (code 0) (function 1) (core-index ?cpu))
    =>
    (assert (cpu-handling-interrupt (cpu ?cpu) (start-time ?time)))
)

(defrule cpu-finished-interrupt-handler
    (kdebug (class 1) (subclass 0x5) (code 0) (function 2) (core-index ?cpu))
    ?f <- (cpu-handling-interrupt (cpu ?cpu))
    =>
    (retract ?f)
)

(defrule cpu-running-a-timer-callout
    (kdebug (time ?time) (class 1) (subclass 0x9) (code 2) (function 1) (core-index ?cpu))
    =>
    (assert (cpu-handling-timer-callout (cpu ?cpu) (start-time ?time)))
)

(defrule cpu-finished-a-timer-callout
    (kdebug (time ?time) (class 1) (subclass 0x9) (code 2) (function 2) (core-index ?cpu))
    ?f <- (cpu-handling-timer-callout (cpu ?cpu))
    =>
    (retract ?f)
)
   
;;;
;;; BSD process lifecycle events
;;;
(defrule process-creation
    (logical (kdebug (class 7) (subclass 0) (code 2) (arg1 ?pid) (arg2 ?main-tid) (arg3 ?ppid)))
    =>
    (assert (process-created (pid ?pid) (ppid ?ppid) (main-tid ?main-tid)))
)

(defrule process-terminating
    (logical (kdebug (class 4) (subclass 1) (code ?exit-kind&1|2) (function 2) ;; BSD_PROC_EXIT or BSD_PROC_FRCEXIT
             (arg1 ?pid))
    )
    =>
    (assert (process-terminating (pid ?pid)))
)

(defrule thread-creation 
    (logical (kdebug (class 7) (subclass 0) (code 1) (arg1 ?tid) (arg2 ?pid) (thread ?creator)))
    =>
    (assert (thread-created (tid ?tid) (pid ?pid) (created-by-thread ?creator)))
)

(defrule thread-terminated
    (logical (kdebug (class 7) (subclass 0) (code 3) (arg1 ?tid)))
    =>
    (assert (thread-terminated (tid ?tid)))
)

;;;
;;; Virtual memory kdebug decoding
;;;
(defrule thread-in-vm-fault
    (kdebug (class 1)
            (subclass 48)  ;; DBG_MACH_VM
            (code 1|2)       ;; fault (like a page-in or protection fault)
            (function 1)   ;; fault started
            (thread ?thread)
            (time ?t)
            (cp-user-callstack ?raw))
    (fixed-cp-backtrace (cp-backtrace ?raw) (backtrace ?backtrace))
    (thread-instance (instance ?thread) (tid ?tid))
    =>
    (assert (thread-in-vm-fault (start-time ?t)
                                (tid ?tid)
                                (backtrace ?backtrace)))
)
(defrule thread-finished-fault
    (logical (kdebug (class 1)
            (subclass 48)  ;; DBG_MACH_VM
            (code 2)       ;; fault (like a page-in or protection fault)
            (function 2)   ;; fault completed
            (thread ?thread)
            (arg1 ?high32)
            (arg2 ?full64-or-low32)
            (arg3 ?kern-return)
            (arg4 ?kind)
            (time ?t))
    )
    ?f <- (thread-in-vm-fault (start-time ?start-time) (tid ?tid) (backtrace ?backtrace))
    (not (thread-completed-vm-fault (tid ?tid) (start-time ?start-time)))
    (thread-instance (instance ?thread) (tid ?tid))
    =>
    (retract ?f)
    (assert (thread-completed-vm-fault (start-time ?start-time)
                (duration (- ?t ?start-time))
                (tid ?tid)
                (address (make-int64 ?high32 ?full64-or-low32)) ;; make-int64 does cast its args before concatenating 
                (operation (switch ?kind (case 1 then "Zero Fill") 
                                         (case 2 then "Page In") 
                                         (case 3 then "Copy On Write") 
                                         (case 4 then "Page Cache Hit") 
                                         (case 5 then "Non-Zero Fill") 
                                         (case 6 then "Guard Page") 
                                         (case 7 then "File Backed Page In") 
                                         (case 8 then "Anonymous Memory Page In") 
                                         (case 9 then "Decompress Memory") 
                                         (case 10 then "Decompress Memory from Swap") 
                                         (default "Unknown")))
                (kern-return ?kern-return)
                (backtrace ?backtrace)
            )
    )
)

(defrule thread-finished-page-out
    (logical (kdebug (class 1)
            (subclass 48)  ;; DBG_MACH_VM
            (code 1)       ;; page out code
            (function 2)   ;; fault completed
            (thread ?thread)
            (arg1 ?size)
            (time ?t))
    )
    ?f <- (thread-in-vm-fault (start-time ?start-time) (tid ?tid) (backtrace ?backtrace))
    (not (thread-completed-vm-fault (tid ?tid) (start-time ?start-time)))
    (thread-instance (instance ?thread) (tid ?tid))
    =>
    (retract ?f)
    (assert (thread-completed-vm-fault (start-time ?start-time)
                (duration (- ?t ?start-time))
                (tid ?tid)
                (operation "Page Out")
                (size ?size)
                (backtrace ?backtrace)
            )
    )
)


;;;
;;; Energy tracing kdebug decoding
;;;
(defrule energy-trace-msg-decode "Basic energy trace decoding"
    (logical (kdebug (class 45) (subclass ?component) (code ?op-code) 
                     (function ?func) (thread ?thread) (cp-user-callstack ?raw-bt)
                     (arg1 ?ident) (arg2 ?quality) (arg3 ?value-high) (arg4 ?value-low)))
    (fixed-cp-backtrace (cp-backtrace ?raw-bt) (backtrace ?bt))                     
    (energy-trace-component (code ?component) (symbol ?component-symbol))
    (energy-trace-op-code (component ?component-symbol) (code ?op-code) (symbol ?op-code-symbol))
    =>
    (assert (energy-trace-msg (component ?component-symbol) (op-code ?op-code-symbol) (identifier ?ident)
                              (life-cycle (switch ?func (case 1 then BEGIN) (case 2 then END) (case 0 then MODIFY)))
                              (quality ?quality) (value (make-int64 ?value-high ?value-low))
                              (backtrace ?bt) (thread ?thread)))
)

(defrule energy-key-value-set-decode "Energy tracing SPI received a key-value set"
    (logical (energy-trace-msg (component ?component) (op-code ?opcode) (identifier ?ident) (life-cycle MODIFY)
                               (quality ?qual) (value ?val) (backtrace ?bt) (thread ?thread)))
    (test (bits-eq ?qual 31 28 2)) ;; if the value "3" is stored in the upper most 4 bits, then it's a "set"
    (energy-trace-key (component ?component) (op-code ?opcode) (code ?code&:(bits-eq ?qual 27 0 ?code)) (key ?key))
    =>
    (assert (energy-trace-key-update (component ?component) (op-code ?opcode) (identifier ?ident) 
                                     (key ?key) (value ?val) (backtrace ?bt) (thread ?thread)))
)

;;;
;;; Tracking of kdebug strings
;;;
(defrule kdebug-string-addition "A kdebug string is being created"
    (kdebug-strings (raw-string ?raw-string&~"") (raw-string-id ?raw-string-id))
    (not (kdebug-uuid-string (identifier ?raw-string-id)))
    =>
    (assert (kdebug-uuid-string (identifier ?raw-string-id) (value ?raw-string)))
)

(defrule kdebug-string-removal "A kdebug string is being removed"
    (kdebug-strings (raw-string "") (raw-string-id ?raw-string-id))
    ?f <- (kdebug-uuid-string (identifier ?raw-string-id))
    =>
    (retract ?f)
)

(defrule kdebug-string-modification "A kdebug string is being modified"
    (kdebug-strings (raw-string ?raw-string&~"") (raw-string-id ?raw-string-id))
    ?f <- (kdebug-uuid-string (identifier ?raw-string-id) (value ~?raw-string))
    =>
    (modify ?f (value ?raw-string))
)

;;;
;;; DBG_MACH_RESOURCE (resource constraint violations)
;;;
(defrule cpu-usage-violation-k64
    (logical (kdebug (time ?time) (class 1) (subclass 0x25) (code 0x2) (function 0) (thread ?thread) (arg1 ?balance) (arg2 ?last-refill) 
                     (arg3 ?limit) (arg4 ?refill-period)))
    =>
    (bind ?synthetic-start (- ?time ?refill-period))
    (if (< ?synthetic-start 0) then (bind ?synthetic-start 0))
    (assert (cpu-usage-violation (start ?synthetic-start) (end ?time) (thread ?thread)
                                 (balance ?balance) (last-refill ?last-refill)
                                 (limit ?limit) (refill-period ?refill-period)))
)

(defrule cpu-usage-violation-k32-a
    (kdebug (time ?time) (class 1) (subclass 0x25) (code 0x4) (function 0) (thread ?thread) (arg1 ?balance-high) (arg2 ?balance-low) 
            (arg3 ?last-refill-high) (arg4 ?last-refill-low))
    =>
    (assert (cpu-usage-violation-32-a (time ?time) (thread ?thread) (balance (make-int64 ?balance-high ?balance-low))
                                      (last-refill (make-int64 ?last-refill-high ?last-refill-low))))
)

(defrule cpu-usage-violation-k32-b "we have part 2 of 2, so create the cpu-usage-violation fact"
    (logical (kdebug (time ?time) (class 1) (subclass 0x25) (code 0x5) (function 0) (thread ?thread) (arg1 ?limit-high) (arg2 ?limit-low) 
             (arg3 ?refill-period-high) (arg4 ?refill-period-low)))
    ?f <- (cpu-usage-violation-32-a (thread ?thread?) (balance ?balance) (last-refill ?last-refill))
    =>
    (retract ?f)
    (bind ?refill-period (make-int64 ?refill-period-high ?refill-period-low))
    (bind ?synthetic-start (- ?time ?refill-period))
    (if (< ?synthetic-start 0) then (bind ?synthetic-start 0))
    (assert (cpu-usage-violation (start ?synthetic-start) (end ?time) (thread ?thread) (balance ?balance) (last-refill ?last-refill) 
                                 (limit (make-int64 ?limit-high ?limit-low)) (refill-period ?refill-period)))
)

(defrule cpu-usage-violation-k32-recover   "if we have 2 type-a records on the same thread, then retract the older one"
    (cpu-usage-violation-32-a (thread ?thread) (time ?t))
    ?f <- (cpu-usage-violation-32-a (thread ?thread) (time ?t2&:(> ?t ?t2)))
    =>
    (retract ?f)
)
