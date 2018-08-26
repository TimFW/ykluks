#!/bin/sh

type getarg >/dev/null 2>&1 || . /lib/dracut-lib.sh

# Set defaults.
YK_SLOT="2"
YK_MAX_WAIT="60"
MESSAGE_TIMEOUT="10"
SHOW_YK_INSERT_MSG="false"
LUKS_PROMPT="Passphrase"
YKLUKS_PROMPT="Password"
LUKS_PASSPHRASE_FALLBACK="false"

# Load config file.
YKLUKS_CONF="/etc/ykluks.conf"
if [ -f "$YKLUKS_CONF" ] ; then
	. "$YKLUKS_CONF"
fi

LUKS_UUIDS="$(getargs rd.ykluks.uuid | tr ' ' '\n'| cut -d '-' -f 2-)"

display_msg_timeout () {
	local MSG="$1"
	(plymouth display-message --text="$MSG";sleep $MESSAGE_TIMEOUT;plymouth hide-message --text="$MSG") &
}

display_msg () {
	local MSG="$1"
	plymouth display-message --text="$MSG" &
}

hide_msg () {
	local MSG="$1"
	plymouth hide-message --text="$MSG" &
}

hide_devices () {
	# Find all networking devices currenly installed...
	HIDE_PCI="`lspci -mm -n | grep '^[^ ]* "02'|awk '{print $1}'`"

	# ... and optionally all USB controllers...
	if getargbool 0 rd.ykluks.hide_all_usb; then
	    HIDE_PCI="$HIDE_PCI `lspci -mm -n | grep '^[^ ]* "0c03'|awk '{print $1}'`"
	fi

	HIDE_PCI="$HIDE_PCI `getarg rd.ykluks.hide_pci | tr ',' ' '`"

	modprobe xen-pciback 2>/dev/null || :

	# ... and hide them so that Dom0 doesn't load drivers for them
	for dev in $HIDE_PCI; do
	    BDF=0000:$dev
	    if [ -e /sys/bus/pci/devices/$BDF/driver ]; then
		echo -n $BDF > /sys/bus/pci/devices/$BDF/driver/unbind
	    fi
	    echo -n $BDF > /sys/bus/pci/drivers/pciback/new_slot
	    echo -n $BDF > /sys/bus/pci/drivers/pciback/bind
	done
}

handle_yubikey () {
	WAIT_COUNTER="0"
	YUBIKEY_TEST=""
	YUBIKEY_MSG="Please insert your yubikey..."
	while ! YUBIKEY_TEST="$(ykchalresp -"$YK_SLOT" test 2> /dev/null)" ; do
		if [ "$SHOW_YK_INSERT_MSG" != "true" ] ; then
			break
		fi

		if [ "$YUBIKEY_MSG" != "" ] ; then
			display_msg "$YUBIKEY_MSG"
			HIDE_MSG="$YUBIKEY_MSG"
			YUBIKEY_MSG=""
		fi

		if [ "$WAIT_COUNTER" -ge "$YK_MAX_WAIT" ] ; then
			break
		fi

		WAIT_COUNTER="$[$WAIT_COUNTER+1]"
		sleep 1
	done

	if [ "$HIDE_MSG" != "" ] ; then
		hide_msg "$HIDE_MSG"
	fi

	while true ; do
		if [ "$YUBIKEY_TEST" == "" ] ; then
			if [ "$LUKS_PASSPHRASE_FALLBACK" != "true" ] ; then
				break
			fi
			LUKS_PASSPHRASE="$(/usr/bin/systemd-ask-password --no-tty "$LUKS_PROMPT")"
		else
			YUBIKEY_PASS="$(/usr/bin/systemd-ask-password --no-tty "$YKLUKS_PROMPT")"
			LUKS_PASSPHRASE="$(ykchalresp -"$YK_SLOT" "$YUBIKEY_PASS")"
			YUBIKEY_MSG="Received response from yubikey."
			display_msg_timeout "$YUBIKEY_MSG"
		fi
		LUKS_OPEN_FAILURE="false"
		for UUID in $LUKS_UUIDS ; do
			DEV="$(blkid -U "$UUID")"
			if echo "$LUKS_PASSPHRASE" | cryptsetup luksOpen "$DEV" luks-$UUID ; then
				LUKS_MSG="Luks device opened successful: $DEV"
				display_msg_timeout "$LUKS_MSG"
			else
				LUKS_MSG="Failed to open luks device: $DEV (Wrong password?)"
				display_msg_timeout "$LUKS_MSG"
				LUKS_OPEN_FAILURE="true"
			fi
		done
		if ! $LUKS_OPEN_FAILURE ; then
			break
		fi
	done
}

if [ "$LUKS_UUIDS" != "" ] ; then
	handle_yubikey
fi

rm /etc/udev/rules.d/69-yubikey.rules
systemctl daemon-reload

# Make sure we hide devices from dom0 after yubikey/luks setup.
hide_devices
