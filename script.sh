#!/bin/bash
#
# Util to check USB subsystem for Linux kernel 3.12+ on TI Sitara devices
#
# Copyright (C) 2018 Texas Instruments Incorporated - http://www.ti.com/
#
#
#  Redistribution and use in source and binary forms, with or without
#  modification, are permitted provided that the following conditions
#  are met:
#
#    Redistributions of source code must retain the above copyright
#    notice, this list of conditions and the following disclaimer.
#
#    Redistributions in binary form must reproduce the above copyright
#    notice, this list of conditions and the following disclaimer in the
#    documentation and/or other materials provided with the
#    distribution.
#
#    Neither the name of Texas Instruments Incorporated nor the names of
#    its contributors may be used to endorse or promote products derived
#    from this software without specific prior written permission.
#
#  THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
#  "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
#  LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
#  A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
#  OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
#  SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
#  LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
#  DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
#  THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
#  (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
#  OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

VERSION=0.3.2
DTPATH=/proc/device-tree
DEVPATH=/sys/devices/platform
KMODPATH="/lib/modules/`uname -r`"

### ENV
# $V: debug flag
# $PLATFORM: force g_plaform if not found in device tree

### functions ###

# $1 commands to be checked
check_command() {
    local _lst="$*"
    local _cmd

    for _cmd in $_lst; do
        which $_cmd > /dev/null || {
            echo "Error: $_cmd command not found"
            exit 1
        }
    done
}

# check if the kernel is supported
# this tool only runs on v4.0+ kernel
# return 0 - if kernel version >= 4.0
#        1 - if kernel version < 4.0
has_supported_kernel() {
	local _ver
	local _t

    check_command uname
    uname -a
	_ver=`uname -r`
    _t=${_ver%%.*}
    # 3.x.x or older, unsupported
    [ $_t -ge 4 ] || return 1
    return 0
}

# define variables for musb entries in sysfs and device tree
# output variables: USB_DT_PARENT, USB0DT, USB1DT
#                   USB_DEV_PARENT, USB0DEV, USB1DEV
query_musb_entries() {
    local _lst
    local _t
    local _intr

    check_command find

    # find usb entry names in device-tree
    _t=$(find ${DTPATH}/ -maxdepth 2 -name '*47400000*')
    [ -n "$_t" ] && USB_DT_PARENT=$_t || {
        echo "usb parent DT node not found in device-tree"
        exit 1
    }

    _lst=$(find ${USB_DT_PARENT}/ -maxdepth 1 -name 'usb@*')
    [ -n "$_lst" ] || {
        echo "usb0 and usb1 DT node not found in device-tree"
        exit 1
    }

    # find USB child DT node based on its interrupt number
    for _t in $_lst; do
        [[ -f "${_t}/interrupts" ]] || continue
        _intr=$(hexdump ${_t}/interrupts | head -1 | cut -d' ' -f3)
        case $_intr in
            "1200") USB0DT=$_t;;
            "1300") USB1DT=$_t;;
            *)  echo "unkown usb interrupt number $_intr"
                exit 1
        esac
    done

    # find device names in sysfs
    _t=$(find ${DEVPATH}/ -maxdepth 2 -name '*47400000*')
    [ -n "$_t" ] && USB_DEV_PARENT=$_t || {
        echo "usb device not found in sysfs"
        exit 1
    }

    _t=$(find ${USB_DEV_PARENT}/47401400.usb/ -maxdepth 1 -name 'musb-hdrc.*')
    [ -n "$_t" ] && USB0DEV=$_t || echo "usb0 device not found in sysfs"

    _t=$(find ${USB_DEV_PARENT}/47401c00.usb/ -maxdepth 1 -name 'musb-hdrc.*')
    [ -n "$_t" ] && USB1DEV=$_t || echo "usb1 device not found in sysfs"
}

# check if the platform is supported
# return 0 - if platform is supported
#        1 - if platform is not supported
check_platform () {
	local _hw

    check_command grep
    _hw=`cat ${DTPATH}/compatible | tr '\0' ' '`
    DBG_PRINT "DT compatible: $_hw"

    if [[ "$_hw" == *"ti,am33xx"* ]]; then
        g_platform="am335x"
    elif [[ "$_hw" == *"ti,am43"* ]]; then
        g_platform="am437x"
    else
        # read from ENV
        g_platform=$PLATFORM
    fi

    DBG_PRINT "g_platform: $g_platform"
    case $g_platform in
        "am335x")
            query_musb_entries
            return 0;;
        "am437x")
            USB0DT="$(find -L $DTPATH -name 'usb@48390000')"
            USB1DT="$(find -L $DTPATH -name 'usb@483d0000')"
            return 0;;
        *)
            echo "Unsupported \"$g_platform\""
            return 1;;
    esac
}

