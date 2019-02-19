;;;
;;; Core location energy modeler
;;;

;; 
;; Templates
;;
(deftemplate location-manager 
    (slot identifier (type INTEGER))
)

(deftemplate location-manager-attribute
    (slot time (type INTEGER))
    (slot identifier (type INTEGER))
    (slot key (type SYMBOL))
    (slot value)
    (slot backtrace (type EXTERNAL-ADDRESS))
)

(deftemplate unrecorded-energy-impact
    (slot start-time (type INTEGER))
    (slot level (type SYMBOL) (allowed-symbols High Low None))
    (slot backtrace (type EXTERNAL-ADDRESS))
    (multislot cause-narrative)
)  

;; 
;; Manager Tracking Rules
;;

(defrule trace-manager-create "Detect creation of location manager"
    (energy-trace-msg (component kEnTrCompSpatial) (op-code kEnTrActSpStdLocation) (identifier ?ident)
                      (life-cycle BEGIN) (quality ?qual) (value ?val) (backtrace ?bt) (thread ?thread))
    (table-attribute (table-id ?table) (has schema cl-trace))
    (thread-instance (instance ?thread) (pid ?pid))
    (table-attribute (table-id ?table) (has target-pid ?pid|ALL))    
    (clock (trace-relative ?current-time))
    =>
    (create-new-row ?table)
    (set-column timestamp ?current-time)
    (set-column thread ?thread)
    (set-column backtrace ?bt)
    (set-column-narrative event "Created")
    (set-column manager ?ident)

    (assert (location-manager (identifier ?ident)))
)

(defrule trace-manager-destroy "Detect end of location manager"
    (energy-trace-msg (component kEnTrCompSpatial) (op-code kEnTrActSpStdLocation) (identifier ?ident)
                      (life-cycle END) (quality ?qual) (value ?val) (backtrace ?bt) (thread ?thread))
    (table-attribute (table-id ?table) (has schema cl-trace))
    (thread-instance (instance ?thread) (pid ?pid))
    (table-attribute (table-id ?table) (has target-pid ?pid|ALL))            
    (clock (trace-relative ?current-time))
    =>
    (create-new-row ?table)
    (set-column timestamp ?current-time)
    (set-column thread ?thread)
    (set-column backtrace ?bt)
    (set-column-narrative event "Released")
    (set-column manager ?ident)
)

(deffunction api-constant-from-val (?val) 
    (switch ?val (case -1 then "kCLLocationAccuracyBest") 
                                             (case -2 then "kCLLocationAccuracyBestForNavigation")
                                             (case 10 then "kCLLocationAccuracyNearestTenMeters")
                                             (case 100 then "kCLLocationAccuracyHundredMeters")
                                             (case 1000 then "kCLLocationAccuracyKilometer")
                                             (case 3000 then "kCLLocationAccuracyThreeKilometers")
                                             (default (str-cat ?val)))
)

(defrule trace-key-value-set "Detect a key/value set"
    (energy-trace-key-update (component kEnTrCompSpatial) (op-code kEnTrActSpStdLocation) (identifier ?ident)
                             (key kEnTrKeySpLocationAccuracy) (value ?val) 
                             (backtrace ?bt) (thread ?thread))
    (location-manager (identifier ?ident)) ;; we make sure we have a manager, because if we're not tracking it then we don't care
    (table-attribute (table-id ?table) (has schema cl-trace))
    (clock (trace-relative ?current-time))
    =>
    (assert (location-manager-attribute (time ?current-time) (identifier ?ident) (key kEnTrKeySpLocationAccuracy)
                                        (value ?val) (backtrace ?bt))) 

    (create-new-row ?table)
    (set-column timestamp ?current-time)
    (set-column thread ?thread)
    (set-column backtrace ?bt)
    (set-column-narrative event "Changing accuracy to %XRCoreLocationEventTypeID%" (api-constant-from-val ?val))
    (set-column manager ?ident)
)

(defrule trace-manager-destroy-cleanup "Clean up after location manager destruction"
    (declare (salience 100)) ;; high salience since this is a maintenance rule
    (energy-trace-msg (component kEnTrCompSpatial) (op-code kEnTrActSpStdLocation) (identifier ?ident)
                      (life-cycle END))
    ?f <- (location-manager (identifier ?ident))
    =>
    (retract ?f)
)

