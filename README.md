# Dynamic fan control — 170HX GPU blowers

Drives the four 170HX GPU blowers (ARCTIC hub on `CHA_FAN1`) from the hottest HBM
reading across the cards, via the ITE IT8665E Super I/O (`pwm2`).

## Why it87 — and what's hardware-specific

The four blowers hang off a **motherboard** header (`CHA_FAN1` via the ARCTIC hub) —
nothing on the GPU side (`nvidia-smi`) can drive it. The header is wired to the board's
Super I/O chip, an ITE IT8665E on this ASUS X399-A. Controlling it from Linux needs a
driver that exposes its PWM as hwmon; the stock in-tree `it87` driver does **not** bind
the IT8665E at its `0x290` address, so we DKMS-build the frankcrawford fork that does.
The payoff over the BIOS Q-Fan curve: the loop keys off the hottest **GPU HBM**
temperature, which the BIOS cannot see.

Portability, layer by layer:

- **Works anywhere**: `gpu-temp-log.sh` (any Linux + NVIDIA box; fan columns stay empty
  without an `it8665` hwmon, slots fall back to `unknown`) and `gpu-temp-prune.*` (pure
  file retention).
- **Works on boards whose Super I/O is an ITE IT86xx** (in-tree driver or fork):
  `gpu-fan-curve.py`, given the right pwm index — that's the `pwmN` CLI arg, per board.
- **Other Super I/O vendors** (Nuvoton/Fintek/...): `resolve()` never matches — the
  script idles safely and the BIOS curve keeps control. No harm, no control. The
  modprobe.d + DKMS pieces should not be installed on such boards.
- **GPU-count trap**: <4 GPU temperature readings (or an unsupported memory-temperature
  query) → fail-safe pins the fans at 100% duty permanently. Retune `LO/HI`, `T_LO/T_HI`
  and the `nvidia-smi` query for other fleets.

Layer-by-layer:

| Layer | This rig | Portability |
|---|---|---|
| Chip binding | IT8665E @ 0x290, needs the fork | Board-specific. In-tree `it87` covers many other ITE chips; Nuvoton boards use `nct6775` instead |
| PWM channel | `pwm2` = CHA_FAN1 (already a CLI arg) | Per-board — needs the right `pwmN` |
| Board topology | ARCTIC hub, one duty for 4 blowers, tach on slot 1 only | Deployment docs are rig-specific |
| GPU side | 4× CMP 170HX, HBM-sensor-driven curve, `LO/HI/T_LO/T_HI` tuned | GPU-specific — the <4-readings fail-safe is a real trap on smaller rigs |
| Deploy paths | `/home/no/...`, `/var/tmp/170hx_logs` in units | Editable, but absolute |

## Files (canonical → deployed)

| canonical (this dir) | deployed | purpose |
|---|---|---|
| `it87.conf` | `/etc/modprobe.d/it87.conf` | `options it87 ignore_resource_conflict=1` |
| `it87-noautoload.conf` | `/etc/modprobe.d/it87-noautoload.conf` | blacklist: blocks udev/alias auto-load only. **Gotcha:** kmod's deny-list also blocks systemd-modules-load *named* loads — never re-add a `modules-load.d` entry for it87 while this blacklist exists; it silently no-ops (caused two silent boot failures 2026-09-14→16). |
| `gpu-fan-curve.py` | `/usr/local/sbin/gpu-fan-curve.py` | HBM→duty loop; arg = pwm index (`2` = CHA_FAN1) |
| `gpu-fan-curve.service` | `/etc/systemd/system/gpu-fan-curve.service` | runs the loop, `Restart=always`; `ExecStartPre=-modprobe it87` loads the module at unit start (the boot-time load path — direct modprobe is not subject to the kmod deny-list) |
| `gpu-temp-log.service` | `/etc/systemd/system/gpu-temp-log.service` | runs `gpu-temp-log.sh` (this repo) in place; 5 s sleep, ~6–7 s cadence incl. `nvidia-smi` |
| `gpu-temp-prune.service` + `.timer` | `/etc/systemd/system/` | daily prune of temp-log CSVs >180 days |
| `gpu-slots.tsv` | `/etc/gpu-slots.tsv` | serial→slot map for the logger; the repo copy is a sanitized template — full serials stay local |

