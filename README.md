**English** | [Русский](README.ru.md)

# Bluetooth disappears after suspend — HP Laptop 15s-fq1xxx + Realtek RTL8821CE

A fix for Linux: the Bluetooth part of the Realtek **RTL8821CE** Wi‑Fi/Bluetooth combo card
vanishes after suspend-to-RAM (S3, `deep`) on **HP Laptop 15s-fq1xxx** (tested on
**15s-fq1120ur**) and does not come back until a reboot.

**Root cause:** on resume from S3 the BIOS does not re-enable the Bluetooth enable line
(GPIO pad `0x06010012`, `W_DISABLE2#`/BT_EN on the M.2 slot). The Bluetooth half of the chip
stays hardware-disabled and drops off the USB bus.
**Fix:** a `systemd-sleep` hook that raises that line again after resume, using the BIOS's own
ACPI methods via `acpi_call`.

## Contents

- [Symptoms](#symptoms)
- [Affected hardware](#affected-hardware)
- [Installation](#installation)
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

Tested with kernel `7.2.11-zen1`, `linux-firmware-realtek 20260916`, Bluetooth firmware `0x75b8f098`, Arch Linux.

Other HP 15s / 14s / 250 G8 models with the same board design are likely affected too, but the GPIO
pin may differ. See [Other laptops](#other-laptops-finding-your-own-pin) before installing.

## Installation

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
   journalctl -t bt-en-resume
   ```

   You should see `BT_EN был 0x0, включил` ("BT_EN was 0x0, turned it on") in the journal and a
   working controller.

Manual one-off recovery without installing anything (when Bluetooth is already gone):

```bash
sudo modprobe acpi_call
echo '\_SB.SGOV 0x06010012 0x1' | sudo tee /proc/acpi/call
```

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
3. logs the result to the journal (`journalctl -t bt-en-resume`).

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
  for a new kernel), the hook does nothing and logs `нет /proc/acpi/call` ("no /proc/acpi/call").
- The pin number comes from BIOS **F.30**. After a BIOS update, check that `./bt-diag.sh --no-fix`
  still shows the BT_EN line and a sane value (`0x1` while Bluetooth works).
- Untested alternatives: `s2idle` instead of `deep` (`mem_sleep_default=s2idle`) should avoid the
  BIOS resume path but drains more battery while sleeping. Pressing the airplane-mode key twice
  after resume should also bring Bluetooth back, because the BIOS toggles the same pin.

## License

[MIT](LICENSE)
