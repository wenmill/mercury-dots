#!/usr/bin/env python3
#
# Drives the GamingPrompt popup with the controller's D-pad while it's open.
# QML Keys can't see gamepad evdev, so this reads the "Pro Controller" event
# device directly (pure stdlib — no python-evdev) and calls the popup's IPC:
#
#   D-pad left  = more time      (ipc addTime)
#   D-pad right = less time      (ipc subTime)
#   D-pad up    = start gaming   (ipc confirm)  -> exits
#   D-pad down  = cancel         (ipc cancel)   -> exits
#
# Launched by controller_gaming_watch.sh right after the popup opens; self-exits
# on confirm/cancel or after TIMEOUT so it never lingers.

import glob, os, select, struct, subprocess, time

SHELL = os.path.expanduser("~/.config/hypr/scripts/quickshell/Shell.qml")
EVENT_FMT = "llHHi"                 # input_event (64-bit): timeval + type + code + value
EVENT_SIZE = struct.calcsize(EVENT_FMT)
EV_ABS = 0x03
ABS_HAT0X = 0x10                    # D-pad X: -1 left, +1 right
ABS_HAT0Y = 0x11                    # D-pad Y: -1 up,   +1 down
TIMEOUT = 60                        # give up if the popup is ignored


def find_device():
    for ev in glob.glob("/sys/class/input/event*"):
        try:
            with open(os.path.join(ev, "device", "name")) as f:
                if f.read().strip() == "Pro Controller":
                    return "/dev/input/" + os.path.basename(ev)
        except OSError:
            pass
    return None


def ipc(fn):
    subprocess.run(["quickshell", "-p", SHELL, "ipc", "call", "gaming", fn],
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def main():
    dev = find_device()
    if not dev:
        return
    try:
        f = open(dev, "rb", buffering=0)
    except OSError:
        return
    deadline = time.time() + TIMEOUT
    while time.time() < deadline:
        r, _, _ = select.select([f], [], [], deadline - time.time())
        if not r:
            break
        data = f.read(EVENT_SIZE)
        if not data or len(data) < EVENT_SIZE:
            continue
        _, _, etype, code, value = struct.unpack(EVENT_FMT, data)
        if etype != EV_ABS:
            continue
        if code == ABS_HAT0X:
            if value < 0:
                ipc("addTime")        # left = more time
            elif value > 0:
                ipc("subTime")        # right = less time
        elif code == ABS_HAT0Y:
            if value < 0:
                ipc("confirm"); return  # up = start
            elif value > 0:
                ipc("cancel"); return   # down = cancel


if __name__ == "__main__":
    main()
