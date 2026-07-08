#!/usr/bin/env python3
#
# Drives the Movies/TV/Anime watch-limit wheel with the controller's D-pad while
# the gate popup is open. QML Keys can't see gamepad evdev, so this reads the
# "Pro Controller" event device directly (pure stdlib) and calls the gate's IPC:
#
#   D-pad left  / right  = move the wheel 1..10   (ipc left / right)
#   D-pad up    / A      = confirm the choice      (ipc confirm) -> exits
#   D-pad down  / B      = leave (go to YouTube)    (ipc cancel)  -> exits
#
# Launched by the widget when the gate opens; self-exits on confirm/cancel or
# after TIMEOUT so it never lingers. No-ops (exits) when no controller present.

import glob, os, select, struct, subprocess, time

SHELL = os.path.expanduser("~/.config/hypr/scripts/quickshell/Shell.qml")
EVENT_FMT = "llHHi"                 # input_event (64-bit): timeval + type + code + value
EVENT_SIZE = struct.calcsize(EVENT_FMT)
EV_KEY = 0x01
EV_ABS = 0x03
ABS_HAT0X = 0x10                    # D-pad X: -1 left, +1 right
ABS_HAT0Y = 0x11                    # D-pad Y: -1 up,   +1 down
BTN_SOUTH = 0x130                  # A
BTN_EAST = 0x131                   # B
TIMEOUT = 120                      # give up if the gate is ignored


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
    subprocess.run(["quickshell", "-p", SHELL, "ipc", "call", "mediagate", fn],
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
        if etype == EV_ABS:
            if code == ABS_HAT0X:
                if value < 0:
                    ipc("left")
                elif value > 0:
                    ipc("right")
            elif code == ABS_HAT0Y:
                if value < 0:
                    ipc("confirm"); return     # up = confirm
                elif value > 0:
                    ipc("cancel"); return       # down = leave
        elif etype == EV_KEY and value == 1:    # button press
            if code == BTN_SOUTH:
                ipc("confirm"); return
            elif code == BTN_EAST:
                ipc("cancel"); return


if __name__ == "__main__":
    main()
