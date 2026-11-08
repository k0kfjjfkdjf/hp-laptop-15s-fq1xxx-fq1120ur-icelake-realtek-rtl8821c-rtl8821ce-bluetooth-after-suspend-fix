#!/usr/bin/env bash
# Installs the BT_EN resume hook. / Устанавливает хук BT_EN.
#   sudo ./install.sh                 hook only / только хук
#   sudo ./install.sh --rtw88-tweaks  + disable rtw88 power saving / + отключить энергосбережение rtw88
set -euo pipefail

HOOK_DST=/usr/lib/systemd/system-sleep/bt-en-resume
MODCONF=/etc/modprobe.d/rtl8821ce-fix.conf
BT_GPIO=0x06010012
cd "$(dirname "$(readlink -f "$0")")"

[[ $EUID -eq 0 ]] || { echo "Run as root: sudo $0 $*"; exit 1; }

model=$(cat /sys/class/dmi/id/product_name 2>/dev/null || true)
board=$(cat /sys/class/dmi/id/board_name 2>/dev/null || true)
echo "Model: $model | Board: $board"
if [[ $model != *"15s-fq1"* || $board != "86C9" ]]; then
    echo "WARNING: this fix was made for HP Laptop 15s-fq1xxx (board 86C9)."
    echo "The GPIO pin $BT_GPIO may be different (or dangerous to touch) on your machine."
    read -r -p "Continue anyway? [y/N] " a; [[ $a == [yY]* ]] || exit 1
fi

modprobe acpi_call 2>/dev/null || true
if [[ ! -w /proc/acpi/call ]]; then
    echo "ERROR: acpi_call module not available."
    echo "Arch: pacman -S acpi_call (stock kernel) or acpi_call-dkms (zen/lts/custom)."
    exit 1
fi
printf '%s' "\\_SB.GGOV $BT_GPIO" > /proc/acpi/call
state=$(tr -d '\0' < /proc/acpi/call)
echo "BT_EN ($BT_GPIO) = $state"
[[ $state == 0x0 || $state == 0x1 ]] || { echo "ERROR: unexpected answer from ACPI, aborting."; exit 1; }

install -Dm755 bt-en-resume "$HOOK_DST"
echo "Installed $HOOK_DST"

if [[ ${1:-} == --rtw88-tweaks ]]; then
    cat > "$MODCONF" <<'CONF'
options rtw88_core disable_lps_deep=y
options rtw88_pci disable_aspm=y
options btusb enable_autosuspend=n
CONF
    echo "Installed $MODCONF (takes effect after reboot)"
fi

if [[ $state == 0x0 ]]; then
    printf '%s' "\\_SB.SGOV $BT_GPIO 0x1" > /proc/acpi/call
    echo "Bluetooth was off — turned it on now."
fi
echo "Done. Test: systemctl suspend, then: bluetoothctl show; sudo journalctl -b -t bt-en-resume"
