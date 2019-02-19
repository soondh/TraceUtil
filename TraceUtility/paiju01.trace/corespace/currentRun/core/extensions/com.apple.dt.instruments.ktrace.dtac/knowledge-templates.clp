(deftemplate thead 
    (slot tid (type INTEGER))
)
(deftemplate process 
    (slot pid (type INTEGER))
    (slot instance (type EXTERNAL-ADDRESS SYMBOL) (allowed-symbols sentinel) (default sentinel))
)