# get kernel config options from /proc/config.gz
# params $@ - the list of config options to query, without 'CONFIG_'
# return - the config options settings in /proc/config.gz
get_kernel_configs() {
    local _opts="$@"
    local _lst=""
    local _t

    check_command zcat grep
    for _t in $_opts; do
        [ -z "$_lst" ] &&
            _lst="^CONFIG_${_t}\>" ||
            _lst="${_lst}\|^CONFIG_${_t}\>"
    done
    [ -z "$_lst" ] || zcat /proc/config.gz | grep "$_lst"
}

# check a kernel CONFIG option
# params $1 - the config option list returned from get_kernel_config()
#             if "", directly check $2 from /proc/config.gz
#        $2 - the config option to check
#        $3 = '-q', quiet output
# return 0 - undefined
#        1 - defined as 'm', kernel module
#        2 - defined as 'y', kernel builtin
check_kernel_config() {
    local _cfg
    local _t

    [ -n "$2" ] || return 0

    if [ -z "$1" ]; then
        check_command zcat
        _cfg=`zcat /proc/config.gz | grep "^$2\>"`
    else
        for _t in $1; do
            [[ "$_t" != "${2}="? ]] || { _cfg=$_t; break; }
        done
    fi

    case ${_cfg#*=} in
        "y") return 2;;
        "m") return 1;;
          *) [ "$3" = "-q" ] ||
              echo "Error: $2 is undefined in kernel config"
          return 0;;
    esac
}

# check a kernel module
# $1 - module name, relative path from drivers/, without .ko surfix
# return 0 - found
#        1 - error
check_module() {
    local _modname
    local _moddep

    [ -n "$1" ] || return 1

    _modname="${KMODPATH}/kernel/drivers/${1}.ko"
    _moddep="${KMODPATH}/modules.dep"

    DBG_PRINT "${1}.ko checking..."
    [ -f $_modname ] || {
        echo "Error: $_modname not found."
        echo "       Please ensure 'make module_install' is done properly."
        return 1
    }

    DBG_PRINT "${1}.ko found"
    [ -f $_moddep ] || $g_printed_once || {
        echo "Error: $_moddep not found."
        echo "       Please ensure 'make module_install' is done properly."
        g_printed_once=true
    }

    DBG_PRINT "${1}.ko moddep checked"
    check_command lsmod basename tr

    lsmod | grep `basename $1 | tr '-' '_'` > /dev/null || {
        DBG_PRINT ">>>> ${1}.ko not found in lsmod:"
        if grep "${1}.ko:" $_moddep > /dev/null; then
            echo "Error: $_moddep seems to be valid,"
            echo "       but `basename $1`.ko is not loaded."
            echo "       Please provide /proc/config.gz and ${KMODPATH}/*"
            echo "       for further investigation."
        else
            echo "Error: `basename $1`: $_moddep is invalid."
            echo "       Please run command 'depmod' on the target to re-generate it,"
            echo "       then reboot the target. If the issue still exists, please"
            echo "       ensure 'make module_install' is done properly."
        fi

        return 1
    }
    DBG_PRINT "${1}.ko done"
    return 0
}

# check kernel config, and modules (if CONFIG_*=M) for musb
check_musb_drivers() {
    local _lst=("USB_MUSB_HDRC" "USB_MUSB_DUAL_ROLE" "USB_OTG" "USB_MUSB_DSPS" \
                "AM335X_PHY_USB" "MUSB_PIO_ONLY" "TI_CPPI41")
    local _opts

    _opts=$(get_kernel_configs ${_lst[*]})

    check_kernel_config "$_opts" CONFIG_USB_MUSB_HDRC
    [ $? != 1 ] || check_module 'usb/musb/musb_hdrc'

    check_kernel_config "$_opts" CONFIG_USB_MUSB_DUAL_ROLE -q
    [ $? != 0 ] || echo "Warning: CONFIG_USB_MUSB_DUAL_ROLE undefined."

    check_kernel_config "$_opts" CONFIG_USB_OTG -q
    [ $? == 0 ] || echo "Warning: CONFIG_USB_OTG defined."

    check_kernel_config "$_opts" CONFIG_USB_MUSB_DSPS
    [ $? != 1 ] || {
        check_module 'usb/musb/musb_dsps'
    }

    check_kernel_config "$_opts" CONFIG_AM335X_PHY_USB
    [ $? != 1 ] || {
        check_module 'usb/phy/phy-am335x'
        check_module 'usb/phy/phy-am335x-control'
    }

    check_kernel_config "$_opts" CONFIG_MUSB_PIO_ONLY -q
    [ $? != 0 ] || {
       if check_kernel_config "$_opts" CONFIG_TI_CPPI41 -q; then
           echo "Error: MUSB CPPI DMA mode is enabled, but CPPI moudle is not enabled in DMA Engine."
           echo "       Please enable CONFIG_TI_CPPI41 under DMA Engine Support in kernel config."
       fi
    }
}

