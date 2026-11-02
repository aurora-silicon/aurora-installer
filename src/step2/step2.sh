#!/bin/sh
# SPDX-License-Identifier: MIT

set -e

DISTRO="##DISTRO##"
VGID="##VGID##"
PREBOOT="##PREBOOT##"
# raw: boot.bin, enrolled with --raw. macho: boot.macho, a Mach-O boot object
# with no __TEXT_BOOT_EXEC (kcbz 0), so iBoot does not start SPTM, TXM or
# exclaves; needed on T6050, whose secondary CPUs never run a raw object.
BOOT_MODE="##BOOT_MODE##"

self="$0"
cd "${self%%step2.sh}"

system_dir="$(cd ../../../; pwd)"
os_name="${system_dir##*/}"

# clear
printf '\033[2J\033[H'

echo "$DISTRO installer (second step)"
echo
echo "VGID: $VGID"
echo "System volume: $system_dir"
echo

BOLD="$(printf '\033[1m')"
RST="$(printf '\033[m')"

bputil -d -v "$VGID" >/tmp/bp.txt

if ! grep -q ': Paired' /tmp/bp.txt; then
    echo "Your system did not boot into the correct recoveryOS."
    echo
    echo "Each OS in your machine comes with its own copy of recoveryOS."
    echo "In order to complete the installation, we need to boot into"
    echo "the brand new recoveryOS that matches the OS which you are"
    echo "installing. The final installation step cannot be completed from"
    echo "a different recoveryOS."
    echo
    echo "Normally this should happen automatically after the initial"
    echo "installer sets up your new OS as the default boot option,"
    echo "but it seems something went wrong there. Let's try that again."
    echo
    echo "Press enter to continue."
    read

    while ! bless --setBoot --mount "$system_dir"; do
        echo
        echo "bless failed. Did you mistype your password?"
        echo "Press enter to try again."
        read
    done

    echo
    echo "Phew, hopefully that fixed it!"
    echo
    echo "Your system will now shut down. Once the screen goes blank,"
    echo "please wait 10 seconds, then press the power button and do not"
    echo "release it until you see the 'Entering startup options...'"
    echo "message, then select '$os_name' again."
    echo
    echo "Press enter to shut down your system."
    read
    shutdown -h now
    exit 1
fi

if ! grep -q 'one true recoveryOS' /tmp/bp.txt; then
    echo "Your system did not boot in One True RecoveryOS (1TR) mode."
    echo
    echo "To finish the installation, the system must be in this special"
    echo "mode. Perhaps you forgot to hold down the power button, or"
    echo "momentarily released it at some point?"
    echo
    echo "Note that tapping and then pressing the power button again will"
    echo "allow you to see the boot picker screen, but you will not be"
    echo "in the correct 1TR mode. You must hold down the power button"
    echo "in one continuous motion as you power on the machine."
    echo
    echo "Your system will now shut down. Once the screen goes blank,"
    echo "please wait 10 seconds, then press the power button and do not"
    echo "release it until you see the 'Entering startup options...'"
    echo "message, then select '$os_name' again."
    echo
    echo "Press enter to shut down your system."
    read
    shutdown -h now
    exit 1
fi

echo "You will see some messages advising you that you are changing the"
echo "security level of your system. These changes apply only to your"
echo "$DISTRO install, and are necessary to install a third-party OS."
echo
echo "Apple Silicon platforms maintain a separate security level for each"
echo "installed OS, and are designed to retain their security with mixed OSes."
echo "${BOLD}The security level of your macOS install will not be affected.${RST}"
echo
echo "You will be prompted for login credentials two times."
echo "Please enter your macOS credentials (for the macOS that you"
echo "used to run the first step of the installation)."
echo
echo "Press enter to continue."
echo

read

if [ "$BOOT_MODE" = macho ]; then
    if [ ! -e boot.macho ]; then
        echo "boot.macho is missing. This install needs a Mach-O boot object"
        echo "next to step2.sh; nothing has been changed."
        exit 1
    fi
    # Aura starts the secondary CPUs only with kernel CTRR disabled.
    BPUTIL_FLAGS=-nkcas
else
    BPUTIL_FLAGS=-nc
fi

while ! bputil $BPUTIL_FLAGS -v "$VGID"; do
    echo
    echo "bputil failed. Did you mistype your password?"
    echo "Press enter to try again."
    read
done

echo
echo

if [ -e "/System/Volumes/iSCPreboot/$VGID/boot" ]; then
    # This is an external volume, and kmutil has a problem with trying to pick
    # up the AdminUserRecoveryInfo.plist from the wrong place. Work around that.
    diskutil mount "$PREBOOT"
    preboot="$(diskutil info "$PREBOOT" | grep "Mount Point" | sed 's, *Mount Point: *,,')"
    cp -R "$preboot/$VGID/var" "/System/Volumes/iSCPreboot/$VGID/"
fi

if [ "$BOOT_MODE" = macho ]; then
    while ! csrutil allow-research-guests enable; do
        echo
        echo "csrutil failed. Did you mistype your password?"
        echo "Press enter to try again."
        read
    done

    bputil -d -v "$VGID" >/tmp/bp.txt
    if ! grep -q 'Kernel CTRR Status: Disabled' /tmp/bp.txt; then
        echo "The boot policy still has kernel CTRR enabled, so the boot"
        echo "object could not start the other CPUs. Stopping here."
        exit 1
    fi

    kcbz="$(kmutil inspect -z -B "$PWD/boot.macho" --show-mach-boot-properties | sed -n 's/^.*kcbz *: *//p')"
    if [ "$kcbz" != 0 ]; then
        echo "boot.macho records kcbz '$kcbz', not 0. Stopping here."
        exit 1
    fi

    while ! kmutil configure-boot -c boot.macho -v "$system_dir"; do
        echo
        echo "kmutil failed. Did you mistype your password?"
        echo "Press enter to try again."
        read
    done
else
    while ! kmutil configure-boot -c boot.bin --raw --entry-point 2048 --lowest-virtual-address 0 -v "$system_dir"; do
        echo
        echo "kmutil failed. Did you mistype your password?"
        echo "Press enter to try again."
        read
    done
fi

echo
echo "Wrapping up..."
echo

mount -u -w "$system_dir"

if [ -e "$system_dir/.IAPhysicalMedia" ]; then
    mv "$system_dir/.IAPhysicalMedia" "$system_dir/IAPhysicalMedia-disabled.plist"
fi

if [ -e "$system_dir/System/Library/CoreServices/SystemVersion-disabled.plist" ]; then
    mv -f "$system_dir/System/Library/CoreServices/SystemVersion"{-disabled,}".plist"
fi

echo
echo "Installation complete! Press enter to reboot."
read

reboot