Rule: edit canonical only, then copy. Verify with `diff`.

## Module source

`it87/` — git clone of https://github.com/frankcrawford/it87 at `a904dd8`, registered as
a submodule (fresh clone of this repo: `git submodule update --init` first)
(in-tree `it87` does not bind the IT8665E at 0x290; the fork does). Install into DKMS:

    sudo cp -r it87 /usr/src/it87-a904dd8.20260910   # or use it87/dkms-install.sh
    sudo dkms add -m it87 -v a904dd8.20260910 && sudo dkms install -m it87 -v a904dd8.20260910

DKMS rebuilds automatically on kernel updates; if a new kernel breaks the build, the
boot load fails harmlessly and the BIOS Manual curve keeps the fleet safe (see below).

## Rebuild-from-scratch deploy

    sudo cp it87.conf it87-noautoload.conf /etc/modprobe.d/
    sudo cp gpu-fan-curve.py /usr/local/sbin/
    sudo cp gpu-fan-curve.service gpu-temp-log.service gpu-temp-prune.service gpu-temp-prune.timer /etc/systemd/system/
    sudo systemctl daemon-reload
    sudo systemctl enable --now gpu-fan-curve.service gpu-temp-log.service gpu-temp-prune.timer

The fan-curve unit's `ExecStartPre` loads it87; the logger picks up the hwmon per-sample
(do NOT add a modules-load.d entry — see the deny-list gotcha in the file table).

## Curve (2026-09-13 constants, in `gpu-fan-curve.py`)

`duty = clamp(LO..HI, LO + (T−T_LO)/(T_HI−T_LO)·(HI−LO))`, T = hottest HBM across the
4 cards, sampled every 5 s; instant ramp-up, back-off 2 duty/cycle; any sensor/loop
error → full speed (fail-safe); <4 readings → fail-safe.

- `LO,HI = 51,255`, `T_LO,T_HI = 53,70` — flat 20% ≤53 °C (idle band 50–52 °C), full at 70 °C.
- Idle/serving-idle ≈ duty 51–75 → ~1,700–1,950 rpm (slot-1 tach). NOTE: the 2026-09-12
  BIOS-side figure "20% → 2,090 rpm" does not transfer to register duty (duty 75 → 1,934).
  Floor state at duty 51 not yet tach/ear-verified; if blowers 2–4 stall at the floor,
  raise `LO` to 75 (verified holding 1,934 rpm).
- RPM mapping (slot-1 tach, mid-band): ~8 rpm per duty point; 255 → ~3,450 rpm.
- Only slot-1 reports tach through the hub; blowers 2–4 are tach-blind (ear-check only).

## Fallback if this stack is removed/broken

The BIOS Q-Fan curve on `CHA1 FAN` (set 2026-09-12, lives only in CMOS — not recorded
anywhere else): Manual mode, 20% ≤42 °C, 100% at 62 °C, straight ramp between. It owns
the header whenever `pwm2_enable` is `2` (firmware auto) — stopping this service hands
it over automatically (ExecStopPost); by hand: `echo 2 >
/sys/class/hwmon/hwmon*/pwm2_enable` (resolve hwmon by `name=it8665`; indices
renumber per boot).

## Verification after deploy

1. `lsmod | grep it87` and an `it8665` hwmon with non-zero `fan2_input`.
2. `gpu-fan-curve.service` active with **no fail-safe lines** in its journal — a quiet
   journal is the healthy state (the no-device path sleeps silently, it doesn't log).
3. `pwm2_enable` reads back 1 (a 0 read-back is a known it8665 encoding on this chip —
   the duty register is the live truth); duty matches the curve for current max HBM;
   `fan2_input` tracks (~8 rpm/duty mid-band).
4. Logger CSV (`/var/tmp/170hx_logs/`) rows carry live `fan_rpm`/`fan_pct` (resolved per sample;
   `fan_pct` is the commanded duty normalized to 0–100).
5. **Boot path (verify after an actual reboot, not just a restart):** `lsmod | grep it87`
   is populated with no manual action. Do NOT expect a "modprobe" hit in
   `journalctl -b -u gpu-fan-curve.service` — a successful ExecStartPre logs nothing; and
   `journalctl -b -u systemd-modules-load` must NOT be relied on — it deny-lists this
   module (see file-table gotcha).
