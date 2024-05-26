#!/system/bin/sh
# Copyright (c) 2022 Qualcomm Technologies, Inc.
# All Rights Reserved.
# Confidential and Proprietary - Qualcomm Technologies, Inc.
#

CLASSPATH=/system/system_ext/framework/ramdump_copy_daemon.jar
export CLASSPATH
exec app_process64 /system/bin --nice-name=ramdumpcopydaemon com.qualcomm.qti.ramdumpcopydaemon.RamdumpCopyDaemon \&