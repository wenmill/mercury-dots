#!/usr/bin/env python3
"""System-calendar bridge for the CalendarPopup.

Reads/writes standard iCalendar (.ics) files in the vdir layout at
~/.calendars/<collection>/ — the same store khal / vdirsyncer / Thunderbird
use, so installing any of those later picks these events up unchanged
(and events synced BY them show up here).

    events.py list YYYY-MM-DD          -> JSON array for that day, sorted:
        [{"start":"HH:MM","end":"HH:MM","summary":"...","allday":false,"uid":"..."}]
    events.py add YYYY-MM-DD HH:MM MINUTES SUMMARY...
                                       -> writes a new .ics, prints its uid
    events.py remove UID               -> deletes the event file with that uid

stdlib only. Limitations (fine for a personal calendar; khal removes them
later): no RRULE recurrence expansion, no TZID conversion (naive/local and
UTC 'Z' times are handled; explicit foreign TZIDs are treated as local).
"""

import json
import os
import sys
import time
import uuid
from datetime import datetime, timedelta, timezone

CAL_ROOT = os.path.expanduser("~/.calendars")
DEFAULT_COLLECTION = os.path.join(CAL_ROOT, "personal")


def _unfold(text):
    """RFC 5545 line unfolding (continuation lines start with space/tab)."""
    out = []
    for line in text.splitlines():
        if line[:1] in (" ", "\t") and out:
            out[-1] += line[1:]
        else:
            out.append(line)
    return out


def _unescape(v):
    return (v.replace("\\n", "\n").replace("\\N", "\n")
             .replace("\\,", ",").replace("\\;", ";").replace("\\\\", "\\"))


def _parse_dt(value, params):
    """Parse a DTSTART/DTEND value. Returns (datetime_local, allday)."""
    value = value.strip()
    if params.get("VALUE") == "DATE" or (len(value) == 8 and value.isdigit()):
        return datetime.strptime(value, "%Y%m%d"), True
    if value.endswith("Z"):
        dt = datetime.strptime(value, "%Y%m%dT%H%M%SZ").replace(tzinfo=timezone.utc)
        return dt.astimezone().replace(tzinfo=None), False
    return datetime.strptime(value, "%Y%m%dT%H%M%S"), False


def _events_in_file(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            lines = _unfold(fh.read())
    except OSError:
        return
    ev = None
    for line in lines:
        u = line.strip()
        if u == "BEGIN:VEVENT":
            ev = {}
            continue
        if u == "END:VEVENT":
            if ev is not None and "DTSTART" in ev:
                yield ev
            ev = None
            continue
        if ev is None or ":" not in line:
            continue
        head, value = line.split(":", 1)
        parts = head.split(";")
        name = parts[0].upper()
        params = {}
        for p in parts[1:]:
            if "=" in p:
                k, v = p.split("=", 1)
                params[k.upper()] = v
        if name in ("DTSTART", "DTEND", "SUMMARY", "UID"):
            ev[name] = (value, params)


def list_day(day_iso):
    day = datetime.strptime(day_iso, "%Y-%m-%d")
    day_end = day + timedelta(days=1)
    results = []
    if os.path.isdir(CAL_ROOT):
        for coll in sorted(os.listdir(CAL_ROOT)):
            cdir = os.path.join(CAL_ROOT, coll)
            if not os.path.isdir(cdir):
                continue
            for fn in os.listdir(cdir):
                if not fn.lower().endswith(".ics"):
                    continue
                for ev in _events_in_file(os.path.join(cdir, fn)):
                    try:
                        start, allday = _parse_dt(*ev["DTSTART"])
                    except (ValueError, KeyError):
                        continue
                    if "DTEND" in ev:
                        try:
                            end, _ = _parse_dt(*ev["DTEND"])
                        except ValueError:
                            end = start + timedelta(hours=1)
                    else:
                        end = start + (timedelta(days=1) if allday else timedelta(hours=1))
                    # overlap with [day, day_end)
                    if start < day_end and end > day:
                        summary = _unescape(ev.get("SUMMARY", ("", {}))[0]).strip() or "(untitled)"
                        uid = ev.get("UID", ("", {}))[0]
                        # clamp to the queried day so multi-day events render
                        # as full-height blocks on each day they span
                        ds = max(start, day)
                        de = min(end, day_end)
                        sh = 0.0 if allday else (ds.hour + ds.minute / 60.0)
                        eh = 24.0 if (allday or de >= day_end) else (de.hour + de.minute / 60.0)
                        results.append({
                            "start": "00:00" if allday else ds.strftime("%H:%M"),
                            "end": "24:00" if (allday or de >= day_end) else de.strftime("%H:%M"),
                            "startHour": sh,
                            "endHour": max(eh, sh + 0.25),
                            "summary": summary,
                            "allday": allday,
                            "uid": uid,
                        })
    results.sort(key=lambda e: (not e["allday"] and 1 or 0, e["startHour"], e["summary"]))
    # allday first, then by time
    results.sort(key=lambda e: (0 if e["allday"] else 1, e["startHour"]))
    return results


def _escape(v):
    return (v.replace("\\", "\\\\").replace(";", "\\;")
             .replace(",", "\\,").replace("\n", "\\n"))


def add_event(day_iso, hhmm, minutes, summary):
    os.makedirs(DEFAULT_COLLECTION, exist_ok=True)
    start = datetime.strptime(day_iso + " " + hhmm, "%Y-%m-%d %H:%M")
    end = start + timedelta(minutes=int(minutes))
    uid = str(uuid.uuid4())
    stamp = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())
    ics = (
        "BEGIN:VCALENDAR\r\n"
        "VERSION:2.0\r\n"
        "PRODID:-//quickshell-calendar//events.py//EN\r\n"
        "BEGIN:VEVENT\r\n"
        f"UID:{uid}\r\n"
        f"DTSTAMP:{stamp}\r\n"
        f"DTSTART:{start.strftime('%Y%m%dT%H%M%S')}\r\n"
        f"DTEND:{end.strftime('%Y%m%dT%H%M%S')}\r\n"
        f"SUMMARY:{_escape(summary)}\r\n"
        "END:VEVENT\r\n"
        "END:VCALENDAR\r\n"
    )
    path = os.path.join(DEFAULT_COLLECTION, uid + ".ics")
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(ics)
    return uid


def remove_event(uid):
    removed = False
    if os.path.isdir(CAL_ROOT):
        for coll in os.listdir(CAL_ROOT):
            cdir = os.path.join(CAL_ROOT, coll)
            if not os.path.isdir(cdir):
                continue
            for fn in os.listdir(cdir):
                if not fn.lower().endswith(".ics"):
                    continue
                p = os.path.join(cdir, fn)
                for ev in _events_in_file(p):
                    if ev.get("UID", ("",))[0] == uid:
                        os.unlink(p)
                        removed = True
                        break
    return removed


def main():
    if len(sys.argv) >= 3 and sys.argv[1] == "list":
        print(json.dumps(list_day(sys.argv[2])))
    elif len(sys.argv) >= 6 and sys.argv[1] == "add":
        print(add_event(sys.argv[2], sys.argv[3], sys.argv[4], " ".join(sys.argv[5:])))
    elif len(sys.argv) >= 3 and sys.argv[1] == "remove":
        sys.exit(0 if remove_event(sys.argv[2]) else 1)
    else:
        sys.stderr.write(__doc__ + "\n")
        sys.exit(2)


if __name__ == "__main__":
    main()
