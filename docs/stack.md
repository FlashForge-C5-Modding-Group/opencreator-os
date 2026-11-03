# The printer stack

The printer software (Kalico, Moonraker, GrumpyScreen, nginx and a web
interface) ships on the install stick. The installer copies it to `c5os`,
and OpenWrt installs it offline on its next committed boot.

> **Prerequisite:** all four boards (`eBoard`, `heaterBoard`, `levelBoard`,
> `mainBoardGD`) must already run matching Kalico firmware. OpenWrt does not
> flash MCUs yet; with stock MCU firmware Klippy cannot connect.

## On the stick

`tools/make-install-stick.sh --stack DIR` adds `stack/stack.tar.gz`,
`stack/fluidd.tar.gz` and `stack/mainsail.tar.gz` (from
`tools/make-stack.sh`) and lists them in `SHA256SUMS`/`MD5SUMS`. Without
`--stack` the stick installs OpenWrt only. A stick that has `stack/stack.tar.gz`
but lacks one of the other archives, or a checksum entry, is refused before
anything is written.

The web interface:

- With the touchscreen app, the installer asks **Fluidd** or **Mainsail**.
- Headless, the optional `opencreator-os/WEBUI` holds `fluidd` or `mainsail`
  (CR, LF and spaces are ignored; anything else is refused). Without it,
  Fluidd. Like `ACTION`, it is not in the checksum lists.

Only the chosen interface is copied. To switch, plant again from a stick.

## Planting

On stock, Install asks for the web interface before the backup question,
then copies the stack after saving stock's settings. On OpenWrt,
**Update / Repair OpenWrt** asks and copies before sysupgrade. Either way
the copy is checksummed against the stick's list.

The stock install also copies `extruder.json`, `zoffset.json` and
`test.json` from `/usr/data/firmwareRes/config/` to `c5os` (`calibration/`).

Planting is skipped when exactly this stack and web interface are already
installed (`stack.installed`) and nothing is pending. Every plant clears
`stack.tries` and `stack.failed`, so a failed setup retries.

## On c5os

`/data/opencreator-os/` (the installer's `$OCDIR` on `c5os`):

| Path | Meaning |
|---|---|
| `stack/` | The planted payload: `stack.tar.gz`, `<webui>.tar.gz`, `SHA256SUMS` or `MD5SUMS` (two lines, `"<digest>  stack.tar.gz"` and `"<digest>  <webui>.tar.gz"`), `webui`, and `pending`, written last. |
| `stack.new/` | A plant in progress. |
| `stack.installed` | The key of the installed stack: `SHA256SUMS` or `MD5SUMS`, then the two lines of the planted checksum file. |
| `stack.tries` | Setup attempts so far. |
| `stack.failed` | The last failure reason, after the third failed attempt. |
| `calibration/` | Stock's `extruder.json`, `zoffset.json`, `test.json`. |
| `logs/stack.log` | The setup log, including the stack's `install.sh` output. |

## Setup

`c5-booted` runs `/usr/libexec/c5-stack-setup` on a committed boot (a
fresh install's test boot counts once `c5-booted` has committed it), before
the USB hook it deferred. A stick's **OpenWrt installed** therefore appears
after the stack is in place. A test boot that is not committed, or a
`c5.nocommit` boot, does not run it.

The setup does nothing unless `/data` is mounted and `stack/pending`
exists. It takes `/tmp/c5-stack.lock` (an OpenWrt installer planting waits
for it), then:

1. Puts back `/data/printer.old` if an earlier run was interrupted, and
   removes `/data/printer.new`.
2. Counts the attempt in `stack.tries` before making it, so a setup that
   crashes the printer still ends.
3. Checks the planted archives against their checksums and the web
   interface choice.
4. Unpacks `stack.tar.gz` into `/data/printer.new`, the web interface into
   its `www/`, and records `webui`.
5. Moves `/data/printer` to `/data/printer.old` and `printer.new` into place.
6. Runs the stack's `install.sh` (below), killing it after 600 s.
7. Restarts the services, removes `printer.old`, writes `stack.installed`,
   clears `stack.tries`/`stack.failed`, and removes `stack/`.

A failure after step 5 removes the new tree, moves `printer.old` back and
restarts the services; before it, only `printer.new` is removed. After the
third failed attempt the setup writes the reason to `stack.failed` and
removes `stack/pending`; it stops retrying until a stick plants again. Each
failure and the final install are also in the boot log (`c5: stack: ...`).

## The stack in /data/printer

`/data/printer` is replaced as a whole by every install and never holds
user data:

| Path | Contents |
|---|---|
| `install.sh` | The stack's installer. |
| `VERSION` | `stack <opencreator-os git describe>`, then `kalico <sha>`, `moonraker <sha>`, `opencreator-fs <sha>`. |
| `webui` | `fluidd` or `mainsail`. |
| `www/` | The web interface; `index.html` at its top. |
| `bin/` | `env.sh` and the launchers `klipper`, `moonraker`, `nginx`, `grumpyscreen`, `mcu-wake`, `python3`. |
| `root/` | The OpenWrt packages the stack needs: Python, nginx, `stty`, ... |
| `klipper/` | Kalico: `klippy/` with a prebuilt `chelper/c_helper.so`, and `scripts/`. |
| `moonraker/` | Moonraker: the `moonraker/` package and `LICENSE`. |
| `grumpyscreen/grumpyscreen` | GrumpyScreen (static). |
| `opencreator/` | `mcu-wake.sh` and `shaper_graph.py`. |
| `etc/nginx.conf` | nginx's configuration. |
| `defaults/config/` | The default Klipper configuration, `moonraker.conf` and `grumpyscreen.cfg`. |

User data lives in `/data/printer_data/` (`config`, `logs`, `gcodes`,
`database`, `comms`, `misc`, `tmp`, `nginx`) and
`/data/printer_data/moonraker.asvc`.

The stack's `install.sh` is called as

```sh
C5_MODEL_FILE=/data/opencreator-os/model C5_CALIBRATION_DIR=/data/opencreator-os/calibration \
	C5_PRINTER_DATA=/data/printer_data sh /data/printer/install.sh /data/printer
```

It must be idempotent, write only under those two directories, start or
stop no services, finish within 600 s and exit 0 on success.
