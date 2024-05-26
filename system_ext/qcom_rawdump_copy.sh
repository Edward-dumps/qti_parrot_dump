#!/system/bin/sh
# Copyright (c) 2019, The Linux Foundation. All rights reserved.
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions are
# met:
#     * Redistributions of source code must retain the above copyright
#       notice, this list of conditions and the following disclaimer.
#     * Redistributions in binary form must reproduce the above
#       copyright notice, this list of conditions and the following
#       disclaimer in the documentation and/or other materials provided
#       with the distribution.
#     * Neither the name of The Linux Foundation nor the names of its
#       contributors may be used to endorse or promote products derived
#      from this software without specific prior written permission.
#
# THIS SOFTWARE IS PROVIDED "AS IS" AND ANY EXPRESS OR IMPLIED
# WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF
# MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NON-INFRINGEMENT
# ARE DISCLAIMED.  IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS
# BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
# CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
# SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR
# BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY,
# WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE
# OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN
# IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
#
#

#
#   Usage: $0 -o TARGET_PATH -f (c|m)
#   -o: Output target folder
#   -f: File type, c: combined file; m: multiple files
#
#   Limitation:
#   Only support section size <= 4GB
#

DEBUG_FLAG=FALSE

#Free space after copy (MB)
MINIMAL_FREE_SPACE=500

#4KB block size for dd comand to copy data
BLOCK_SIZE=4096

#Shell command od showed byte per line
OD_BPL=16

#Shell command od valid data offset per line
OD_OFFSET=2

#Source partition
DUMP_PARTITION="/dev/block/by-name/rawdump"

#Do NOT Support HEX
#Unit: Byte
#Primary Header
VALIDATION_BIT_OFFSET=12
VALIDATION_BIT_LENGTH=4
VALIDATION_BIT=1

DUMP_SIZE_OFFSET=36
DUMP_SIZE_LENGTH=8

REQUEST_SIZE_OFFSET=44
REQUEST_SIZE_LENGTH=8

SECTION_CNT_OFFSET=52
SECTION_CNT_LENGTH=4

FRIST_STRING_SIZE=8

PRI_HEADER_SIZE=56

#Secondary Header
SEC_HEADER_OFFSET=56
SEC_HEADER_SIZE=64

SECTION_VALID_OFFSET=0
SECTION_VALID_LENGTH=4
SECTION_VALID_BIT=2

SECTION_OFF_OFFSET=12
SECTION_OFF_LENGTH=8

SECTION_SIZE_OFFSET=20
SECTION_SIZE_LENGTH=8

SECTION_NAME_OFFSET=44
SECTION_NAME_LENGTH=20

#Protocol aligned with daemon Constants
FROM_SERVER=100
CMD_COPY_TYPE=0
CMD_VALIDATED=1
CMD_TOTAL_SIZE=2
CMD_TOTAL_COUNT=3
CMD_COPY_UPDATE=4
CMD_COPY_FINISHED=5
TYPE_COMBINED=0
TYPE_MULTIPLE=1
STATUS_COPYING=1
STATUS_DONE=2
STATUS_OK=1
EIO=-5
EAGAIN=-11
ENOREADY=-21
EINVAL=-22
ENOSPC=-28
EROFS=-30

#Magic code
DUMP_STRING="Raw_Dmp!"
COPIED_STRING="CopyDone"

usage ()
{
    echo "==============================="
    echo "Usage: $0 -o TARGET_PATH -f (c|m)"
    echo "-o: Output target folder"
    echo "-f: File type, c: combined file; m: multiple files"
    echo "==============================="
}


if [[ $1 = "-h" || $1 = "--help" ]]; then
    usage
    exit 0
fi