(defrule trace-manager-attribute-cleanup "Clean up after location manager destruction"
    (declare (salience 100)) ;; high salience since this is a maintenance rule
    ?f <- (location-manager-attribute (identifier ?ident))
    (not (location-manager (identifier ?ident)))
    =>
    (retract ?f)
)

(defrule remove-old-update "Removes an old attribute update"
    (declare (salience 100)) ;; high salience since this is a maintenance rule
    (location-manager-attribute (time ?t1) (identifier ?ident) (key ?key) (value ?new-val))
    ?old <- (location-manager-attribute (time ?t2&:(> ?t1 ?t2)) (identifier ?ident) (key ?key) (value ~?new-val))
    =>
    (retract ?old)
)

(defrule squash-redundant-update "Preserve the timestamp of the oldest unique update"
    (declare (salience 100)) ;; high salience since this is a maintenance rule
    ?redundant <- (location-manager-attribute (time ?t1) (identifier ?ident) (key ?key) (value ?val))
    (location-manager-attribute (time ?t2&:(> ?t1 ?t2)) (identifier ?ident) (key ?key) (value ?val))
    =>
    (retract ?redundant)
)


;; 
;; Energy Level Rules
;;

(deffunction energy-impact-from-accuracy (?accuracy) 
    (if (<= ?accuracy 10) then (return High) else (return Low))
)

(deffacts energy-level-initial-values
    (unrecorded-energy-impact (start-time 0) (level None) (cause-narrative "Initial assumption"))
)

(defrule log-highest-energy-state "Log the highest energy state"
    (table-attribute (table-id ?table) (has schema cl-energy-level))
    (location-manager-attribute (key kEnTrKeySpLocationAccuracy) (value ?val) (identifier ?ident) (backtrace ?new-bt))
    (not (location-manager-attribute (key kEnTrKeySpLocationAccuracy) (value ?val2&:(< ?val2 ?val))))
    ?f <- (unrecorded-energy-impact (start-time ?start-time) 
                                    (cause-narrative $?unrecorded-cause)
                                    (level ?unrecorded-level&:(neq ?unrecorded-level (energy-impact-from-accuracy ?val)))
                                    (backtrace ?bt))
    (clock (trace-relative ?now))
    =>
    (modify ?f (start-time ?now) (level (energy-impact-from-accuracy ?val))
               (cause-narrative "CLLocationManager<%XRRegisterContentsTypeID%> changed accuracy to %XRCoreLocationEventTypeID%"
                                ?ident (api-constant-from-val ?val))
               (backtrace ?new-bt))

    (create-new-row ?table) 
    (set-column start ?start-time)
    (set-column duration (- ?now ?start-time))
    (set-column impact ?unrecorded-level)
    (set-column-narrative cause (expand$ $?unrecorded-cause))
    (if (neq ?unrecorded-level None) then (set-column backtrace ?bt))
)

(defrule log-absense-of-energy 
    (table-attribute (table-id ?table) (has schema cl-energy-level))
    (not (location-manager-attribute (key kEnTrKeySpLocationAccuracy)))
    ?f <- (unrecorded-energy-impact (start-time ?start-time) (level ?level&~None) (cause-narrative $?unrecorded-cause) (backtrace ?bt))
    (clock (trace-relative ?now))
    =>
    (modify ?f (start-time ?now) (level None) (cause-narrative "All location managers were released"))

    (create-new-row ?table) 
    (set-column start ?start-time)
    (set-column duration (- ?now ?start-time))
    (set-column impact ?level)
    (set-column-narrative cause (expand$ $?unrecorded-cause))
    (set-column backtrace ?bt)
)

(defrule speculate-energy-impact
    (table-attribute (table-id ?table) (has schema cl-energy-level))
    (speculate (event-horizon ?horizon))
    (unrecorded-energy-impact (start-time ?start-time) (level ?level) (cause-narrative $?cause) (backtrace ?bt))
    =>
    (create-new-row ?table)

    (set-column start ?start-time)
    (set-column duration (- ?horizon ?start-time))
    (set-column impact ?level)
    (set-column-narrative cause (expand$ $?cause))
    (if (neq ?level None) then (set-column backtrace ?bt))
)

