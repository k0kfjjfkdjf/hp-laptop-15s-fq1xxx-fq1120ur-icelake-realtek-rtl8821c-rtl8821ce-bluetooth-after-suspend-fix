#!/usr/bin/env bash
# Removes everything install.sh added. / Удаляет всё, что поставил install.sh.
set -eu
[[ $EUID -eq 0 ]] || { echo "Run as root: sudo $0"; exit 1; }
for f in /usr/lib/systemd/system-sleep/bt-en-resume /etc/modprobe.d/rtl8821ce-fix.conf; do
    [[ -e $f ]] && rm -v "$f"
done
echo "Done."