if [[ $# -lt 4 ]]; then
    echo "Error: please check your arguments"
    usage
    exit $EINVAL
fi

while [[ "$1" ]]; do
    case "$1" in
        -h|--help)
            usage
            exit 0
            ;;
        -o|--output)
            if [[ ! -d $2 ]]; then
                mkdir -p $2
                if [[ $? -ne "0" ]]; then
                    echo "Target folder cannot be created"
                    exit 20
                fi
            fi
            if [[ ! -w $2 ]]; then
               echo "Target folder is Read-Only"
               exit $EROFS
            fi
            TARGET_FOLDER=$2
            TARGET_TMP_FOLDER="$2/tmp"
            mkdir -p $TARGET_TMP_FOLDER
            echo Target_folder:$TARGET_FOLDER
            ;;
        -f|--file)
            if [[ $2 != "c" && $2 != "m" ]]; then
                echo "Error:please check your file type"
                usage
                exit $EINVAL
            elif [[ $2 = "c" ]]; then
                FILE_TYPE=combined
                echo $FROM_SERVER:$CMD_COPY_TYPE:$TYPE_COMBINED
            elif [[ $2 = "m" ]]; then
                FILE_TYPE=multiple
                echo $FROM_SERVER:$CMD_COPY_TYPE:$TYPE_MULTIPLE
            fi
            echo "File type is $FILE_TYPE file(s)"
            ;;
        *)
            echo "Do not support the opcode"
            usage
            exit $EINVAL
            ;;
    esac
    shift 2
done

# ready_byte $file $offset
# use od to read one line, then cut the byte which want
byte_read_ascii()
{
    line_offset=$(($2%$OD_BPL+$OD_OFFSET))
    jump_offset=$(($2/$OD_BPL*$OD_BPL))
    od -j $jump_offset -cN $OD_BPL $1 | awk 'NR==1 {print $'$line_offset'}'
}

byte_read_raw()
{
    line_offset=$(($2%$OD_BPL+$OD_OFFSET))
    jump_offset=$(($2/$OD_BPL*$OD_BPL))
    od -j $jump_offset -N $OD_BPL $1 -t x1 | awk 'NR==1 {print $'$line_offset'}'
}

dbyte_read_raw()
{
    line_offset=$(($2%$OD_BPL+$OD_OFFSET))
    line_offset=$(($line_offset/2+1))
    jump_offset=$(($2/$OD_BPL*$OD_BPL))
    od -j $jump_offset -N $OD_BPL $1 -t x2 | awk 'NR==1 {print $'$line_offset'}'
}

dump_dd()
{
    dd $* 1>/dev/null 2>&1
    if [[ "$?" -ne 0 ]]; then
        echo "$FROM_SERVER:$CMD_COPY_FINISHED:$EIO:$?"
        exit $EIO
    fi
}

#read_raw $file $offset $width
read_raw()
{
    od -j $2 -N $OD_BPL $1 -t x$3 | awk 'NR==1 {print $'$OD_OFFSET'}'
}

#Do not support in Android od
read_string()
{
    od -j $2 -S 8 $1 | awk 'NR==1 {print $'$OD_OFFSET'}'
}

