#/bin/bash
#
# Copyright (c) 2021 Qualcomm Technologies, Inc.
# All Rights Reserved.
# Confidential and Proprietary - Qualcomm Technologies, Inc.
#
if [ ! $1 ]; then
   exit -1
fi

if [ "stop" = $1 ]; then
   setprop sys.perfetto.cmd ""
   exit 0
fi

# default max count is 24
maxCount=`getprop persist.sys.perfetto.max_trace_count 24`
output_path="/data/local/traces"

# delete perfetto log if reach to limit
if [ -d $output_path ]; then
   traceFiles=`ls -rt $output_path/perfetto.trace_*`
   if [ $? -eq 0 ]; then
      traceArray=(${traceFiles// / })
      if [ ${#traceArray[@]} -ge $maxCount ]; then
         # delete 1/10 file
         delCount=`expr ${#traceArray[@]} / 10`
         for i in `seq 0 $delCount`
             do
                 rm ${traceArray[i]}
             done
      fi
   fi
fi

if [ "start" = $1 ]; then
    perfetto  --txt --config /system_ext/etc/perfetto.cfg --out $output_path/perfetto.trace_$(date "+%Y-%m-%d-%H-%M-%S")
fi
