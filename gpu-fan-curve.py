#!/usr/bin/env python3
"""Drive the CHA_FAN1 PWM channel from the hottest HBM reading across the 170HX cards.

All four blowers hang off one ARCTIC hub on CHA_FAN1, so a single duty drives the
fleet. Canonical copy: 170hx_fan_control/gpu-fan-curve.py — deployed copy goes to
/usr/local/sbin/; re-copy after any change here.

Differences from the §4.4 reference script: the it87 hwmon device is resolved by
*name* and re-resolved on write failure, because hwmon indices renumber every boot
(same lesson as per-boot BDF renumbering, §13); manual mode (pwmN_enable=1) is
re-asserted every cycle because firmware may re-assert auto mode (§4.2 decision).
Fail-safe: any read error or missing reading drives the fan to full speed."""
import pathlib, subprocess, sys, time

if len(sys.argv) != 2:
    sys.exit("usage: gpu-fan-curve.py <pwmN>   # pwmN on the it87 device (2 = CHA_FAN1 on this board; 1 = CPU fan!)")
PWM_IDX  = sys.argv[1]
LO, HI   = 51, 255           # duty clamp — 20% floor. The "2,090 rpm @ 20%" BIOS-tach figure does NOT
                             # transfer to register duty (duty 75 → 1,934 rpm, 2026-09-12); the
                             # duty-51 floor is not yet tach/ear-verified.
T_LO, T_HI = 53, 70          # °C band mapped onto LO..HI: flat 20% ≤53 °C (idle band 50-52), full at 70
duty     = 140

def resolve():
    """Return (pwm, enable) paths for the it87 device, or (None, None)."""
    for d in sorted(pathlib.Path("/sys/class/hwmon").glob("hwmon*")):
        try:
            name = (d / "name").read_text().strip()
        except OSError:
            continue
        if name.startswith("it86"):
            pwm, en = d / f"pwm{PWM_IDX}", d / f"pwm{PWM_IDX}_enable"
            if pwm.exists() and en.exists():
                return pwm, en
    return None, None

def set_duty(pwm, en, d):
    en.write_text("1")       # re-assert manual mode every cycle (BIOS may revert)
    pwm.write_text(str(d))

PWM, EN = None, None
while True:
    try:
        if PWM is None:
            PWM, EN = resolve()
            if PWM is None:                  # module not loaded (e.g. blacklisted at boot):
                time.sleep(60)               # BIOS Manual curve keeps the fleet safe meanwhile
                continue
        out = subprocess.run(
            ["nvidia-smi", "--query-gpu=temperature.memory", "--format=csv,noheader,nounits"],
            capture_output=True, text=True, timeout=10, check=True).stdout
        temps = [int(x) for x in out.split() if x.strip().isdigit()]
        if len(temps) < 4 or max(temps) <= 0:
            raise RuntimeError(f"bad HBM temperatures: {temps}")
        t = max(temps)
        target = min(HI, max(LO, int((t - T_LO) / (T_HI - T_LO) * (HI - LO) + LO)))
        if target >= duty:
            duty = target                      # ramp up immediately
        else:
            duty = max(target, duty - 2)       # back off slowly (avoid fan cycling)
        set_duty(PWM, EN, duty)
    except Exception as e:
        print(f"fail-safe full speed: {e}", file=sys.stderr)
        PWM, EN = resolve()                    # device may have renumbered / module reloaded
        if PWM is not None:
            try:
                set_duty(PWM, EN, HI)
                duty = HI                       # latch, so recovery back-offs from full speed
            except Exception:
                pass
        time.sleep(60)
        continue
    time.sleep(5)
