#/bin/bash
#
# Copyright (c) 2021 Qualcomm Technologies, Inc.
# All Rights Reserved.
# Confidential and Proprietary - Qualcomm Technologies, Inc.
#
cmd=`getprop sys.smtrace.cmd`
cmdArray=(${cmd//:/ })
if [ ${#cmdArray[@]} != 2 ]; then
    exit 1
fi
file=${cmdArray[1]}

pids=${cmdArray[0]}
pidArray=(${pids//,/ })

if [ ${#pidArray[@]} -ge 2 ]; then
    anr_pid=${pidArray[0]}
    unset pidArray[0]
    for p in ${pidArray[@]}
        do
           debuggerd -b $p >> $file
        done
    setprop sys.smtrace.cmd ""
fi