# check kernel config, and modules (if CONFIG_*=M) for dwc3
check_dwc3_drivers() {
    local _lst=("USB_DWC3" "USB_DWC3_DUAL_ROLE" "USB_OTG" "USB_DWC3_OMAP" \
                "USB_XHCI_HCD" "OMAP_CONTROL_PHY" "OMAP_USB2")
    local _opts

    _opts=$(get_kernel_configs ${_lst[*]})

    check_kernel_config "$_opts" CONFIG_USB_DWC3
    [ $? != 1 ] || check_module 'usb/dwc3/dwc3'

    check_kernel_config "$_opts" CONFIG_USB_DWC3_DUAL_ROLE -q
    [ $? != 0 ] || echo "Warning: CONFIG_USB_DWC3_DUAL_ROLE undefined."

    check_kernel_config "$_opts" CONFIG_USB_OTG -q
    [ $? == 0 ] || echo "Warning: CONFIG_USB_OTG defined."

    check_kernel_config "$_opts" CONFIG_USB_DWC3_OMAP
    [ $? != 1 ] || check_module 'usb/dwc3/dwc3-omap'

    check_kernel_config "$_opts" CONFIG_USB_XHCI_HCD
    [ $? != 1 ] || {
        check_module 'usb/host/xhci-plat-hcd'
        check_module 'usb/host/xhci-hcd'
    }

    check_kernel_config "$_opts" CONFIG_OMAP_CONTROL_PHY
    [ $? != 1 ] || check_module 'phy/ti/phy-omap-control'

    check_kernel_config "$_opts" CONFIG_OMAP_USB2
    [ $? != 1 ] || check_module 'phy/ti/phy-omap-usb2'
}

check_musb_dt() {
    local _dt_dir
    local _ent
    local _sts
    local _t

    case $USB_DT_PARENT in
        *"usb@"*)
            _ent=("control@44e10620" "usb-phy@47401300" "usb-phy@47401b00" \
                  "usb@47401000" "usb@47401800" "dma-controller@47402000")
            ;;
        *"target-module@"*)
            _ent=("usb-phy@1300" "usb-phy@1b00" "usb@1400" "usb@1800" \
                  "dma-controller@2000")
            ;;
        *)
            echo "Warning: unknown USB DT ($USB_DT_PARENT)"
            return
    esac

    echo "Device Tree USB node status:"
    for _t in '.' ${_ent[*]}; do
        [ -d "${USB_DT_PARENT}/${_t}/" ] || {
            echo -e "\tWarning: USB DT node $_t not found"
            continue
        }
        [ -f "${USB_DT_PARENT}/${_t}/status" ] &&
            _sts=$(tr -d '\0' <${USB_DT_PARENT}/${_t}/status) ||
            _sts="(enabled)"
        echo -e "\t$_t: $_sts"
    done
}

