**English** | [Русский](README.ru.md)

# Bluetooth disappears after suspend — HP Laptop 15s-fq1xxx + Realtek RTL8821CE

<a id="warning"></a>

> [!CAUTION]
> **Read this before running anything.**
>
> - This fix was found and verified on **one machine only**: HP 15s-fq1120ur (SKU `286V9EA`),
>   DMI board **`86C9`**, BIOS **F.30**, running **Arch Linux** with the **linux-zen** kernel
>   (7.2.11-zen1) and **systemd**. Other distributions and kernels were not tested. The number `0x06010012` is a GPIO pad of the Intel chipset
>   taken from *this* BIOS. On another model or another BIOS version the same number may point to a
>   **different pin** (touchpad, display, power rails, anything). Writing to the wrong pin can make
>   hardware stop working until reboot, and in the worst case can do things nobody can predict.
> - **Check your model first** (step 0 below). If board, product name or BIOS differ, do **not**
>   write anything. See [Other laptops](#other-laptops-finding-your-own-pin) to find your own pin
>   in your own ACPI tables.
> - **Read before you write.** The read command must return exactly `0x0` or `0x1`. Any other
>   answer (an error, `not called`, a big number) means the pin or method does not exist on your
>   machine: stop there.
> - The hook is a **systemd-sleep** hook. On distributions without systemd (OpenRC, runit, s6, ...)
>   it will not run as is; you would have to call the same command from your own resume hook.
> - `acpi_call` lets root call **any** ACPI method. It is a powerful debugging tool, not a
>   polished driver. A typo in a method name or argument goes straight to the firmware.
> - `acpi_call` is an out-of-tree, unsigned module: it taints the kernel, and with Secure Boot /
>   enforced module signatures it may refuse to load. That is expected, not a bug of this fix.
> - Nothing here writes to the BIOS, flash or NVRAM. The pin state lives only until the next
>   reboot or suspend. **To undo everything: delete the hook file and reboot.**
> - Not affiliated with HP or Realtek. No warranty, use at your own risk ([MIT](LICENSE)).

A fix for Linux: the Bluetooth part of the Realtek **RTL8821CE** Wi‑Fi/Bluetooth combo card
vanishes after suspend-to-RAM (S3, `deep`) on **HP Laptop 15s-fq1xxx** (tested on
**15s-fq1120ur**) and does not come back until a reboot.

**Root cause:** on resume from S3 the BIOS does not re-enable the Bluetooth enable line
(GPIO pad `0x06010012`, `W_DISABLE2#`/BT_EN on the M.2 slot). The Bluetooth half of the chip
stays hardware-disabled and drops off the USB bus.
**Fix:** a `systemd-sleep` hook that raises that line again after resume, using the BIOS's own
ACPI methods via `acpi_call`.

## Manual fix (raw commands, no scripts)

Every step is one command you can read and understand. Commands work in bash, zsh and fish.

**0. Check that this is the same machine.** Expected: `HP Laptop 15s-fq1xxx`, `86C9`, `F.30`.

```bash
cat /sys/class/dmi/id/product_name /sys/class/dmi/id/board_name /sys/class/dmi/id/bios_version
```

**1. Check that you have this exact bug** (after a suspend/resume, Bluetooth gone):

```bash
lsusb | grep 0bda:b00a                     # empty = Bluetooth adapter is gone from USB
sudo journalctl -k -b | grep 'usb 1-10'          # look for "USB disconnect" right after "Waking up from system sleep state S3"
```

**2. Install and load `acpi_call`:**

```bash
sudo pacman -S acpi_call-dkms               # tested: Arch Linux + linux-zen (DKMS needs linux-zen-headers)
                                            # stock "linux" kernel: acpi_call; other distros: acpi-call-dkms (untested)
sudo modprobe acpi_call
```

**3. Read the Bluetooth enable pin (read-only, safe):**

```bash
echo '\_SB.GGOV 0x06010012' | sudo tee /proc/acpi/call
sudo cat /proc/acpi/call; echo
```

`0x0` = Bluetooth is switched off by hardware (this bug). `0x1` = switched on.
**Anything else: stop here.**

**4. Switch Bluetooth back on (only if step 3 printed `0x0`):**

```bash
echo '\_SB.SGOV 0x06010012 0x1' | sudo tee /proc/acpi/call
```

Within 1–2 seconds:

```bash
lsusb | grep 0bda:b00a                     # adapter is back
bluetoothctl show                          # controller is back
```

**5. Make it automatic after every resume.** Create the file
`/usr/lib/systemd/system-sleep/bt-en-resume` with any editor (`sudo nano ...`) and paste:

```sh
#!/bin/sh
# /usr/lib/systemd/system-sleep/bt-en-resume
# HP Laptop 15s-fq1xxx (board 86C9, BIOS F.30) + Realtek RTL8821CE.
# After resume from S3 the BIOS leaves the Bluetooth enable line (GPIO pad 0x06010012) low,
# so the Bluetooth half of the chip stays off. This hook raises it again.
# Requires the acpi_call kernel module.

[ "$1" = "post" ] || exit 0
modprobe acpi_call 2>/dev/null
[ -w /proc/acpi/call ] || { logger -t bt-en-resume "no /proc/acpi/call (acpi_call not loaded)"; exit 0; }

printf '%s' '\_SB.GGOV 0x06010012' > /proc/acpi/call
state=$(tr -d '\0' < /proc/acpi/call)

case "$state" in
    0x1) logger -t bt-en-resume "BT_EN already 0x1, nothing to do" ;;
    0x0) printf '%s' '\_SB.SGOV 0x06010012 0x1' > /proc/acpi/call
         logger -t bt-en-resume "BT_EN was 0x0, set to 0x1" ;;
    *)   logger -t bt-en-resume "unexpected answer '$state', not touching anything" ;;
esac
exit 0
```

Then make it executable:

```bash
sudo chmod 755 /usr/lib/systemd/system-sleep/bt-en-resume
```

**6. Test:** suspend, wake up, then:

```bash
bluetoothctl show
sudo journalctl -b -t bt-en-resume         # expect: "BT_EN was 0x0, set to 0x1"
```

**Undo:**

```bash
sudo rm /usr/lib/systemd/system-sleep/bt-en-resume
```

and reboot. Nothing else was changed.

## Contents

- [⚠️ Warning](#warning) · [Manual fix (raw commands)](#manual-fix-raw-commands-no-scripts)
- [Symptoms](#symptoms)
- [Affected hardware](#affected-hardware)
- [Automatic installation](#automatic-installation-script)
- [Kernel module (recommended)](#kernel-module-recommended-no-gpio-number-at-all)
- [Test results](#test-results)
- [How it works](#how-it-works)
- [Why the usual fixes don't work](#why-the-usual-fixes-dont-work)
- [Diagnostic script](#diagnostic-script)
- [Other laptops: finding your own pin](#other-laptops-finding-your-own-pin)
- [Uninstall](#uninstall)
- [Caveats](#caveats)

## Symptoms

After waking from sleep:

```
$ bluetoothctl show
No default controller available

$ lsusb | grep 0bda:b00a
(nothing)

$ journalctl -k
ACPI: PM: Waking up from system sleep state S3
usb 1-10: USB disconnect, device number 3
```

- Wi‑Fi keeps working; only Bluetooth is gone.
- `rfkill` shows no Bluetooth device at all (not "blocked", just absent).
- Restarting `bluetooth.service`, reloading `btusb`, resetting USB or PCI: nothing helps.
- A reboot fixes it until the next suspend.
- Suspend mode in `/sys/power/mem_sleep` is `[deep]`.

## Affected hardware

| | Family | Exact model (tested) |
|---|---|---|
| Laptop | HP Laptop 15s-fq1xxx (Intel Ice Lake, 10th gen), DMI board `86C9`, family `103C_5335KV HP Notebook` | **HP 15s-fq1120ur**, SKU `286V9EA#ACB`, BIOS **F.30** (07/04/2023) |
| Adapter | Realtek RTL8821C, Linux driver `rtw88` | **RTL8821CE**: Wi‑Fi 5 802.11ac 1x1 over PCIe (`10ec:c821`, subsystem `103c:831a`) + Bluetooth 4.2 over internal USB (`0bda:b00a`) |

Verified on a real suspend/resume cycle: after `usb 1-10: USB disconnect` the adapter re-enumerates in the same second.
Tested on **Arch Linux** with the **linux-zen** kernel `7.2.11-zen1` and **systemd**, `linux-firmware-realtek 20260916`,
Bluetooth firmware `0x75b8f098`. Not tested on other distributions, kernels or init systems.

Other HP 15s / 14s / 250 G8 models with the same board design are likely affected too, but the GPIO
pin may differ. See [Other laptops](#other-laptops-finding-your-own-pin) before installing.

## Automatic installation (script)

Same as the manual fix above, plus checks. Read the warning at the top first.

1. Install the `acpi_call` kernel module:

   ```bash
   sudo pacman -S acpi_call        # stock "linux" kernel
   sudo pacman -S acpi_call-dkms   # linux-zen, linux-lts, custom kernels
   ```

   On other distributions the package is usually called `acpi-call-dkms`.

2. Clone and install:

   ```bash
   git clone https://github.com/k0kfjjfkdjf/hp-laptop-15s-fq1xxx-fq1120ur-icelake-realtek-rtl8821c-rtl8821ce-bluetooth-after-suspend-fix.git
   cd hp-laptop-15s-fq1xxx-fq1120ur-icelake-realtek-rtl8821c-rtl8821ce-bluetooth-after-suspend-fix
   sudo ./install.sh
   ```

   The installer checks the laptop model, checks that `acpi_call` works and that the pin reads back
   a sane value, then copies the hook to `/usr/lib/systemd/system-sleep/bt-en-resume`.

   Optional: `sudo ./install.sh --rtw88-tweaks` also disables power saving in the Wi‑Fi driver
   (`disable_lps_deep`, `disable_aspm`) and USB autosuspend for `btusb`. This is **not needed** for
   the Bluetooth fix, but it cures the `rtw88_8821ce: firmware failed to leave lps state`
   errors many people get with this card.

3. Test:

   ```bash
   systemctl suspend
   # wake the laptop, then:
   bluetoothctl show
   sudo journalctl -b -t bt-en-resume
   ```

   You should see `BT_EN was 0x0, set to 0x1` in the journal and a
   working controller.

## Kernel module (recommended): no GPIO number at all

> [!NOTE]
> **Verified on hardware** (HP 15s-fq1120ur, board 86C9, BIOS F.30, Arch Linux, linux-zen 7.2.11, systemd):
> after a reboot the btfix module is loaded automatically, and after S3 resume it logs
> `btfix: radios re-enabled by BIOS _STA after resume (0xf)`; Bluetooth comes back with no
> `acpi_call` and no hook. Bluetooth headphones reconnect normally.
>
> Also run on an HP Victus 16-e0xxx (AMD, RTL8852AE) that does not have the bug: no side effects, see
> [Test results](#test-results).
>
> On other HP models it should work the same way (it calls the BIOS's own method instead of a
> hard-coded pin), but that has not been tested. If it does not help on your model, the
> `acpi_call` hook below remains as a fallback.

Instead of hard-coding the pin, this is a modified copy of the kernel's own
`drivers/platform/x86/wireless-hotkey.c` (Linux v7.2), the driver that already binds to HP's
wireless device `HPQ6001`. The only addition: after every resume it calls **`\_SB.WLBT._STA`**
again, the same BIOS method that switches the radios on at boot. The BIOS then raises the right
GPIO pads itself, whatever their numbers are on a given model. Nothing to look up, nothing to
configure.

- Acts only on `HPQ6001` (HP). On AMD/Xiaomi/LG devices handled by the same driver it behaves
  exactly like the stock one.
- Module parameter `resume_fix` (default `Y`): `echo N | sudo tee /sys/module/wireless_hotkey/parameters/resume_fix` turns it off.
- Side effect: `_STA` switches **both** radios on, so if airplane mode was on before suspend, the
  radios come back on after resume (same as after a reboot).
- Installed via DKMS into `updates/dkms`, so it takes priority over the in-kernel module and is
  rebuilt automatically for new kernels.
- Logs to the kernel log: `sudo journalctl -k -b | grep btfix`.

### `btfix`: switch between the stock driver, the module and the hook

`btfix` is a text menu that shows what is active right now (which `wireless-hotkey` is on disk
and in memory, whether the hook is installed) and lets you switch:

```bash
sudo ./btfix --install-command   # once: installs the "btfix" command into /usr/local/bin
btfix                            # menu (asks for sudo itself)
btfix status                     # status only
```

Menu: 1) enable the btfix module · 2) back to the stock in-kernel `wireless-hotkey` ·
3) install/remove the `acpi_call` hook · 4) apply now without reboot · 5) reboot ·
6) show this boot's fix log.

Quick start:

```bash
git clone https://github.com/k0kfjjfkdjf/hp-laptop-15s-fq1xxx-fq1120ur-icelake-realtek-rtl8821c-rtl8821ce-bluetooth-after-suspend-fix.git
cd hp-laptop-15s-fq1xxx-fq1120ur-icelake-realtek-rtl8821c-rtl8821ce-bluetooth-after-suspend-fix
sudo ./btfix --install-command
btfix          # 1) enable the btfix module, then 5) reboot
```

After a suspend/resume, `sudo journalctl -b -k | grep btfix` should show the `re-enabled` line.
If you also keep the `acpi_call` hook as a safety net, the hook will log `BT_EN already 0x1,
nothing to do`, which means the module already did the job.

## Test results

| | HP 15s-fq1120ur | HP Victus 16-e0xxx (AMD) |
|---|---|---|
| DMI board / BIOS | `86C9` / F.30 | `88EB` / F.18 |
| CPU / platform | Intel Ice Lake (10th gen) | AMD Ryzen 5 5600H "Cezanne" (Radeon Vega iGPU) + NVIDIA GTX 1650 Mobile |
| Wi‑Fi / Bluetooth | Realtek RTL8821CE (`10ec:c821`, `rtw88`) / USB `0bda:b00a` | Realtek RTL8852AE (`10ec:8852`, `rtw89`) / USB `0bda:2852` |
| `HPQ6001` present | yes | yes |
| Sleep mode | S3 (`deep`) | S3 (`deep`) |
| Kernel | linux-zen 7.2.11, Arch Linux, systemd | linux-zen 7.2.14, Arch Linux, systemd |
| Bluetooth after S3, **no fix** | **lost** (`usb 1-10: USB disconnect`) | kept, no USB disconnect |
| Bluetooth after S3, **btfix module** | **restored** (`radios re-enabled ... (0xf)`) | kept; Wi‑Fi and Bluetooth both fine (`radios re-enabled ... (0xf)`) |
| Verdict | bug present, module fixes it | no bug; module is harmless |

What this shows: the bug is in the BIOS of specific HP models, not in Realtek chips or Linux.
The Victus BIOS re-enables Bluetooth on resume by itself; the HP 15s-fq1xxx BIOS does not.
Re-running the BIOS's own `WLBT._STA` on a machine that does not need it changes nothing.

Test procedure: `resume_fix=N` → S3 suspend/resume → check `lsusb`/`bluetoothctl show` and the
kernel log; then `resume_fix=Y` → S3 again → check again.

## How it works

### The card is two devices

The RTL8821CE is an M.2 card with two independent functions inside one chip, each connected to
the chipset by its own path:

```
              Intel Ice Lake PCH                         RTL8821CE (M.2 card)
   ┌────────────────────────────────────┐         ┌───────────────────────────────┐
   │ PCIe root port 00:1c.0  ───────────┼────────►│ Wi‑Fi     PCIe 01:00.0        │
   │                                    │         │           driver rtw88_8821ce │
   │ xHCI USB 00:14.0, port 1-10  ──────┼────────►│ Bluetooth USB 0bda:b00a       │
   │                                    │         │           driver btusb+btrtl  │
   │ GPIO pad 0x06010012 (BT_EN)  ──────┼────────►│ W_DISABLE2#: Bluetooth on/off │
   └────────────────────────────────────┘         └───────────────────────────────┘
```

The third wire is the important one. M.2 cards have a "disable Bluetooth" input pin. When the
line is low, the Bluetooth part of the chip is held off: it does not even show up on USB. When
it is high, Bluetooth powers up, enumerates on USB port `1-10`, `btusb` loads the firmware and
`hci0` appears.

### Who controls that wire

The BIOS describes its hardware to the OS in ACPI tables (DSDT/SSDT). Decompiling the DSDT of
this laptop (`iasl -d DSDT.dat`) shows two helper methods, `\_SB.GGOV` (get GPIO output value)
and `\_SB.SGOV` (set GPIO output value), and three places that touch pad `0x06010012`:

**1. At boot**, HP's wireless device `\_SB.WLBT` (`HPQ6001`) switches Bluetooth on:

```asl
Device (WLBT)
{
    Name (_HID, EisaId ("HPQ6001"))
    Method (_STA, 0, NotSerialized)
    {
        ...
        If (((BTDS == One) || (CCDS == One)))
        {
            SGOV (0x06010012, One)      // Bluetooth ON
        }
```

**2. On the airplane-mode key**, the embedded-controller handler toggles both radios:

```asl
If (((WBTS == One) & (BTDS == One)))
{
    SGOV (0x06010012, Local0)           // Bluetooth on/off together with Wi‑Fi
}
```

**3. On resume from S3: nowhere.** Neither `_WAK` nor any other resume path writes this pad.

### What happens during sleep

In S3 (`deep`) almost the whole platform loses power, including the chipset's GPIO
configuration. On wake-up the pad comes back in its default state, **low**. The BIOS restores a
lot of things but not this pin, and `WLBT._STA` is only evaluated at boot. So:

1. The Bluetooth enable line is low after resume.
2. The Bluetooth half of RTL8821CE stays hardware-disabled.
3. It drops off the USB bus (`usb 1-10: USB disconnect`) and never re-appears.
4. Wi‑Fi sits on a different path (PCIe) and comes back fine.

You can see it directly: after a failed resume
`echo '\_SB.GGOV 0x06010012' > /proc/acpi/call; cat /proc/acpi/call` returns `0x0`.

### What the fix does

`acpi_call` is a kernel module that lets root call any ACPI method. The hook
`/usr/lib/systemd/system-sleep/bt-en-resume` runs after every resume (`$1 = post`) and:

1. reads the pin with `\_SB.GGOV 0x06010012`;
2. if it is not `0x1`, calls `\_SB.SGOV 0x06010012 0x1`, which is exactly what the BIOS itself does at boot;
3. logs the result to the journal (`sudo journalctl -b -t bt-en-resume`).

About one second later the adapter enumerates on USB and Bluetooth works as after a cold boot.
Suspend stays in `deep` mode, so there is no extra battery drain.

## Why the usual fixes don't work

Everything below was tested on this machine with Bluetooth in the broken state. All of it acts
on the buses or on Wi‑Fi, never on the BT_EN line, so the Bluetooth part stays switched off.

| Attempt | Result |
|---|---|
| `systemctl restart bluetooth` | no controller |
| `modprobe -r btusb && modprobe btusb` | nothing to bind to: no USB device |
| `btusb enable_autosuspend=n`, `rtw88_core disable_lps_deep=y`, `rtw88_pci disable_aspm=y` | fixes Wi‑Fi LPS errors, Bluetooth still lost |
| Power-cycling USB port `1-10` (`usb1-port10/disable`) | nothing on the port |
| Unbinding/rebinding the xHCI controller | all other USB devices return, Bluetooth doesn't |
| Reloading `rtw88_8821ce` | Wi‑Fi resets, Bluetooth doesn't |
| PCI `remove` + `rescan` of the card | Wi‑Fi resets, Bluetooth doesn't |
| PCIe Secondary Bus Reset, PCIe Link Disable | same |
| D3cold of the root port | impossible: no ACPI power resources on this platform, port only reaches D3hot |
| **`\_SB.SGOV 0x06010012` 0 → 1** | **Bluetooth back in 1 second** |

Related upstream reports: Realtek shipped a firmware update for "8821C BT broken after S3" in 2020
([Ubuntu SRU](https://lists.ubuntu.com/archives/kernel-team/2020-October/114229.html),
[LP#1901129](https://answers.launchpad.net/bugs/1901129)), and there is a similar
[kernel bug for RTL8822CE](https://bugzilla.kernel.org/show_bug.cgi?id=210141). On this HP the
firmware is already current, and the problem is in the BIOS, not in the chip.

## Diagnostic script

`bt-diag.sh` is the step-by-step diagnostic used to find this bug. Its output is in Russian;
it re-runs itself with `sudo` and saves a log to `logs/`.

```bash
./bt-diag.sh                      # full diagnostics + try every recovery method in order
./bt-diag.sh --no-fix             # diagnostics only
./bt-diag.sh --suspend            # real suspend test via rtcwake (wakes itself after 20 s)
./bt-diag.sh --suspend s2idle     # same, temporarily in s2idle mode
./bt-diag.sh --suspend --unload all   # unload drivers before sleeping
./bt-diag.sh --bt-gpio [sec]      # pull BT_EN low for N seconds, then high (the fix, by hand)
./bt-diag.sh --chip-reset         # hardware resets of the card: PCI reset, link disable, slot power
./bt-diag.sh --full-cycle [sec]   # everything at once: drivers out, card removed, USB port, PCIe link
                                  #   and BT_EN off for N seconds, then back on and actively rescan
./bt-diag.sh --hibernate          # hibernation test (only if resume is configured)
```

It checks: DMI model and BIOS, PCI and USB presence, USB power settings, loaded modules and
their parameters, `modprobe.d` options, sleep hooks, Bluetooth firmware, rfkill, the BT_EN pin,
hibernation readiness and the kernel log around suspend/resume.

## Other laptops: finding your own pin

If you have a different laptop with the same symptom (combo card, Bluetooth vanishes after
S3, nothing short of reboot helps), the cause may be the same, but the pin number will differ.

> ⚠️ Writing to an arbitrary GPIO pad can switch off other hardware or confuse the platform.
> Only use a pad that your own DSDT clearly uses for Bluetooth.

1. Dump and decompile the ACPI tables:

   ```bash
   sudo pacman -S acpica
   mkdir acpi && cd acpi
   for t in /sys/firmware/acpi/tables/DSDT /sys/firmware/acpi/tables/SSDT*; do
       sudo cat "$t" > "$(basename "$t").dat"
   done
   iasl -d *.dat
   ```

2. Look for the code that switches Bluetooth:

   ```bash
   grep -n 'Device (WLBT)' -A40 *.dsl     # HP wireless device: SGOV calls inside _STA
   grep -n 'BTRK\|GBTR\|BTDS\|WBTS' *.dsl  # Intel reference BT RF-kill and HP BT flags
   ```

   On HP machines the pad used together with `BTDS`/`WBTS` is the Bluetooth enable. On many
   Intel reference designs there is also a `\_SB.BTRK` method (writes pad `GBTK`).
   *Note:* on this laptop `BTRK` exists but is not what HP uses.

3. Check the value after a failed resume, then switch it on:

   ```bash
   sudo modprobe acpi_call
   echo '\_SB.GGOV 0xYOURPAD' | sudo tee /proc/acpi/call; sudo cat /proc/acpi/call
   echo '\_SB.SGOV 0xYOURPAD 0x1' | sudo tee /proc/acpi/call
   ```

4. If Bluetooth comes back, change `0x06010012` in `bt-en-resume` and `install.sh` to your pad.

## Uninstall

```bash
sudo ./uninstall.sh
```

This removes the hook and `/etc/modprobe.d/rtl8821ce-fix.conf` (if `--rtw88-tweaks` was used).

## Caveats

- The fix depends on `acpi_call`. If the module is missing (removed package, DKMS failed to build
  for a new kernel), the hook does nothing and logs `no /proc/acpi/call`.
- The pin number comes from BIOS **F.30**. After a BIOS update, check that `./bt-diag.sh --no-fix`
  still shows the BT_EN line and a sane value (`0x1` while Bluetooth works).
- Untested alternatives: `s2idle` instead of `deep` (`mem_sleep_default=s2idle`) should avoid the
  BIOS resume path but drains more battery while sleeping. Pressing the airplane-mode key twice
  after resume should also bring Bluetooth back, because the BIOS toggles the same pin.

## License

[MIT](LICENSE)
