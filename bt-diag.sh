#!/usr/bin/env bash
# bt-diag.sh — поэтапная диагностика Bluetooth (Realtek RTL8821CE) после сна.
#
#   ./bt-diag.sh                       диагностика + попытки оживить BT, если он пропал
#   ./bt-diag.sh --no-fix              только диагностика, ничего не трогать
#   ./bt-diag.sh --suspend [deep|s2idle]   тест сна через rtcwake (сам заснёт и проснётся)
#   ./bt-diag.sh --suspend --unload bt     то же, но перед сном выгрузить btusb
#   ./bt-diag.sh --suspend --unload all    перед сном выгрузить btusb и Wi‑Fi драйвер
#   ./bt-diag.sh --sleep 30            длительность сна в тесте, секунд
#   ./bt-diag.sh --hibernate           гибернация (полный цикл питания с сохранением сессии)
#   ./bt-diag.sh --chip-reset          только «холодный перезапуск» карты Wi‑Fi/BT на живой
#                                      системе: аппаратные сбросы и снятие питания со слота
#   ./bt-diag.sh --full-cycle [сек]    ВСЁ сразу: выгрузить драйверы, удалить карту, выключить
#                                      USB-порт, линк PCIe и питание, подержать N с (5),
#                                      включить и активно искать адаптер
#   ./bt-diag.sh --bt-gpio [сек]       выключить/включить линию питания Bluetooth (BT_EN)
#                                      через ACPI BIOS — настоящий сброс BT-части чипа
#
# Лог каждого запуска сохраняется в ./logs/

set -u

BT_VID=0bda
BT_PID=b00a
WIFI_PCI=0000:01:00.0
WIFI_MOD=rtw88_8821ce
DEFAULT_PORT=1-10

DO_FIX=1
DO_SUSPEND=0
DO_HIBERNATE=0
DO_CHIPRESET=0
DO_FULLCYCLE=0
DO_BTGPIO=0
HOLD_SEC=5
SUSPEND_MODE=""
UNLOAD=""
SLEEP_SEC=20

usage() { sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

ARGS=("$@")
while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-fix)    DO_FIX=0 ;;
        --suspend)
            DO_SUSPEND=1
            if [[ "${2:-}" == "deep" || "${2:-}" == "s2idle" ]]; then SUSPEND_MODE=$2; shift; fi ;;
        --unload)
            UNLOAD=${2:-}; shift
            [[ $UNLOAD == bt || $UNLOAD == all ]] || { echo "--unload: bt или all"; exit 1; } ;;
        --sleep)     SLEEP_SEC=${2:?нужно число секунд}; shift ;;
        --hibernate) DO_HIBERNATE=1 ;;
        --chip-reset) DO_CHIPRESET=1 ;;
        --bt-gpio)   DO_BTGPIO=1
            if [[ "${2:-}" =~ ^[0-9]+$ ]]; then HOLD_SEC=$2; shift; fi ;;
        --full-cycle) DO_FULLCYCLE=1
            if [[ "${2:-}" =~ ^[0-9]+$ ]]; then HOLD_SEC=$2; shift; fi ;;
        -h|--help)   usage ;;
        *) echo "Неизвестный параметр: $1"; usage ;;
    esac
    shift
done

if [[ $EUID -ne 0 ]]; then
    echo "Нужны права root, перезапускаю через sudo..."
    exec sudo -- "$(readlink -f "$0")" "${ARGS[@]}"
fi

SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
STATE_FILE="$SCRIPT_DIR/.last_usb_port"
LOG_DIR="$SCRIPT_DIR/logs"
mkdir -p "$LOG_DIR"
LOG="$LOG_DIR/bt-diag-$(date +%Y%m%d-%H%M%S).log"
OWNER=${SUDO_USER:-root}

if [[ -t 1 ]]; then
    R=$'\e[31m'; G=$'\e[32m'; Y=$'\e[33m'; B=$'\e[1;36m'; D=$'\e[2m'; N=$'\e[0m'
else
    R=; G=; Y=; B=; D=; N=
fi
exec > >(tee -a "$LOG") 2>&1

section() { echo; echo "${B}━━━ $* ━━━${N}"; }
ok()   { echo "  ${G}[OK]${N}   $*"; }
warn() { echo "  ${Y}[!!]${N}   $*"; }
bad()  { echo "  ${R}[FAIL]${N} $*"; }
info() { echo "  ${D}·${N}      $*"; }
indent() { sed 's/^/         /'; }

SUMMARY=()
note() { SUMMARY+=("$*"); }