dump_sysfs_debugfs() {
    local _debugfs
    local _l
    local _f

    _debugfs=`sed -ne 's/^debugfs \(.*\) debugfs.*/\1/p' /proc/mounts`
    [ -n "$_debugfs" ] || return

    case $g_platform in
        am335x)
            _debugfs=$(find $_debugfs -name 'musb-hdrc.*')
            _debugfs=${_debugfs%/*}

            for _f in $USB0DEV $USB1DEV; do
                _l=$(basename $_f)
                echo "$_l: mode $(cat ${_f}/mode), $(cat ${_f}/vbus)"
                grep -i 'power\|devctl\|testmode' ${_debugfs}/${_l}/regdump
            done
            ;;
    esac
}

check_gadget_kernel_config() {
    local _lst=("USB_ZERO" "USB_AUDIO" "USB_ETH" "USB_G_NCM" "USB_MASS_STORAGE" \
                "USB_G_SERIAL" "USB_G_PRINTER")
    local _opts

    _opts=$(get_kernel_configs ${_lst[*]})

    check_kernel_config "$_opts" CONFIG_USB_ZERO -q ||
        echo "Gadget Kernel Config: g_zero is enabled"
    check_kernel_config "$_opts" CONFIG_USB_AUDIO -q ||
        echo "Gadget Kernel Config: g_audio is enabled"
    check_kernel_config "$_opts" CONFIG_USB_ETH -q ||
        echo "Gadget Kernel Config: g_ether is enabled"
    check_kernel_config "$_opts" CONFIG_USB_G_NCM -q ||
        echo "Gadget Kernel Config: g_ncm is enabled"
    check_kernel_config "$_opts" CONFIG_USB_MASS_STORAGE -q ||
        echo "Gadget Kernel Config: g_mass_storage is enabled"
    check_kernel_config "$_opts" CONFIG_USB_G_SERIAL -q ||
        echo "Gadget Kernel Config: g_serial is enabled"
    check_kernel_config "$_opts" CONFIG_USB_G_PRINTER -q ||
        echo "Gadget Kernel Config: g_printer is enabled"
}

### debug ###

g_log_file=/tmp/chkusb.log

DBG_ENABLE() { g_dbg_enabled=true; }
DBG_DISABLE() { g_dbg_enabled=false; }
DBG_LOG_RESET() { ! $g_dbg_enabled || echo > $g_log_file; }
DBG_PRINT() { ! $g_dbg_enabled || echo "$(date +%H:%M:%S) [$(basename $0)]: $*"; }
DBG_LOG() { DBG_PRINT $* >> $g_log_file; }
DBG_LOG_MARK() { DBG_PRINT "----------------" >> $g_log_file; }


### main ####

g_printed_once=false

echo "chkusb.sh Version $VERSION"

[ "$V" = "1" ] && DBG_ENABLE && DBG_LOG_RESET || DBG_DISABLE

has_supported_kernel ||
    { echo "Unsupported kernel version: `uname -r`"; exit 1; }
check_platform || exit 2
DBG_PRINT device: $g_platform
[ -d ${DTPATH} ] || { echo "Error: ${DTPATH} not found"; exit 3; }

check_command lsusb
if lsusb > /dev/null 2>&1; then
    echo "USB is initialized"
else
    echo "USB initialization failed"
fi

# check kernel configs

if [ -f /proc/config.gz ]; then
    case $g_platform in
        am335x) check_musb_drivers;;
        am437x) check_dwc3_drivers;;
    esac
else
    echo "Error: /proc/config.gz not found"
fi

dump_sysfs_debugfs

# check dr_mode & gadget drivers

check_command basename
for _usb_dir in "${USB0DT}" "${USB1DT}"; do
    [ -n "$_usb_dir" ] || continue

    [ -f "$_usb_dir/status" ] &&
        _status=`tr -d '\0' <$_usb_dir/status` ||
        _status='(enabled)'
    _dr_mode=`tr -d '\0'  <$_usb_dir/dr_mode`
    echo `basename $_usb_dir`: $_dr_mode, $_status

    [ "$_status" = "disabled" -o "$_dr_mode" = "host" ] || gadget_mode=true
done

case $g_platform in
    am335x) check_musb_dt;;
    *) ;;
esac

DBG_PRINT $gadget_mode
$gadget_mode || exit 0

echo

check_kernel_config "" CONFIG_USB_LIBCOMPOSITE
case $? in
    0) echo "Error: no any gadget driver enabled"
       exit 6;;
    1) is_gadget_builtin=false;;
    2) echo "The gadget driver is built-in"
       is_gadget_builtin=true;;
esac

[[ ! -f /proc/config.gz ]] || check_gadget_kernel_config

g_driver=`grep '^DRIVER=' /sys/class/udc/*/uevent 2>/dev/null`
echo "gadget driver loaded: ${g_driver:-(none)}"

[[ $is_gadget_builtin == false ]] || exit 0

echo

if [ -d "$KMODPATH" ]; then
    echo "The list of USB gadget drivers installed:"
    ls -1Rp ${KMODPATH}/kernel/drivers/usb/gadget/{function,legacy}/
else
    echo "Error: $KMODPATH not found"
    echo "       Please ensure 'make modules_install' is done properly."
    exit 7
fi

# vim: ft=sh:ts=4:sw=4:et
