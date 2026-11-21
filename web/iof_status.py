"""Снимок и дневная история VPN-служб для публичной страницы."""

import fcntl
import json
import os
import time

from iof_auth import atomic_write


INTERVAL = 300
MAX_GAP = INTERVAL + 180  # период опроса с допуском на длительность iof api status
FRESH_FOR = 2 * INTERVAL
DAY = 24 * 3600
DAYS = 30
MIN_MEASURED = 3600
OPERATIONAL, OUTAGE, UNKNOWN = "operational", "outage", "unknown"


def day_start(at):
    return at - at % DAY


def first_day(at):
    return day_start(at) - (DAYS - 1) * DAY


def service_state(node):
    if not node["reachable"]:
        return UNKNOWN
    hy2, awg = node["hy2"], node["awg"]
    if (hy2["installed"] and (hy2["state"] != "active" or not hy2["udp"])) or awg["state"] == "stopped":
        return OUTAGE
    if hy2["installed"] or awg["state"] == "running":
        return OPERATIONAL
    return UNKNOWN


def daily(counter, at):
    return counter.setdefault(str(day_start(at)), {"up": 0, "down": 0, "unknown": 0,
                                                  "up_seconds": 0, "down_seconds": 0})


def add_observation(entry, state, at, previous_at):
    counts = daily(entry["days"], at)
    counts[{OPERATIONAL: "up", OUTAGE: "down", UNKNOWN: "unknown"}[state]] += 1
    # Учитываются интервалы между соседними согласованными наблюдениями.
    if (state != UNKNOWN and state == entry["state"] and previous_at is not None
            and 0 < at - previous_at <= MAX_GAP):
        field = "up_seconds" if state == OPERATIONAL else "down_seconds"
        boundary = min(at, day_start(previous_at) + DAY)
        daily(entry["days"], previous_at)[field] += boundary - previous_at
        counts[field] += at - boundary
    entry["state"] = state


def public_days(days, start):
    for at in range(start, start + DAYS * DAY, DAY):
        entry = days.get(str(at), {})
        up, down = entry.get("up", 0), entry.get("down", 0)
        up_seconds, down_seconds = entry.get("up_seconds", 0), entry.get("down_seconds", 0)
        state = OUTAGE if down or down_seconds else OPERATIONAL if up or up_seconds else UNKNOWN
        yield {"date": at, "state": state, "up": up, "down": down, "unknown": entry.get("unknown", 0),
               "up_seconds": up_seconds, "down_seconds": down_seconds}


def public_name(number):
    return f"Сервер {number:d}"


def network_state(nodes):
    states = {node["state"] for node in nodes}
    if states == {OUTAGE}:
        return "all_outage"
    if OUTAGE in states:
        return OUTAGE
    return OPERATIONAL if states == {OPERATIONAL} else UNKNOWN


class PublicStatus:
    def __init__(self, base):
        self.base = base
        self.path = base / "public-status.json"

    def read(self):
        try:
            return json.loads(self.path.read_text(encoding="utf-8"))
        except FileNotFoundError:
            return {"updated_at": None, "attempt_at": None, "next_number": 1, "nodes": {}, "events": []}

    def record(self, result):
        # Читатель видит целый снимок. Блокировка исключает одновременную запись при двух процессах панели.
        self.base.mkdir(mode=0o700, parents=True, exist_ok=True)
        with os.fdopen(os.open(self.base / "public-status.lock", os.O_CREAT | os.O_WRONLY, 0o600), "w") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            self.record_locked(result)

    def record_locked(self, result):
        data = self.read()
        at = int(result["status_at"])
        if data["attempt_at"] is not None and at <= data["attempt_at"]:
            return
        previous_at = data["updated_at"] if data["attempt_at"] == data["updated_at"] else None
        data["attempt_at"] = at
        if result["status_error"] is None:
            data["updated_at"] = at
            current = {}
            for node in result["nodes"]:
                name = node["name"]
                entry = data["nodes"].get(name)
                state = service_state(node)
                if state == UNKNOWN and entry is None:
                    continue
                if entry is None:
                    entry = {"number": data["next_number"], "state": UNKNOWN, "known_state": None,
                             "maintenance": None, "known_maintenance": None, "days": {}}
                    data["next_number"] += 1
                current[name] = entry
                add_observation(entry, state, at, previous_at)
                self.record_events(data["events"], entry, node.get("nightly_active"), at)
            data["nodes"] = current
        start = first_day(at)
        for entry in data["nodes"].values():
            entry["days"] = {k: v for k, v in entry["days"].items() if int(k) >= start}
        data["events"] = [event for event in data["events"] if event["at"] >= start][-60:]
        atomic_write(self.path, json.dumps(data, ensure_ascii=False, separators=(",", ":")))

    @staticmethod
    def record_events(events, entry, maintenance, at):
        def add(kind):
            events.append({"number": entry["number"], "kind": kind, "at": at})

        state, previous = entry["state"], entry["known_state"]
        if state == OUTAGE and previous != OUTAGE:
            add("outage")
        elif state == OPERATIONAL and previous == OUTAGE:
            add("recovery")
        if state != UNKNOWN:
            entry["known_state"] = state
        if maintenance is True and entry["known_maintenance"] is not True:
            add("maintenance")
        if maintenance is not None:
            entry["known_maintenance"] = maintenance
        entry["maintenance"] = maintenance

    def view(self, now=None):
        now = int(time.time()) if now is None else now
        try:
            data = self.read()
        except (OSError, ValueError):
            return {"state": UNKNOWN, "updated_at": None, "nodes": [], "events": []}
        updated_at = data["updated_at"]
        fresh = (updated_at is not None and data["attempt_at"] == updated_at and 0 <= now - updated_at <= FRESH_FOR)
        start = first_day(now)
        nodes = []
        for entry in sorted(data["nodes"].values(), key=lambda entry: entry["number"]):
            days = list(public_days(entry["days"], start))
            up = sum(day["up_seconds"] for day in days)
            measured = up + sum(day["down_seconds"] for day in days)
            nodes.append({"name": public_name(entry["number"]), "state": entry["state"] if fresh else UNKNOWN,
                          "maintenance": fresh and entry["maintenance"] is True, "days": days,
                          "availability": round(up * 100 / measured, 2) if measured >= MIN_MEASURED else None})
        events = [{"name": public_name(event["number"]), "kind": event["kind"], "at": event["at"]}
                  for event in reversed(data["events"]) if start <= event["at"] <= now][:12]
        return {"state": network_state(nodes), "updated_at": updated_at, "nodes": nodes, "events": events}


def collect(stop, cache, history, log):
    while not stop.is_set():
        started = time.monotonic()
        try:
            result = cache.get(force=True)
            if not stop.is_set():
                history.record(result)
        except (OSError, ValueError) as error:
            log(f"статус: не удалось записать наблюдение: {error}")
        stop.wait(max(0, INTERVAL - (time.monotonic() - started)))