# --- помощники ----------------------------------------------------------
bt_usb_path() {
    local d
    for d in /sys/bus/usb/devices/*; do
        [[ -f $d/idVendor && -f $d/idProduct ]] || continue
        if [[ $(<"$d/idVendor") == "$BT_VID" && $(<"$d/idProduct") == "$BT_PID" ]]; then
            basename "$d"; return 0
        fi
    done
    return 1
}

known_port() {
    local p
    if p=$(bt_usb_path); then echo "$p"
    elif [[ -s $STATE_FILE ]]; then cat "$STATE_FILE"
    else echo "$DEFAULT_PORT"; fi
}

port_disable_file() {
    local bus=${1%%-*} num=${1#*-}
    [[ $num == *.* ]] && return 1
    local f="/sys/bus/usb/devices/${bus}-0:1.0/usb${bus}-port${num}/disable"
    [[ -e $f ]] && echo "$f"
}

pci_root_port() {  # корневой порт PCIe, к которому подключена карта
    local p
    p=$(readlink -f /sys/bus/pci/devices/$WIFI_PCI/.. 2>/dev/null) || return 1
    [[ -n $p ]] && basename "$p"
}
ROOT_PORT=$(pci_root_port)
[[ -z $ROOT_PORT || $ROOT_PORT == pci* ]] && ROOT_PORT=0000:00:1c.0   # запасной вариант

hci_present() { [[ -e /sys/class/bluetooth/hci0 ]]; }

bt_alive() {
    hci_present || return 1
    timeout 5 bluetoothctl show 2>/dev/null | grep -q '^Controller'
}

short_state() {
    local usb hci ctl p
    if p=$(bt_usb_path); then usb="${G}есть ($p)${N}"; else usb="${R}нет${N}"; fi
    if hci_present; then hci="${G}есть${N}"; else hci="${R}нет${N}"; fi
    if bt_alive; then
        local pw; pw=$(timeout 5 bluetoothctl show 2>/dev/null | awk -F': ' '/Powered/{print $2}')
        ctl="${G}виден${N} (Powered: ${pw:-?})"
    else ctl="${R}No default controller${N}"; fi
    echo "  USB-устройство: $usb | hci0: $hci | bluetoothctl: $ctl"
}

wait_alive() {
    local i
    for ((i=0; i<${1:-8}; i++)); do bt_alive && return 0; sleep 1; done
    return 1
}

reload_all() {   # вернуть все драйверы на место
    [[ -e /sys/bus/pci/devices/$WIFI_PCI ]] || echo 1 > /sys/bus/pci/rescan
    modprobe "$WIFI_MOD" 2>/dev/null
    modprobe btusb 2>/dev/null
    systemctl is-active --quiet bluetooth || systemctl start bluetooth
}

# --- новые способы сброса -----------------------------------------------
step_rfkill_all() {
    modprobe hp_wmi 2>/dev/null
    rfkill block all; sleep 3; rfkill unblock all
}

step_pci_resets() {   # перебрать ВСЕ аппаратные методы сброса карты
    local d=/sys/bus/pci/devices/$WIFI_PCI m rc=1
    [[ -e $d/reset ]] || { echo "нет $d/reset"; return 1; }
    local methods; methods=$(cat "$d/reset_method" 2>/dev/null)
    echo "карта поддерживает: ${methods:-ничего}"
    modprobe -r btusb btrtl 2>/dev/null
    [[ -e $d/driver ]] && echo "$WIFI_PCI" > "$d/driver/unbind"
    for m in acpi bus flr pm; do
        [[ " $methods " == *" $m "* ]] || continue
        echo "$m" > "$d/reset_method" 2>/dev/null || continue
        if echo 1 > "$d/reset" 2>/dev/null; then echo "  сброс '$m': выполнен"; rc=0
        else echo "  сброс '$m': ошибка"; fi
        sleep 2
    done
    echo default > "$d/reset_method" 2>/dev/null
    echo "$WIFI_PCI" > /sys/bus/pci/drivers_probe 2>/dev/null
    return $rc
}

step_d3cold() {
    local d=/sys/bus/pci/devices/$WIFI_PCI rp=/sys/bus/pci/devices/$ROOT_PORT
    [[ -e $rp ]] || { echo "корневой порт $ROOT_PORT не найден"; return 1; }
    modprobe -r btusb btrtl 2>/dev/null
    echo 1 > "$d/remove" 2>/dev/null
    local orig; orig=$(cat "$rp/power/control")
    echo auto > "$rp/power/control"
    sleep 6
    echo "состояние порта $ROOT_PORT: $(cat $rp/power_state 2>/dev/null || cat $rp/power/runtime_status)"
    [[ -r $rp/firmware_node/real_power_state ]] && echo "ACPI real_power_state: $(cat $rp/firmware_node/real_power_state)"
    echo on > "$rp/power/control"
    sleep 2
    echo 1 > /sys/bus/pci/rescan
    sleep 2
    echo "$orig" > "$rp/power/control" 2>/dev/null
}

detach_card() {   # аккуратно убрать карту из системы перед жёстким сбросом
    systemctl stop bluetooth 2>/dev/null
    modprobe -r btusb btrtl 2>/dev/null
    [[ -e /sys/bus/pci/devices/$WIFI_PCI ]] && echo 1 > /sys/bus/pci/devices/$WIFI_PCI/remove
    sleep 1
}

step_reset_each_method() {   # все методы сброса, которые поддерживает карта
    local d=/sys/bus/pci/devices/$WIFI_PCI m rc=1
    [[ -e $d/reset_method ]] || { echo "у карты нет методов сброса"; return 1; }
    local methods; methods=$(cat "$d/reset_method")
    echo "поддерживаются: $methods"
    [[ -e $d/driver ]] && echo "$WIFI_PCI" > "$d/driver/unbind"
    for m in $methods; do
        echo "$m" > "$d/reset_method" 2>/dev/null || continue
        if echo 1 > "$d/reset" 2>/dev/null; then echo "  сброс $m: выполнен"; rc=0
        else echo "  сброс $m: ошибка"; fi
        sleep 1
    done
    echo default > "$d/reset_method" 2>/dev/null
    echo "$WIFI_PCI" > /sys/bus/pci/drivers_probe 2>/dev/null
    return $rc
}

step_link_disable() {   # выключить линк PCIe на корневом порту (карта уходит в сброс), потом включить
    command -v setpci >/dev/null || { echo "нет setpci (pciutils)"; return 1; }
    local rp=${ROOT_PORT#0000:} v nv
    v=$(setpci -s "$rp" CAP_EXP+10.w 2>/dev/null) || { echo "не читается Link Control порта $rp"; return 1; }
    echo "Link Control порта $rp: 0x$v"
    detach_card
    nv=$(printf '%04x' $((0x$v | 0x10)))
    setpci -s "$rp" CAP_EXP+10.w="$nv"
    echo "линк выключен, жду 5 с..."
    sleep 5
    setpci -s "$rp" CAP_EXP+10.w="$(printf '%04x' $((0x$v & ~0x10)))"
    echo "линк включён"
    sleep 2
    echo 1 > /sys/bus/pci/rescan
}

step_slot_power() {   # настоящее выключение питания слота, если у порта есть hotplug-управление
    local s found=0
    for s in /sys/bus/pci/slots/*; do
        [[ -e $s/address && -e $s/power ]] || continue
        [[ $(cat "$s/address") == "${WIFI_PCI%.*}" || $(cat "$s/address") == "${WIFI_PCI:0:10}" ]] || continue
        found=1
        echo "слот $(basename "$s"), питание сейчас: $(cat "$s/power")"
        detach_card
        echo 0 > "$s/power" && echo "питание снято, жду 5 с..."
        sleep 5
        echo 1 > "$s/power" && echo "питание подано"
        sleep 2; echo 1 > /sys/bus/pci/rescan
    done
    [[ $found -eq 1 ]] || { echo "у слота карты нет управления питанием (hotplug) — ноутбук это не поддерживает"; return 1; }
}


# --- линия включения Bluetooth (GPIO), найдена в DSDT ноутбука -----------------
# HP 15s-fq1xxx: \_SB.SGOV(0x06010012, 1/0) — BT вкл/выкл (так делает сама BIOS
# при загрузке в \_SB.WLBT._STA и при нажатии «режима самолёта»).
BT_GPIO=0x06010012
acpi_call() {   # acpi_call '\_SB.GGOV 0x06010012' -> печатает результат
    [[ -e /proc/acpi/call ]] || modprobe acpi_call 2>/dev/null
    [[ -e /proc/acpi/call ]] || { echo "нет /proc/acpi/call (модуль acpi_call)"; return 1; }
    echo "$1" > /proc/acpi/call
    tr -d '\0' < /proc/acpi/call; echo
}
bt_gpio_get() { acpi_call "\\_SB.GGOV $BT_GPIO"; }
bt_gpio_set() { acpi_call "\\_SB.SGOV $BT_GPIO $1" >/dev/null; }

step_bt_gpio() {
    local hold=${HOLD_SEC:-3} port pf
    port=$(known_port); pf=$(port_disable_file "$port")
    echo "линия BT_EN ($BT_GPIO) сейчас: $(bt_gpio_get)   (0x1 = включён, 0x0 = выключен)"
    systemctl stop bluetooth 2>/dev/null
    modprobe -r btusb btrtl 2>/dev/null
    bt_gpio_set 0x0; echo "BT_EN → 0 (Bluetooth-часть чипа выключена), держу $hold с"
    sleep "$hold"
    bt_gpio_set 0x1; echo "BT_EN → 1, сейчас: $(bt_gpio_get)"
    sleep 2
    if ! bt_usb_path >/dev/null && [[ -n $pf ]]; then
        echo 1 > "$pf"; sleep 1; echo 0 > "$pf"; echo "USB-порт $port передёрнут"
    fi
    local t
    for ((t=1; t<=15; t++)); do
        bt_usb_path >/dev/null && { echo "[${t} с] адаптер появился на USB: $(bt_usb_path)"; break; }
        sleep 1
    done
    modprobe btusb; systemctl start bluetooth
    bt_usb_path >/dev/null
}


# --- полный холодный цикл: всё отключить одновременно, подержать, включить и искать ---
step_full_cycle() {
    local hold=${HOLD_SEC:-5}
    local rp=/sys/bus/pci/devices/$ROOT_PORT rps=${ROOT_PORT#0000:}
    local port; port=$(known_port)
    local pf; pf=$(port_disable_file "$port")
    local lc="" slot="" s orig_ctl

    echo "▼ ВЫКЛЮЧЕНИЕ (всё сразу)"
    systemctl stop bluetooth 2>/dev/null
    modprobe -r btusb btrtl 2>/dev/null && echo "  драйверы BT выгружены"
    modprobe -r "$WIFI_MOD" 2>/dev/null && echo "  драйвер Wi‑Fi выгружен"
    if [[ -e /sys/bus/pci/devices/$WIFI_PCI ]]; then
        echo 1 > /sys/bus/pci/devices/$WIFI_PCI/remove && echo "  карта удалена из системы (ядро её «забыло»)"
    fi
    if [[ -n $pf ]]; then echo 1 > "$pf" && echo "  USB-порт $port выключен"; fi
    if command -v setpci >/dev/null && lc=$(setpci -s "$rps" CAP_EXP+10.w 2>/dev/null); then
        setpci -s "$rps" CAP_EXP+10.w="$(printf '%04x' $((0x$lc | 0x10)))" && echo "  линк PCIe выключен (карта в сбросе)"
    else lc=""; echo "  линк PCIe: не удалось (нет setpci?)"; fi
    for s in /sys/bus/pci/slots/*; do
        [[ -e $s/address && -e $s/power && $(cat "$s/address") == "${WIFI_PCI%.*}" ]] || continue
        echo 0 > "$s/power" && { slot=$s; echo "  питание слота снято"; }
    done
    [[ -z $slot ]] && echo "  питание слота: ноутбук не даёт управлять (hotplug нет)"
    bt_gpio_set 0x0 && echo "  линия BT_EN выключена (Bluetooth-часть обесточена)"
    orig_ctl=$(cat "$rp/power/control" 2>/dev/null)
    echo auto > "$rp/power/control" 2>/dev/null && echo "  корневой порт отпущен в D3 (если BIOS умеет — обесточит)"

    echo "… держу $hold с"
    sleep 1
    echo "  порт $ROOT_PORT: $(cat $rp/power_state 2>/dev/null || cat $rp/power/runtime_status 2>/dev/null)"
    sleep $((hold>1 ? hold-1 : 0))

    echo "▲ ВКЛЮЧЕНИЕ"
    echo on > "$rp/power/control" 2>/dev/null && echo "  корневой порт разбужен"
    bt_gpio_set 0x1 && echo "  линия BT_EN включена: $(bt_gpio_get)"
    [[ -n $slot ]] && echo 1 > "$slot/power" && echo "  питание слота подано"
    if [[ -n $lc ]]; then
        setpci -s "$rps" CAP_EXP+10.w="$(printf '%04x' $((0x$lc & ~0x10)))" && echo "  линк PCIe включён"
    fi
    sleep 1
    [[ -n $pf ]] && echo 0 > "$pf" && echo "  USB-порт $port включён"
    echo 1 > /sys/bus/pci/rescan && echo "  PCI rescan"
    modprobe "$WIFI_MOD" 2>/dev/null; modprobe btusb 2>/dev/null
    [[ -n $orig_ctl ]] && echo "$orig_ctl" > "$rp/power/control" 2>/dev/null

    echo "🔍 АКТИВНЫЙ ПОИСК (до 30 с)"
    local t
    for ((t=1; t<=30; t++)); do
        if bt_usb_path >/dev/null; then
            echo "  [${t} с] Bluetooth появился на USB: $(bt_usb_path)"
            systemctl start bluetooth
            return 0
        fi
        if (( t % 3 == 0 )); then
            echo 1 > /sys/bus/pci/rescan
            if [[ -n $pf ]]; then echo 1 > "$pf"; sleep 0.5; echo 0 > "$pf"; fi
            udevadm trigger --subsystem-match=usb --action=add 2>/dev/null
            echo "  [${t} с] нет — пинаю шины (PCI rescan, перезапуск USB-порта)"
        fi
        sleep 1
    done
    echo "  за 30 с адаптер так и не появился"
    systemctl start bluetooth
    [[ -e /sys/bus/pci/devices/$WIFI_PCI ]] && echo "  (Wi‑Fi карта на PCI при этом есть)" || echo "  (Wi‑Fi карты на PCI тоже нет!)"
    return 1
}

START_TS=$(date '+%Y-%m-%d %H:%M:%S')

# ========================================================================
section "1. Система"
info "Дата:      $START_TS"
info "Ядро:      $(uname -r)"
info "Аптайм:    $(uptime -p)"
info "mem_sleep: $(cat /sys/power/mem_sleep 2>/dev/null)"
info "Модель:    $(cat /sys/class/dmi/id/sys_vendor /sys/class/dmi/id/product_name 2>/dev/null | tr '\n' ' ')"
info "BIOS:      $(cat /sys/class/dmi/id/bios_version /sys/class/dmi/id/bios_date 2>/dev/null | tr '\n' ' ')"
n_susp=$(journalctl -b -k --no-pager 2>/dev/null | grep -c 'PM: suspend entry')
info "Засыпаний с момента загрузки: $n_susp"

# ========================================================================
section "2. Железо"
if [[ -n $(lspci -s "${WIFI_PCI#0000:}" 2>/dev/null) ]]; then
    ok "PCI: $(lspci -s "${WIFI_PCI#0000:}" | cut -d' ' -f2-)"
    drv=$(basename "$(readlink -f /sys/bus/pci/devices/$WIFI_PCI/driver 2>/dev/null)" 2>/dev/null)
    info "Драйвер Wi‑Fi: ${drv:-нет}"
    info "Методы сброса PCI: $(cat /sys/bus/pci/devices/$WIFI_PCI/reset_method 2>/dev/null || echo нет)"
else
    bad "Wi‑Fi/BT карта $WIFI_PCI не найдена на шине PCI"
    note "Карта пропала с шины PCI"
fi
rp=/sys/bus/pci/devices/$ROOT_PORT
info "Корневой порт PCIe: $ROOT_PORT ($(lspci -s ${ROOT_PORT#0000:} 2>/dev/null | cut -d' ' -f2-))"
info "  power/control=$(cat $rp/power/control 2>/dev/null), power_state=$(cat $rp/power_state 2>/dev/null || echo ?), d3cold_allowed=$(cat $rp/d3cold_allowed 2>/dev/null)"
pr=$(ls -d $rp/firmware_node/power_resources_* 2>/dev/null | xargs -n1 basename 2>/dev/null | tr '\n' ' ')
if [[ -n $pr ]]; then info "  ACPI power resources: $pr (можно реально обесточить слот)"
else info "  ACPI power resources: нет (D3cold слота, скорее всего, невозможен)"; fi

info "Линия включения BT (GPIO $BT_GPIO): $(bt_gpio_get 2>&1)  (0x1 = вкл)"
if USB_PATH=$(bt_usb_path); then
    ok "USB: Bluetooth $BT_VID:$BT_PID на порту $USB_PATH"
    echo "$USB_PATH" > "$STATE_FILE"; chown "$OWNER" "$STATE_FILE" 2>/dev/null
    d=/sys/bus/usb/devices/$USB_PATH
    info "power/control:        $(cat $d/power/control 2>/dev/null)   (auto = autosuspend включён)"
    info "power/runtime_status: $(cat $d/power/runtime_status 2>/dev/null)"
    info "power/wakeup:         $(cat $d/power/wakeup 2>/dev/null)"
    info "persist:              $(cat $d/power/persist 2>/dev/null)"
    info "removable:            $(cat $d/removable 2>/dev/null)"
else
    bad "USB: Bluetooth $BT_VID:$BT_PID на шине отсутствует (ожидался порт $(known_port))"
    note "BT-адаптер отсутствует на USB-шине"
fi

# ========================================================================
section "3. Модули ядра"
for m in bluetooth btusb btrtl "$WIFI_MOD" rtw88_core rtw88_pci hp_wmi; do
    if lsmod | grep -q "^$m "; then ok "$m загружен"; else warn "$m НЕ загружен"; fi
done
p=/sys/module/btusb/parameters
[[ -r $p/enable_autosuspend ]] && info "btusb enable_autosuspend    = $(<$p/enable_autosuspend)"
[[ -r $p/reset ]]              && info "btusb reset                 = $(<$p/reset)"
[[ -r /sys/module/usbcore/parameters/autosuspend ]] && \
    info "usbcore autosuspend         = $(</sys/module/usbcore/parameters/autosuspend) с"
[[ -r /sys/module/rtw88_core/parameters/disable_lps_deep ]] && \
    info "rtw88_core disable_lps_deep = $(</sys/module/rtw88_core/parameters/disable_lps_deep)"
[[ -r /sys/module/rtw88_pci/parameters/disable_aspm ]] && \
    info "rtw88_pci disable_aspm      = $(</sys/module/rtw88_pci/parameters/disable_aspm)"
confs=$(grep -rlsE 'btusb|btrtl|rtw88|bluetooth' /etc/modprobe.d/ /usr/lib/modprobe.d/ 2>/dev/null)
if [[ -n $confs ]]; then
    info "Настройки modprobe, касающиеся BT/rtw88:"
    for f in $confs; do echo "         $f:"; grep -vE '^\s*(#|$)' "$f" | indent | indent; done
fi
hooks=$(ls /usr/lib/systemd/system-sleep/ /etc/systemd/system-sleep/ 2>/dev/null | grep -v ':$' | grep -v '^$')
info "Хуки systemd-sleep: ${hooks:-нет}"
info "Параметры ядра: $(cat /proc/cmdline)"

# ========================================================================
section "4. Прошивка"
fw=$(ls /usr/lib/firmware/rtl_bt/rtl8821c_* 2>/dev/null)
if [[ -n $fw ]]; then
    ok "Файлы прошивки найдены:"
    echo "$fw" | indent
    pkg=$(pacman -Qqo $(echo "$fw" | head -1) 2>/dev/null)
    [[ -n $pkg ]] && info "Пакет: $pkg $(pacman -Q "$pkg" 2>/dev/null | cut -d' ' -f2)"
else
    bad "Нет /usr/lib/firmware/rtl_bt/rtl8821c_* — поставь linux-firmware-realtek"
    note "Отсутствует прошивка rtl8821c"
fi
fwv=$(journalctl -b -k --no-pager 2>/dev/null | grep -o 'RTL: fw version 0x[0-9a-f]*' | tail -1)
[[ -n $fwv ]] && info "Загруженная прошивка BT: ${fwv#RTL: }"

# ========================================================================
section "5. rfkill и служба"
rfkill list 2>/dev/null | indent
if rfkill list 2>/dev/null | grep -qiE 'hp-(bluetooth|wifi)'; then
    ok "Есть rfkill-переключатели HP (hp-wmi) — BIOS может управлять питанием радио"
else
    info "rfkill-переключателей HP (hp-wmi) нет"
fi
rfkill list bluetooth 2>/dev/null | grep -q 'Soft blocked: yes' && { bad "BT soft-blocked"; note "rfkill soft block"; }
rfkill list bluetooth 2>/dev/null | grep -q 'Hard blocked: yes' && { bad "BT hard-blocked"; note "rfkill hard block"; }
if systemctl is-active --quiet bluetooth; then ok "bluetooth.service активна"
else bad "bluetooth.service не запущена"; note "bluetooth.service не активна"; fi
echo
short_state

# ========================================================================
section "6. Готовность к гибернации"
HIB_OK=1
grep -qw disk /sys/power/state && ok "Ядро поддерживает гибернацию" || { bad "/sys/power/state без disk"; HIB_OK=0; }
lock=$(cat /sys/kernel/security/lockdown 2>/dev/null | grep -o '\[[a-z]*\]')
[[ $lock == "[none]" || -z $lock ]] && info "lockdown: ${lock:-нет}" || { bad "lockdown $lock — гибернация запрещена"; HIB_OK=0; }
ram_kb=$(awk '/MemTotal/{print $2}' /proc/meminfo)
swap_kb=$(awk 'NR>1{s+=$3} END{print s+0}' /proc/swaps)
used_kb=$(awk '/MemTotal/{t=$2}/MemAvailable/{a=$2}END{print t-a}' /proc/meminfo)
info "RAM: $((ram_kb/1024)) МБ, занято ~$((used_kb/1024)) МБ, swap: $((swap_kb/1024)) МБ"
if [[ $swap_kb -eq 0 ]]; then bad "Swap нет — гибернация невозможна"; HIB_OK=0
elif [[ $swap_kb -lt $used_kb ]]; then warn "Swap меньше занятой памяти — может не хватить"; fi
awk 'NR>1{print $1" ("$2", "$3/1024" МБ)"}' /proc/swaps | indent
if grep -qw 'resume=' /proc/cmdline 2>/dev/null || grep -q 'resume=' /proc/cmdline; then
    ok "В параметрах ядра есть resume="
elif [[ -d /sys/firmware/efi ]] && grep -qE '^HOOKS=.*\bsystemd\b' /etc/mkinitcpio.conf 2>/dev/null; then
    ok "UEFI + systemd в initramfs — resume найдётся автоматически"
elif grep -qE '^HOOKS=.*\bresume\b' /etc/mkinitcpio.conf 2>/dev/null; then
    warn "Хук resume есть, но нет resume= в параметрах ядра"; HIB_OK=0
else
    bad "Не настроено восстановление из гибернации (resume)"; HIB_OK=0
fi
info "HOOKS: $(grep -E '^HOOKS=' /etc/mkinitcpio.conf 2>/dev/null || echo 'mkinitcpio.conf не найден')"

# ========================================================================
section "7. Журнал ядра (эта загрузка)"
klog=$(journalctl -b -k --no-pager -o short-iso 2>/dev/null | \
    grep -iE 'PM: (suspend|hibernation) (entry|exit)|ACPI: PM: (Waking|Preparing)|btusb|btrtl|hci0:|usb 1-[0-9.]+: (USB disconnect|new)|rtw88|rtw_8821ce|failed' | \
    grep -v 'RTL: \(examining\|rom_version\|btrtl_initialize\|loading\|cfg_sz\)' | tail -40)
if [[ -n $klog ]]; then echo "$klog" | indent; else info "Ничего подходящего"; fi

# ========================================================================
try_recover() {
    local label=$1
    section "$label: попытки оживить Bluetooth"
    if bt_alive; then ok "Bluetooth работает, чинить нечего"; return 0; fi
    if [[ $DO_FIX -eq 0 ]]; then warn "Режим --no-fix: ничего не трогаю"; return 1; fi

    local port; port=$(known_port)
    local steps
    if [[ $DO_CHIPRESET -eq 1 ]]; then steps=(
        "Передёрнуть линию включения Bluetooth BT_EN (GPIO из BIOS)|step_bt_gpio"
        "Все поддерживаемые методы сброса PCI (FLR / PM / bus)|step_reset_each_method"
        "Выключение линка PCIe на 5 с (Link Disable)|step_link_disable"
        "Снятие питания со слота через PCIe hotplug|step_slot_power"
        "Обесточивание слота PCIe (D3cold корневого порта $ROOT_PORT)|step_d3cold"
        "ПОЛНЫЙ ХОЛОДНЫЙ ЦИКЛ: всё сразу на ${HOLD_SEC} с|step_full_cycle"
    ); else steps=(
        "Перезапуск bluetooth.service|systemctl restart bluetooth"
        "Перезагрузка btusb/btrtl|modprobe -r btusb btrtl; sleep 1; modprobe btusb"
        "Передёрнуть линию включения Bluetooth BT_EN (GPIO из BIOS)|step_bt_gpio"
        "rfkill: выключить и включить ВСЕ радио (через hp-wmi BIOS может передёрнуть питание)|step_rfkill_all"
        "Сброс USB-устройства (authorized 0→1)|d=/sys/bus/usb/devices/\$(bt_usb_path) && echo 0 > \$d/authorized && sleep 1 && echo 1 > \$d/authorized"
        "Отключение питания USB-порта $port|f=\$(port_disable_file $port) && echo 1 > \$f && sleep 2 && echo 0 > \$f"
        "Перепривязка USB-контроллера xHCI|x=\$(basename \$(readlink -f /sys/bus/usb/devices/usb1/..)) && echo \$x > /sys/bus/pci/drivers/xhci_hcd/unbind && sleep 2 && echo \$x > /sys/bus/pci/drivers/xhci_hcd/bind"
        "Перезагрузка Wi‑Fi драйвера $WIFI_MOD|modprobe -r $WIFI_MOD && sleep 2 && modprobe $WIFI_MOD"
        "Удаление карты с шины PCI + rescan|echo 1 > /sys/bus/pci/devices/$WIFI_PCI/remove && sleep 2 && echo 1 > /sys/bus/pci/rescan"
        "Аппаратный сброс чипа: все методы (acpi/bus/flr/pm)|step_pci_resets"
        "Обесточивание слота PCIe (D3cold корневого порта $ROOT_PORT)|step_d3cold"
    ); fi
    local s name cmd i=0 out rc
    for s in "${steps[@]}"; do
        i=$((i+1)); name=${s%%|*}; cmd=${s#*|}
        echo; echo "  ${B}Шаг $i:${N} $name"
        if [[ $name == "Сброс USB-устройства"* ]] && ! bt_usb_path >/dev/null; then
            info "Пропуск: устройства нет на шине"; continue; fi
        if [[ $name == "Отключение питания USB-порта"* ]] && ! port_disable_file "$port" >/dev/null; then
            info "Пропуск: нет файла управления портом $port"; continue; fi
        out=$(eval "$cmd" 2>&1); rc=$?
        [[ -n $out ]] && echo "$out" | indent
        [[ $rc -ne 0 ]] && warn "Код возврата $rc"
        reload_all
        if wait_alive 10; then
            ok "Bluetooth вернулся после шага $i"
            short_state
            note "$label: помог шаг $i «$name»"
            return 0
        fi
        short_state
    done
    bad "Ни один способ не помог — нужна перезагрузка (или гибернация: --hibernate)"
    note "$label: ни один способ не помог"
    return 1
}

if [[ $DO_BTGPIO -eq 1 ]]; then
    section "Сброс Bluetooth через линию BT_EN (${HOLD_SEC} с)"
    echo "  До:"; short_state
    step_bt_gpio 2>&1 | indent
    if wait_alive 10; then ok "Bluetooth РАБОТАЕТ"; note "BT_EN: BT ВЕРНУЛСЯ"; ALIVE_NOW=0
    else bad "Bluetooth не вернулся"; note "BT_EN: BT не вернулся"; ALIVE_NOW=1; fi
    echo "  После:"; short_state
elif [[ $DO_FULLCYCLE -eq 1 ]]; then
    section "Полный холодный цикл карты (всё сразу, $HOLD_SEC с)"
    echo "  До:"; short_state
    step_full_cycle 2>&1 | indent
    reload_all
    if wait_alive 10; then ok "Bluetooth РАБОТАЕТ после полного цикла"; note "Полный цикл ($HOLD_SEC с): BT ВЕРНУЛСЯ"; ALIVE_NOW=0
    else bad "Bluetooth не вернулся"; note "Полный цикл ($HOLD_SEC с): BT не вернулся"; ALIVE_NOW=1; fi
    echo "  После:"; short_state
elif [[ $DO_CHIPRESET -eq 1 ]]; then
    section "Холодный перезапуск карты (без сна и перезагрузки)"
    if bt_alive; then
        ok "Bluetooth сейчас работает — сбрасывать нечего. Запусти этот режим, когда он пропадёт."
        ALIVE_NOW=0
    else
        try_recover "Сброс чипа"
        ALIVE_NOW=$?
    fi
else
    try_recover "8"
    ALIVE_NOW=$?
fi

# ========================================================================
if [[ $DO_SUSPEND -eq 1 ]]; then
    section "9. Тест сна"
    if [[ $ALIVE_NOW -ne 0 ]]; then
        warn "Bluetooth сейчас не работает — тест сна бессмысленен. Перезагрузись и запусти снова."
        note "Тест сна пропущен (BT не работал до теста)"
    elif ! command -v rtcwake >/dev/null; then
        bad "Нет rtcwake (пакет util-linux)"
    else
        ORIG_MODE=$(grep -o '\[[a-z0-9]*\]' /sys/power/mem_sleep | tr -d '[]')
        MODE=${SUSPEND_MODE:-$ORIG_MODE}
        [[ $MODE != "$ORIG_MODE" ]] && echo "$MODE" > /sys/power/mem_sleep
        DESC="режим $MODE${UNLOAD:+, выгрузка: $UNLOAD}"
        info "Тест: $DESC, длительность: $SLEEP_SEC с"
        echo "  До сна:"; short_state
        if [[ -n $UNLOAD ]]; then
            info "Выгружаю драйверы перед сном..."
            systemctl stop bluetooth
            modprobe -r btusb btrtl 2>&1 | indent
            [[ $UNLOAD == all ]] && modprobe -r "$WIFI_MOD" 2>&1 | indent
            sleep 1
            info "USB-устройство перед сном: $(bt_usb_path || echo нет)"
        fi
        T0=$(date '+%Y-%m-%d %H:%M:%S')
        info "Засыпаю... (ноутбук проснётся сам)"
        sync
        rtcwake -m mem -s "$SLEEP_SEC" 2>&1 | indent
        sleep 3
        info "USB-устройство сразу после пробуждения: $(bt_usb_path || echo нет)"
        reload_all
        sleep 3
        echo "  После пробуждения:"; short_state
        echo "$ORIG_MODE" > /sys/power/mem_sleep
        info "Журнал ядра за время теста:"
        journalctl -k --since "$T0" --no-pager -o short-iso 2>/dev/null | \
            grep -iE 'PM: |btusb|btrtl|hci0|Bluetooth: |usb 1-|rtw|xhci' | tail -40 | indent
        if wait_alive 10; then
            ok "Bluetooth ПЕРЕЖИЛ сон ($DESC)"
            note "Тест сна ($DESC): BT ВЫЖИЛ"
        else
            bad "Bluetooth НЕ пережил сон ($DESC)"
            note "Тест сна ($DESC): BT пропал"
            try_recover "10"
        fi
    fi
fi

# ========================================================================
if [[ $DO_HIBERNATE -eq 1 ]]; then
    section "11. Гибернация"
    if [[ $HIB_OK -ne 1 ]]; then
        bad "Система не готова к гибернации (см. раздел 6) — пропускаю, чтобы не потерять сессию"
        note "Гибернация пропущена: не настроена"
    else
        warn "Ноутбук сохранит память на диск и ПОЛНОСТЬЮ выключится."
        warn "После этого включи его кнопкой питания — сессия должна восстановиться."
        warn "Сохрани открытые документы на всякий случай."
        read -r -p "  Продолжить? [y/N] " ans </dev/tty
        if [[ $ans == [yYдД]* ]]; then
            T0=$(date '+%Y-%m-%d %H:%M:%S')
            sync
            systemctl hibernate
            info "Жду возвращения из гибернации..."
            for ((i=0; i<900; i++)); do
                journalctl -k --since "$T0" --no-pager 2>/dev/null | grep -q 'PM: hibernation: hibernation exit\|PM: hibernation exit\|PM: restore exit' && break
                sleep 2
            done
            sleep 5; reload_all
            echo "  После гибернации:"; short_state
            if wait_alive 15; then ok "Гибернация вернула Bluetooth"; note "Гибернация: BT ВЕРНУЛСЯ"
            else bad "Гибернация не помогла"; note "Гибернация: BT не вернулся"; fi
        else
            info "Отменено"
        fi
    fi
fi

# ========================================================================
section "ИТОГ"
short_state
for s in "${SUMMARY[@]}"; do echo "  • $s"; done
[[ ${#SUMMARY[@]} -eq 0 ]] && echo "  • Замечаний нет"
echo
echo "  Полный лог: $LOG"
chown -R "$OWNER" "$LOG_DIR" 2>/dev/null