#Attention:
#Current Android Shell base function, like echo/printf/dd and compare,
#They treat numbers as signed, and do not support > 32bit numbers.
#eg. 0xFFFFFFFF is -1, 0x100000000 is 0.
#So here need unsigned hex2dec
unsigned_hex2dec()
{
    a=$1
    if [[ $((0x$a)) -lt 0 ]];then
        #signed number
        if [[ ${a:0:$((${#a}-8))} -gt 0 ]]; then
            #more than 32bit
            a_h=$(expr ${a:0:$((${#a}-8))} \* 4294967296)
            a_l=$(expr 4294967296 + $((0x$1)))
            echo $(expr $a_h + $a_l)
        else
            #add 0x100000000 to turn signed to unsigned
            echo $(expr 4294967296 + $((0x$a)))
        fi
    else
        #unsigned number
        if [[ ${a:0:$((${#a}-8))} -ne 0 ]] ; then
            #high 32bit != 0, more than 32bit
            a_h=$(expr ${a:0:$((${#a}-8))} \* 4294967296)
            a_l=$((16#${a:0-8}))
            echo $(expr $a_h + $a_l)
        else
            echo $((16#$a))
        fi
    fi
}

#validate $header.img
validate()
{
    #Check validation bit
    validation_byte=$(($(byte_read_raw "$1" "$VALIDATION_BIT_OFFSET")&$VALIDATION_BIT))
    for i in $(seq 1 $FRIST_STRING_SIZE)
    do
        a="$(byte_read_ascii "$1" "$(($i-1))")"
        if [[ $a = "\0" ]];then
            break
        fi
        first_string=$first_string$a
    done
    if [[ "$VALIDATION_BIT" = "$validation_byte" ]]; then
        echo $FROM_SERVER:$CMD_VALIDATED:$STATUS_OK
    elif [[ "$validation_byte" = "0" && "$first_string" = "$COPIED_STRING" ]]; then
        echo $FROM_SERVER:$CMD_VALIDATED:$EAGAIN
        exit $EAGAIN
    elif [[ "$validation_byte" = "0" && "$first_string" = "$DUMP_STRING" ]]; then
        #Clean the first string to avoid report invalid dump again
        dump_dd if=/dev/zero of=$DUMP_PARTITION bs=$BLOCK_SIZE count=1
        echo $FROM_SERVER:$CMD_VALIDATED:$EINVAL
        exit $EINVAL
    else
        #Return with No notification
        echo $FROM_SERVER:$CMD_VALIDATED:$EAGAIN
        exit $EAGAIN
    fi
}

#get_section_name $ascii_file $section_cnt
#   0000144   O   C   I   M   E   M   .   B   I   N  \0  \0  \0  \0  \0  \0
#   0000164  \0  \0  \0  \0 001  \0  \0  \0  \0 020  \0  \0 003  \0  \0  \0
#   0000204   x  \v 004  \0  \0  \0  \0  \0  \0 200 001  \0  \0  \0  \0  \0
#   0000224  \0  \0  \0  \v  \0  \0  \0  \0  \0  \0  \0  \0  \0  \0  \0  \0
#   0000244   C   O   D   E   R   A   M   .   B   I   N  \0  \0  \0  \0  \0
#   0000264  \0  \0  \0  \0 001  \0  \0  \0  \0 020  \0  \0 003  \0  \0  \0
#   0000304   x 213 005  \0  \0  \0  \0  \0  \0 200  \0  \0  \0  \0  \0  \0
#   0000324  \0  \0 016  \v  \0  \0  \0  \0  \0  \0  \0  \0  \0  \0  \0  \0
#
get_section_name()
{
    jump_line=$(($SEC_HEADER_SIZE*($2-1)/$OD_BPL+1))
    offset_per_line=$(($SEC_HEADER_SIZE*($2-1)%$OD_BPL+$OD_OFFSET))
    line_end=0
    for i in $(seq 1 $SECTION_NAME_LENGTH)
    do
        line_end=$((line_end+1))
        if [[ $line_end -gt $OD_BPL ]]; then
            jump_line=$(($jump_line+1))
            offset_per_line=$OD_OFFSET
            line_end=0
        fi
        a=$(awk 'NR=='$jump_line' {print $'$offset_per_line'}' $1)
        offset_per_line=$(($offset_per_line+1))
        if [[ $a = "\0" ]];then
            break
        fi
        b=$b$a
    done
    echo $b
}

#Clean success flag
rm -rf $TARGET_FOLDER/completed

#Copy header
dump_dd if=$DUMP_PARTITION of=$TARGET_FOLDER/header.img bs=4096 count=10

#Do validation
validate $TARGET_FOLDER/header.img

# Use the UUID to distinguish the crash, whatever the copy succeed or not.
cp /proc/sys/kernel/random/uuid $TARGET_FOLDER

#dump_size is a hex data read from header
dump_size=$(unsigned_hex2dec $(read_raw "$TARGET_FOLDER/header.img" "$DUMP_SIZE_OFFSET" "$DUMP_SIZE_LENGTH"))

#Current free space, initial value read from "df" is KB.
#Turn it to MB to avoid negative number shell treat if Bit31 is 1.
#It is safe for data parition less than 2TB.
curr_free_space=$(df | grep -w " /data" | awk '{print $4}')
if [[ $curr_free_space ]]; then
    curr_free_space=$(expr $curr_free_space / 1024)
    if [[ $(expr $curr_free_space - $(expr $(expr $dump_size / 1024) / 1024)) -lt $MINIMAL_FREE_SPACE ]]; then
        echo $FROM_SERVER:$CMD_TOTAL_SIZE:$ENOSPC
        exit $ENOSPC
    else
        echo $FROM_SERVER:$CMD_TOTAL_SIZE:$dump_size:Byte
    fi
else
    echo $FROM_SERVER:$CMD_TOTAL_SIZE:$ENOSPC
    exit $ENOSPC
fi

#Check whether it is minidump
#Set /sys/kernel/dload/dload_mode to mini will be reset to full after dump.
#So use the dump size as a judgement, < 256MB(268435456Byte)
if [[ $(expr $(expr $dump_size / 1024) / 1024) -lt 256 ]]; then
    FILE_TYPE="combined"
    combined_file="sbldump.bin"
else
    combined_file="rawdump.img"
fi

if [[ "$FILE_TYPE" = "combined" ]]; then
    #dump_cnt is the count for pages - 4KB
    dump_cnt=$(expr $dump_size / $BLOCK_SIZE)

    #dump_cnt + 1 to get dump tail
    dump_cnt=$(expr $dump_cnt + 1)

    echo "Source: $DUMP_PARTITION, Target: $TARGET_FOLDER/$combined_file, count=$dump_cnt, bs=$BLOCK_SIZE"
    dump_dd if=$DUMP_PARTITION of=$TARGET_FOLDER/$combined_file bs=$BLOCK_SIZE count=$dump_cnt
elif [[ "$FILE_TYPE" = "multiple" ]]; then
    section_cnt=$((16#$(read_raw "$TARGET_FOLDER/header.img" "$SECTION_CNT_OFFSET" "$SECTION_CNT_LENGTH")))
    echo $FROM_SERVER:$CMD_TOTAL_COUNT:$section_cnt

    #Previous design is using od to read section name each time.
    #But that need run od too many times and cost more time.
    #Now turn header.img to ascii file then use awk to parse.
    ascii_header_size=$(($SEC_HEADER_SIZE*$section_cnt))

    #Create ascii header file
    od -j $(($PRI_HEADER_SIZE+$SECTION_NAME_OFFSET)) -cN $ascii_header_size $TARGET_FOLDER/header.img > $TARGET_TMP_FOLDER/ascii_header

    #Initial the offset to a invalid value, here is 0xFFFFFFFF
    previous_section_block_offset=4294967295

    for i in $(seq 1 $section_cnt)
    do
        curr_section=$i
        section_offset=$(unsigned_hex2dec $(read_raw "$TARGET_FOLDER/header.img" "$(($SEC_HEADER_OFFSET+$SEC_HEADER_SIZE*$(($curr_section-1))+$SECTION_OFF_OFFSET))" "$SECTION_OFF_LENGTH"))
        section_size=$(unsigned_hex2dec $(read_raw "$TARGET_FOLDER/header.img" "$(($SEC_HEADER_OFFSET+$SEC_HEADER_SIZE*$(($curr_section-1))+$SECTION_SIZE_OFFSET))" "$SECTION_SIZE_LENGTH"))
        section_name=$(get_section_name "$TARGET_TMP_FOLDER/ascii_header" "$curr_section")
        echo $FROM_SERVER:$CMD_COPY_UPDATE:$curr_section:$section_name:$section_size:$STATUS_COPYING:$section_offset

        if [[ "$section_size" -gt "$BLOCK_SIZE" ||  "$section_size" -lt 0 ]]; then
            #dd is faster at 4KB copy, split the file to head/body/tail.
            #one for 4KB copy, others use 1 byte copy.
            #Then combine them together to speed up.
            if [[ $(expr $section_offset % $BLOCK_SIZE) -eq 0 ]]; then
                #section offset has already been 4KB aligned.
                if [[ $(expr $section_size % $BLOCK_SIZE) -eq 0 ]]; then
                    #section size also has been 4KB aligned, only need one file.
                    dump_dd if=$DUMP_PARTITION of=$TARGET_FOLDER/$section_name bs=$BLOCK_SIZE count=$(expr $section_offset / $BLOCK_SIZE) skip=$(expr $section_size / $BLOCK_SIZE)
                else
                    #need 2 files, head for 4KB copy, tail for 1 byte copy
                    dump_dd if=$DUMP_PARTITION of=$TARGET_TMP_FOLDER/head bs=$BLOCK_SIZE count=$(expr $section_offset / $BLOCK_SIZE) skip=$(expr $section_size / $BLOCK_SIZE)

                    tail_block_end=$(expr $section_offset + $section_size)
                    tail_block_offset=$(expr $tail_block_end / $BLOCK_SIZE)
                    dump_dd if=$DUMP_PARTITION of=$TARGET_TMP_FOLDER/tail_one_block bs=$BLOCK_SIZE count=1 skip=$tail_block_offset
                    tail_size=$(expr $tail_block_end % $BLOCK_SIZE)
                    dump_dd if=$TARGET_TMP_FOLDER/tail_one_block of=$TARGET_TMP_FOLDER/tail bs=1 count=$tail_size

                    cat $TARGET_TMP_FOLDER/tail>>$TARGET_TMP_FOLDER/head
                    mv $TARGET_TMP_FOLDER/head $TARGET_FOLDER/$section_name
                fi
            else
                #section is big and not 4KB aligned, need to do copy and combine
                if [[ $section_offset -lt 0 || $section_offset -gt $BLOCK_SIZE ]]; then
                    #if section_offset is more than block size(4KB), here is a way to speed up the copy
                    #current UFS driver can do auto 4KB alignment in the copy
                    #so "dd" skips the section offset will get the front of the file.
                    #then files combine will only need copy a small file to tail which could save time.
                    #fine graind the section offset for "dd" block size
                    dd_skip=1
                    for m in $(seq 1 $(expr $SECTION_OFF_LENGTH \* 8))
                    do
                        if [[ $(expr $section_offset % 2) -eq 0 ]]; then
                            #section_offset is not the real offset now
                            section_offset=$(expr $section_offset / 2)
                            dd_skip=$(expr $dd_skip \* 2)
                        else
                            break
                        fi
                    done
                    dd_count=$(expr $section_size / $section_offset)


                    dump_dd if=$DUMP_PARTITION of=$TARGET_FOLDER/$section_name bs=$section_offset count=$dd_count skip=$dd_skip
                    dd_left_offset=$(expr $(expr $dd_skip + $dd_count) \* $section_offset)
                    dd_left_size=$(expr $section_size % $section_offset)

                    if [[ $dd_left_size -lt 0 || $dd_left_size -gt $BLOCK_SIZE ]]; then
                        head_block_offset=$(expr $dd_left_offset / $BLOCK_SIZE)
                        dump_dd if=$DUMP_PARTITION of=$TARGET_TMP_FOLDER/head_one_block bs=$BLOCK_SIZE count=1 skip=$head_block_offset
                        head_one_block_offset=$(expr $dd_left_offset % $BLOCK_SIZE)
                        head_size=$(expr $BLOCK_SIZE - $head_one_block_offset)
                        dump_dd if=$TARGET_TMP_FOLDER/head_one_block of=$TARGET_TMP_FOLDER/head bs=1 count=$head_size skip=$head_one_block_offset

                        tail_block_end=$(expr $dd_left_offset + $dd_left_size)
                        tail_block_offset=$(expr $tail_block_end / $BLOCK_SIZE)
                        dump_dd if=$DUMP_PARTITION of=$TARGET_TMP_FOLDER/tail_one_block bs=$BLOCK_SIZE count=1 skip=$tail_block_offset
                        tail_size=$(expr $tail_block_end % $BLOCK_SIZE)
                        dump_dd if=$TARGET_TMP_FOLDER/tail_one_block of=$TARGET_TMP_FOLDER/tail bs=1 count=$tail_size

                        body_block_offset=$(expr $head_block_offset + 1)
                        if [[ $(expr $head_size + $tail_size) -ge $BLOCK_SIZE ]]; then
                            body_block_cnt=$(expr $dd_left_size / $BLOCK_SIZE)
                            body_block_cnt=$(expr $body_block_cnt - 1)
                        else
                            body_block_cnt=$(expr $dd_left_size / $BLOCK_SIZE)
                        fi
                        dump_dd if=$DUMP_PARTITION of=$TARGET_TMP_FOLDER/body bs=$BLOCK_SIZE count=$body_block_cnt skip=$body_block_offset

                        cat $TARGET_TMP_FOLDER/head>>$TARGET_FOLDER/$section_name
                        cat $TARGET_TMP_FOLDER/body>>$TARGET_FOLDER/$section_name
                        cat $TARGET_TMP_FOLDER/tail>>$TARGET_FOLDER/$section_name
                    else
                        dump_dd if=$DUMP_PARTITION of=$TARGET_TMP_FOLDER/tail bs=1 count=$dd_left_size skip=$dd_left_offset
                        cat $TARGET_TMP_FOLDER/tail>>$TARGET_FOLDER/$section_name
                    fi


                else
                    head_block_offset=$(expr $section_offset / $BLOCK_SIZE)
                    dump_dd if=$DUMP_PARTITION of=$TARGET_TMP_FOLDER/head_one_block bs=$BLOCK_SIZE count=1 skip=$head_block_offset
                    head_one_block_offset=$(expr $section_offset % $BLOCK_SIZE)
                    head_size=$(expr $BLOCK_SIZE - $head_one_block_offset)
                    dump_dd if=$TARGET_TMP_FOLDER/head_one_block of=$TARGET_TMP_FOLDER/head bs=1 count=$head_size skip=$head_one_block_offset

                    tail_block_end=$(expr $section_offset + $section_size)
                    tail_block_offset=$(expr $tail_block_end / $BLOCK_SIZE)
                    dump_dd if=$DUMP_PARTITION of=$TARGET_TMP_FOLDER/tail_one_block bs=$BLOCK_SIZE count=1 skip=$tail_block_offset
                    tail_size=$(expr $tail_block_end % $BLOCK_SIZE)
                    dump_dd if=$TARGET_TMP_FOLDER/tail_one_block of=$TARGET_TMP_FOLDER/tail bs=1 count=$tail_size

                    body_block_offset=$(expr $head_block_offset + 1)
                    if [[ $(expr $head_size + $tail_size) -ge $BLOCK_SIZE ]]; then
                        body_block_cnt=$(expr $section_size / $BLOCK_SIZE)
                        body_block_cnt=$(expr $body_block_cnt - 1)
                    else
                        body_block_cnt=$(expr $section_size / $BLOCK_SIZE)
                    fi
                    dump_dd if=$DUMP_PARTITION of=$TARGET_TMP_FOLDER/body bs=$BLOCK_SIZE count=$body_block_cnt skip=$body_block_offset

                    cat $TARGET_TMP_FOLDER/body>>$TARGET_TMP_FOLDER/head
                    cat $TARGET_TMP_FOLDER/tail>>$TARGET_TMP_FOLDER/head
                    mv $TARGET_TMP_FOLDER/head $TARGET_FOLDER/$section_name
                fi
            fi
        else
            #section size is smaller than 1 block
            #Parameters for dd do not support over 32bit number, use this method to support $section_offset > 32bit
            if [[ $(($section_offset)) -ge 0 ]]; then
                #section size < 0xFFFFFFFF, use 1 byte copy directly
                dump_dd if=$DUMP_PARTITION of=$TARGET_FOLDER/$section_name bs=1 count=$section_size skip=$section_offset
            else
                #section size > 0xFFFFFFFF, jump block offset to copy two block at first.
                section_block_offset=$(expr $section_offset / $BLOCK_SIZE)
                if [[ $section_block_offset -ne $previous_section_block_offset ]]; then
                    #do not need to copy block again
                    dump_dd if=$DUMP_PARTITION of=$TARGET_TMP_FOLDER/section_one_block bs=$BLOCK_SIZE count=2 skip=$section_block_offset
                fi

                section_one_block_offset=$(expr $section_offset % $BLOCK_SIZE)
                dump_dd if=$TARGET_TMP_FOLDER/section_one_block of=$TARGET_FOLDER/$section_name bs=1 count=$section_size skip=$section_one_block_offset
                previous_section_block_offset=$section_block_offset
            fi
        fi

        echo $FROM_SERVER:$CMD_COPY_UPDATE:$curr_section:$section_name:$section_size:$STATUS_DONE:$section_offset
    done
fi

#set success mark
touch $TARGET_FOLDER/completed

if [[ $DEBUG_FLAG = "TRUE" ]]; then
    echo 1 > /sys/kernel/dload/emmc_dload
else
    #clear validation bit and add CopyDone tag
    dump_dd if=/dev/zero of=$DUMP_PARTITION bs=$BLOCK_SIZE count=1
    touch $TARGET_TMP_FOLDER/copied
    echo "$COPIED_STRING" > $TARGET_TMP_FOLDER/copied
    dump_dd if=$TARGET_TMP_FOLDER/copied of=$DUMP_PARTITION bs=1 count=$FRIST_STRING_SIZE

    #clean temp files
    rm -rf $TARGET_TMP_FOLDER
fi
echo $FROM_SERVER:$CMD_COPY_FINISHED:$STATUS_OK:$TARGET_FOLDER
