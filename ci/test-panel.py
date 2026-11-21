#!/usr/bin/env python3
"""Проверки ссылок, панели и локальных команд без SSH и настоящего Telegram."""
import base64
import html
import importlib.util
from email.message import Message
from io import BytesIO
import json
from pathlib import Path
import subprocess
import sys
import tempfile
from threading import Event
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch as mock_patch
import zlib

ROOT = Path(__file__).resolve().parents[1]
sys.dont_write_bytecode = True
sys.path.insert(0, str(ROOT / "web"))


def module(name, path):
    spec = importlib.util.spec_from_file_location(name, ROOT / path)
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


bot = module("iof_bot", "web/iof_bot.py")
web = module("iof_web", "web/iof-web.py")


class PanelAppearance(unittest.TestCase):
    def test_logo_is_available_before_login(self):
        handler = web.Handler.__new__(web.Handler)
        handler.route = Mock(return_value=("/logo-panel.svg", {}))
        handler.static = Mock()
        handler.authorized = Mock(return_value=False)
        handler.do_GET()
        handler.static.assert_called_once_with("logo-panel.svg", "image/svg+xml")
        handler.authorized.assert_not_called()
        self.assertTrue((web.STATIC_DIR / "logo-panel.svg").is_file())

    def test_branding_on_all_pages(self):
        footer = ('<footer class="foot">Island of Freedom · by mEldevlp - '
                  '<a href="https://github.com/mEldevlp">https://github.com/mEldevlp</a></footer>')
        for path in web.STATIC_DIR.glob("*.html"):
            with self.subTest(page=path.name):
                text = path.read_text(encoding="utf-8")
                asset = "/status/assets/" if path.name == "status.html" else ""
                self.assertIn(f'<img class="logo" src="{asset}logo-panel.svg"', text)
                self.assertIn(footer, text)
                self.assertNotIn('<svg class="logo"', text)
        for name in ("hy2.html", "bot.html"):
            self.assertNotIn("Команды на сервере", (web.STATIC_DIR / name).read_text(encoding="utf-8"))


class PublicStatus(unittest.TestCase):
    status = web.iof_status
    midnight = 20000 * status.DAY

    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.history = self.status.PublicStatus(Path(tmp.name))

    @staticmethod
    def node(name, *, reachable=True, hy2="active", awg="none", nightly="no"):
        return web.shape_node({"name": name, "addr": "192.0.2.3", "title": "Закрытая подпись",
                               "reachable": "yes" if reachable else "no", "issues": "закрытая ошибка",
                               "hy2_installed": "yes" if hy2 else "no", "hy2_state": hy2, "hy2_udp": "yes",
                               "awg_state": awg, "nightly_active": nightly})

    def record(self, at, *nodes, error=None):
        self.history.record({"status_at": at, "status_error": error, "nodes": nodes})
        return self.history.view(at)

    def test_empty_and_classification(self):
        at = self.midnight
        self.assertEqual(self.history.view(at), {"state": "unknown", "updated_at": None, "nodes": [], "events": []})
        up = self.node("vpn1")
        down = self.node("vpn2", hy2="", awg="stopped")
        unreachable = self.node("vpn1", reachable=False)
        view = self.record(at, up, down, self.node("controller", hy2=""), self.node("new", reachable=False))
        self.assertEqual(view["state"], "outage")
        self.assertEqual([n["state"] for n in view["nodes"]], ["operational", "outage"])
        no_container = self.node("vpn2", hy2="")
        view = self.record(at + 150, up, no_container)
        self.assertEqual([n["state"] for n in view["nodes"]], ["operational", "unknown"])
        self.assertEqual(view["nodes"][1]["days"][-1]["down"], 1)
        view = self.record(at + 300, down, unreachable)
        self.assertEqual([(n["name"], n["state"]) for n in view["nodes"]],
                         [("Сервер 1", "unknown"), ("Сервер 2", "outage")])
        self.assertEqual(view["nodes"][0]["days"][-1]["unknown"], 1)
        self.assertEqual(self.record(at + 600, down)["state"], "all_outage")
        failed = self.record(at + 900, error="закрытый лог")
        self.assertEqual(failed["state"], "unknown")
        self.assertEqual(failed["updated_at"], at + 600)
        self.assertNotIn("закрыт", json.dumps(failed, ensure_ascii=False).lower())

    def test_intervals_events_staleness_and_retention(self):
        at = self.midnight
        up = self.node("private.example")
        down = self.node("private.example", hy2="failed", nightly="yes")
        ssh_failure = self.node("private.example", reachable=False)
        self.record(at - 100, up)
        for time in range(at + 200, at + 3501, 300):
            self.record(time, up)
        self.record(at + 3800, down)
        self.record(at + 4100, down)
        self.record(at + 4400, ssh_failure)
        self.record(at + 4700, down)
        self.record(at + 5600, down)
        view = self.record(at + 5900, up)
        node = view["nodes"][0]
        self.assertEqual(sum(d["up_seconds"] for d in node["days"]), 3600)
        self.assertEqual(node["days"][-2]["up_seconds"], 100)
        self.assertEqual(node["days"][-1]["down_seconds"], 300)
        self.assertEqual(node["availability"], 92.31)
        self.assertEqual([e["kind"] for e in view["events"]], ["recovery", "maintenance", "outage"])
        stale = self.status.PublicStatus(self.history.base).view(at + 5900 + self.status.FRESH_FOR + 1)
        self.assertEqual(stale["state"], "unknown")
        self.assertEqual(stale["nodes"][0]["days"], node["days"])
        self.assertFalse(stale["nodes"][0]["maintenance"])
        self.assertEqual(set(node), {"name", "state", "days", "availability", "maintenance"})
        self.assertNotIn("private.example", json.dumps(view))
        recent = self.record(at + 31 * self.status.DAY, up)
        self.assertIsNone(recent["nodes"][0]["availability"])
        self.assertFalse(recent["events"])
        self.assertEqual(len(self.history.read()["nodes"]["private.example"]["days"]), 1)


class CronSchedule(unittest.TestCase):
    def test_save_existing_nightly_and_add_reboot_pair(self):
        cron = web.iof_cron
        other = "SHELL=/bin/bash\n# расписание сервера\n\n17 * * * * housekeeping\n"
        root = [other + "0 4 * * * /usr/local/sbin/iof-nightly >/dev/null 2>&1\n"]
        writes = []

        def command(args, stdin=None):
            self.assertEqual(args[:3], ["crontab", "-u", "root"])
            if stdin is not None:
                root[0] = stdin
                writes.append(stdin)
            return SimpleNamespace(returncode=0, stdout=root[0].encode(), stderr=b"")

        with mock_patch.object(cron, "command", side_effect=command), \
             mock_patch.object(cron, "system_jobs", return_value=[]), \
             mock_patch.object(cron.time, "time", return_value=1795224000):
            self.assertEqual(cron.view()["schedules"]["nightly"]["time"], "04:00")
            cron.save({"task": "nightly", "time": "03:45"})
            self.assertEqual(root[0], other + "45 3 * * * /usr/local/sbin/iof-nightly >/dev/null 2>&1\n")
            cron.save({"task": "reach", "time": "04:10"})
            cron.save({"task": "reach", "time": "04:10"})
            self.assertEqual(len(writes), 2)
            self.assertEqual(cron.view()["schedules"]["reach"]["time"], "04:10")
            cron.save({"task": "reach", "time": "04:20"})
            self.assertEqual(root[0].count("check-from-ru --scheduled 04:20"), 2)
            self.assertEqual(root[0].count("@reboot"), 1)
            self.assertNotIn("04:10", root[0])
            reboot = next(j for j in cron.view()["jobs"] if j["schedule"] == "@reboot")
            cron.change({**reboot, "action": "delete"})
            self.assertNotIn("check-from-ru", root[0])
            self.assertTrue(root[0].startswith(other))

    def test_change_system_job_keeps_file_metadata_and_checks_revision(self):
        cron = web.iof_cron
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "iof-local"
            existing = "MAILTO=root\n# Локальные задания\n5 2 * * * root /bin/true\n"
            path.write_text(existing, encoding="utf-8")
            path.chmod(0o640)
            with mock_patch.object(cron, "CRON_DIR", path.parent), \
                 mock_patch.object(cron, "command", return_value=SimpleNamespace(returncode=0)) as command:
                cron.change({"action": "add", "source": str(path), "schedule": "@reboot",
                             "command": r"date +\%F | logger", "user": "nobody"})
                row, = [j for j in cron.tab_jobs(cron.read_tab(path), str(path), None) if j["schedule"] == "@reboot"]
                cron.change({**row, "action": "edit", "schedule": "0 4 * * MON-FRI", "command": "echo готово"})
                self.assertEqual(path.read_text(encoding="utf-8"), existing + "0 4 * * MON-FRI nobody echo готово\n")
                self.assertEqual(path.stat().st_mode & 0o777, 0o640)
                self.assertEqual(command.call_count, 2)
                with self.assertRaises(cron.CronChanged):
                    cron.change({**row, "action": "delete"})
                current = list(cron.tab_jobs(cron.read_tab(path), str(path), None))[-1]
                cron.change({**current, "action": "delete"})
                self.assertEqual(path.read_text(encoding="utf-8"), existing)

    def test_disable_periodic_script_preserves_contents(self):
        cron = web.iof_cron
        with tempfile.TemporaryDirectory() as tmp:
            folder = Path(tmp) / "cron.daily"
            folder.mkdir()
            path = folder / "backup"
            path.write_text("#!/bin/sh\n/bin/true\n", encoding="utf-8")
            path.chmod(0o751)
            with mock_patch.object(cron, "PERIODIC", [folder]):
                rev = cron.file_revision(path.stat())
                cron.change({"action": "delete", "source": str(folder), "number": path.name, "revision": rev})
                self.assertEqual(path.stat().st_mode & 0o777, 0o640)
                self.assertEqual(path.read_text(encoding="utf-8"), "#!/bin/sh\n/bin/true\n")
                with self.assertRaises(cron.CronChanged):
                    cron.change({"action": "delete", "source": str(folder), "number": path.name, "revision": rev})

    def test_user_crontab_list_and_edit_use_same_view_of_spool(self):
        cron = web.iof_cron
        with tempfile.TemporaryDirectory() as tmp:
            spool = Path(tmp)
            tab = spool / "nobody"
            job = "@reboot /bin/true\n"
            tab.write_text("# cron spool header\n" + job, encoding="utf-8")
            with mock_patch.object(cron, "CRON_SPOOL", spool), mock_patch.object(cron, "system_tabs", return_value=[]), \
                 mock_patch.object(cron, "PERIODIC", []), mock_patch.object(cron, "crontab", return_value=job), \
                 mock_patch.object(cron, "install_crontab") as install:
                row, = cron.system_jobs()
                cron.change({**row, "action": "edit", "schedule": "@daily"})
                install.assert_called_once_with("nobody", job, ["@daily /bin/true"])

    def test_system_jobs_are_visible_and_leave_existing_nightly_untouched(self):
        cron = web.iof_cron
        system = list(cron.tab_jobs("MAILTO=root\n0 4 * * * root /usr/local/sbin/iof-nightly\n"
                                    "@reboot nobody /bin/true\n", "/etc/cron.d/iof", None))
        with mock_patch.object(cron, "root_crontab", return_value=""), \
             mock_patch.object(cron, "system_jobs", return_value=system), mock_patch.object(cron, "command") as command:
            self.assertEqual(cron.view()["jobs"], system)
            self.assertEqual(system[1]["user"], "nobody")
            with self.assertRaises(ValueError):
                cron.save({"task": "nightly", "time": "04:30"})
            with self.assertRaises(ValueError):
                cron.save({"task": "reach", "time": "04:30; reboot"})
            command.assert_not_called()

    def test_scheduled_check_catches_up_across_midnight_and_runs_once(self):
        with tempfile.TemporaryDirectory() as tmp:
            subprocess.run(["bash", "-c", '''
set -euo pipefail
source lib/common.sh
source lib/status.sh
BASE="$1"
date() {
  case "$*" in
    '+%s') echo 1800000001 ;;
    '-d today 23:45 +%s') echo 1800086300 ;;
    '-d yesterday 23:45 +%s') echo 1799999900 ;;
    '+%F %T') echo '2027-01-15 00:11:00' ;;
    *) return 1 ;;
  esac
}
systemctl() {
  if [[ "$1" == is-active ]]; then
    [[ ! -e "$BASE/waited" ]]
  else
    [[ "$*" == 'start network-online.target' ]]
  fi
}
sleep() { touch "$BASE/waited"; }
check_from_ru() { echo 'Запуск' >>"$BASE/runs"; }
(cmd_check_from_ru --scheduled 23:45 1800000000)
[[ ! -e "$BASE/runs" && ! -e "$BASE/waited" ]]
(cmd_check_from_ru --scheduled 23:45 1799999800)
(cmd_check_from_ru --scheduled 23:45 1799999800)
[[ -e "$BASE/waited" && "$(cat "$BASE/check-from-ru.last")" == 1799999900 ]]
[[ "$(wc -l < "$BASE/runs")" == 1 ]]
''', "check-schedule", tmp], cwd=ROOT, capture_output=True, check=True)


class Dashboard(unittest.TestCase):
    def test_controller_before_and_after_migrate_finish(self):
        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp)
            conf = base / "nodes.conf"
            conf.write_text("node-a | 10.0.0.1 | root@a\nold | 8.8.8.8 | local | Старый\n"
                            "node-b | 10.0.0.2 | root@b\nberlin | 77.1.2.3 | root@new:22 | Новый\n",
                            encoding="utf-8")
            nodes = [{"name": n} for n in ("node-a", "old", "node-b", "berlin")]
            handler = web.Handler.__new__(web.Handler)
            handler.server = SimpleNamespace(base=base, cache=Mock(), controller_cache=Mock())
            handler.send_json = Mock()
            handler.server.cache.get.side_effect = lambda _: {"nodes": nodes}
            handler.server.controller_cache.get.side_effect = lambda _: {
                "nodes": [web.shape_node({"name": "iof-main", "reachable": "yes"})], "status_error": None,
            }

            def names():
                handler.dashboard(False)
                rows = handler.send_json.call_args.args[0]["nodes"]
                self.assertTrue(all(not n["controller"] for n in rows[1:]))
                return [(n["name"], n["controller"]) for n in rows]

            before = [("old", True), ("node-a", False), ("node-b", False), ("berlin", False)]
            self.assertEqual(names(), before)
            subprocess.run(["bash", "-c", 'source lib/migrate.sh; migrate_nodes_conf "$1" root@old:2222 root@new',
                            "migrate-test", str(conf)], cwd=ROOT, check=True)
            self.assertIn("old | 8.8.8.8 | root@old:2222 | Старый", conf.read_text(encoding="utf-8"))
            self.assertIn("berlin | 77.1.2.3 | local | Новый", conf.read_text(encoding="utf-8"))
            state = base / "migrate.conf"
            state.write_text("role=target\nid=test\npeer=root@old:2222\n", encoding="utf-8")
            self.assertEqual(names(), before)
            subprocess.run(["bash", "-c", '''
set -euo pipefail
source lib/common.sh
BASE="$1"; MIGRATE_FILE="$BASE/migrate.conf"
source lib/migrate.sh
run_on() { [[ "$1 $2 $3" == 'root@old:2222 n_migrate_demote test' ]]; }
migrate_finish
''', "migrate-test", str(base)], cwd=ROOT, capture_output=True, check=True)
            self.assertFalse(state.exists())
            self.assertEqual(names(), [("berlin", True), ("node-a", False), ("old", False), ("node-b", False)])
            self.assertTrue(all("controller" not in node for node in nodes))

            conf.write_text(conf.read_text(encoding="utf-8").replace("| local |", "| root@new |"), encoding="utf-8")
            self.assertEqual(names(), [(web.CONTROLLER_NAME, True)] + [(node["name"], False) for node in nodes])
            row = handler.send_json.call_args.args[0]["nodes"][0]
            self.assertTrue(row["dedicated"] and row["local"] and row["ok"])
            self.assertEqual(row["title"], "iof-main")
            self.assertFalse(row["hy2"]["installed"])
            self.assertEqual(row["awg"]["state"], "none")

    def test_countries_ip_and_domain_change_and_retry_after_outage(self):
        now = Mock(return_value=1000)
        dns = Mock(return_value=SimpleNamespace(stdout="10.0.0.1 STREAM\n8.8.8.8 STREAM\n"))
        cache = web.CountryCache()
        addrs = ["vpn.example", "8.8.8.8", "10.0.0.2", "224.0.0.1"]

        def poll():
            self.assertTrue(cache.get(addrs)["pending"])
            cache.worker.join(2)
            self.assertFalse(cache.worker.is_alive())
            result = cache.get(addrs)
            self.assertFalse(result["pending"])
            return result["countries"]

        with mock_patch.object(web.time, "monotonic", now), mock_patch.object(web.subprocess, "run", dns), \
                mock_patch.object(web, "urlopen") as source:
            source.return_value = BytesIO(b'[{"ip":"8.8.8.8","country":"US"}]')
            self.assertEqual(poll(), {"vpn.example": "US", "8.8.8.8": "US"})
            self.assertEqual(json.loads(source.call_args.args[0].data), ["8.8.8.8"])
            self.assertEqual(dns.call_args.args[0], ["getent", "--", "ahosts", "vpn.example"])
            self.assertEqual(dns.call_count, 1)

            now.return_value += 61
            dns.return_value.stdout = "77.1.2.3 STREAM\n"
            source.side_effect = TimeoutError
            self.assertEqual(poll(), {"8.8.8.8": "US"})
            self.assertEqual(json.loads(source.call_args.args[0].data), ["77.1.2.3"])
            now.return_value += 61
            self.assertEqual(poll(), {"8.8.8.8": "US"})
            self.assertEqual(source.call_count, 2)

            now.return_value += 300
            source.side_effect = None
            source.return_value = BytesIO(b'[{"ip":"77.1.2.3","country":"DE"}]')
            self.assertEqual(poll(), {"vpn.example": "DE", "8.8.8.8": "US"})
            self.assertEqual(source.call_count, 3)

    def test_countries_endpoint_does_not_wait_for_lookup_or_probe(self):
        with tempfile.TemporaryDirectory() as tmp:
            cache = web.CountryCache()
            base = Path(tmp)
            (base / "nodes.conf").write_text("home | 8.8.8.8 | root@77.1.2.3\n", encoding="utf-8")
            handler = web.Handler.__new__(web.Handler)
            handler.server = SimpleNamespace(base=base, countries=cache, hosts={"localhost"})
            handler.headers = Message()
            handler.headers["Host"] = "localhost"
            handler.authorized = Mock(return_value=True)
            handler.path = "/api/nodes/countries"
            handler.send_json = Mock()
            started, release = Event(), Event()

            def lookup(ips):
                started.set()
                release.wait(3)
                return dict.fromkeys(ips, "US")

            with mock_patch.object(web, "lookup_countries", side_effect=lookup) as source:
                try:
                    handler.do_GET()
                    self.assertTrue(started.wait(2))
                    handler.do_GET()
                    handler.send_json.assert_called_with({"countries": {}, "pending": True})
                    source.assert_called_once_with(["8.8.8.8"])
                finally:
                    release.set()
                    cache.worker.join(2)
                handler.do_GET()
                handler.send_json.assert_called_with({"countries": {"8.8.8.8": "US"}, "pending": False})


class GroupLinks(unittest.TestCase):
    def deliver(self, urls, png=b"png", error=None):
        views = SimpleNamespace(hy2_links=lambda _: {"label": "Семья & друзья", "links": [{"url": u} for u in urls]},
                                qr_png=Mock(return_value=png))
        client = bot.Bot.__new__(bot.Bot)
        client.views, client.log = views, Mock()
        api = Mock()
        if error:
            api.call.side_effect = [None, error]
        client.view_links(api, 123, "family")
        return views, api.call.call_args_list

    def test_group(self):
        urls = [f"hy2://secret@host{i}:443/?a=1&b=2#Узел{i}" for i in range(5)]
        views, calls = self.deliver(urls)
        self.assertEqual([c.args[0] for c in calls], ["sendMessage", "sendPhoto"])
        text = calls[0].args[1]["text"]
        self.assertEqual(text.count("<pre>"), 1)
        self.assertIn("<pre>" + html.escape("\n".join(urls), quote=False) + "</pre>", text)
        views.qr_png.assert_called_once_with("\n".join(urls))

    def test_without_qr(self):
        _, calls = self.deliver(["hy2://one", "hy2://two"], png=None)
        self.assertEqual(len(calls), 1)
        self.assertEqual(calls[0].args[0], "sendMessage")

    def test_long_group(self):
        urls = ["hy2://" + "😀" * 2100]
        _, calls = self.deliver(urls, png=None)
        self.assertEqual(calls[0].args[0], "sendDocument")
        self.assertEqual(calls[0].kwargs["files"]["document"][1].decode(), urls[0])

    def test_photo_rejected_does_not_repeat_links(self):
        _, calls = self.deliver(["hy2://one"], error=bot.ApiError(400, "Bad Request"))
        self.assertEqual([c.args[0] for c in calls], ["sendMessage", "sendPhoto"])


class AwgLinks(unittest.TestCase):
    def test_export_and_panel(self):
        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp)
            client = base / "awg" / "family"
            client.mkdir(parents=True)
            (client.parent / "index.tsv").write_text("family\tСемья\t2026-11-21 12:00:00\n../other\tДругой клиент\n",
                                                     encoding="utf-8")
            conf = client / "Test.conf"
            conf.write_text("[Interface]\nAddress = 10.8.1.2/32\nDNS = 9.9.9.9, 149.112.112.112\n"
                            "PrivateKey = test-private=\nH1 = 100001000-100001100\nS3 = 20\nI1 = <b 0x12345678>\nI2 =\n"
                            "[Peer]\nEndpoint = relay.example:51821\nPublicKey = server-key=\nPresharedKey = test-psk=\n",
                            encoding="utf-8")
            key = subprocess.check_output(["bash", "-c", 'source lib/awg.sh; awg_make_key "$@"',
                                           "awg-test", str(conf), "client-public=", "amnezia-awg2", "Узел через реле"],
                                          cwd=ROOT, text=True).strip()
            self.assertRegex(key, r"^vpn://[A-Za-z0-9_-]+$")
            encoded = key[6:]
            blob = base64.urlsafe_b64decode(encoded + "=" * (-len(encoded) % 4))
            data = zlib.decompress(blob[4:])
            self.assertEqual(int.from_bytes(blob[:4], "big"), len(data))
            profile = json.loads(data)
            container, = profile["containers"]
            self.assertEqual(profile["defaultContainer"], "amnezia-awg2")
            self.assertEqual(container["container"], "amnezia-awg2")
            self.assertEqual(profile["description"], "Узел через реле")
            self.assertEqual(profile["hostName"], "relay.example")
            self.assertEqual(profile["dns2"], "149.112.112.112")
            self.assertFalse({"userName", "password", "port"} & profile.keys())
            awg = container["awg"]
            self.assertEqual(awg["protocol_version"], "2")
            self.assertEqual(awg["port"], "51821")
            last = json.loads(awg["last_config"])
            self.assertEqual(last["port"], 51821)
            self.assertEqual(last["client_ip"], "10.8.1.2")
            self.assertEqual(last["client_pub_key"], "client-public=")
            self.assertIn("DNS = $PRIMARY_DNS, $SECONDARY_DNS", last["config"])
            self.assertIn("Endpoint = relay.example:51821", last["config"])
            for param in ("H1", "S3", "I1"):
                self.assertEqual(last[param], awg[param])
                self.assertIn(f"{param} = {awg[param]}", last["config"])
            self.assertNotIn("I2 =", last["config"])

            (client / "keys.txt").write_text(f"== Узел через реле\n{key}\n\nслужебный текст\n", encoding="utf-8")
            self.assertEqual(web.read_awg_keys(base, "family"), [{"title": "Узел через реле", "url": key}])
            self.assertEqual(web.read_awg_clients(base)[0]["configs"], ["Test"])
            self.assertNotIn(key, str(web.read_awg_clients(base)))
            with self.assertRaises(ValueError):
                web.read_awg_keys(base, "../other")

            handler = web.Handler.__new__(web.Handler)
            auth = web.Credentials(base)
            auth.save("admin", "test")
            handler.server = SimpleNamespace(base=base, hosts={"localhost"}, auth=auth)
            handler.path = "/api/awg/keys?name=family"
            handler.headers = Message()
            handler.headers["Host"] = "localhost"
            handler.send_body = Mock()
            handler.do_GET()
            self.assertEqual(handler.send_body.call_args.args[3], 401)
            self.assertNotIn(key, str(handler.send_body.call_args))
            handler.headers["Cookie"] = "iof_session=" + auth.issue(auth.read(), "http://localhost")
            handler.do_GET()
            payload, _, cache, status = handler.send_body.call_args.args
            self.assertEqual(status, 200)
            self.assertEqual(cache, "no-store")
            self.assertEqual(json.loads(payload)["links"][0]["url"], key)

            jobs = web.Jobs(lambda: None)
            job = {"log": []}
            jobs.run(job, [("iof awg add", [sys.executable, "-c", "import sys; print(sys.argv[1])", key], None)])
            self.assertEqual(job["state"], "ok")
            self.assertNotIn(key, str(job))
            self.assertIn("vpn://••••••••", job["log"])

    def test_job_validation(self):
        client = {"name": "family", "label": "Семья"}
        _, steps = web.awg_steps("iof", {"action": "del", "name": "family"}, [client], None)
        self.assertEqual(steps[0][1], ["iof", "awg", "del", "family"])
        with self.assertRaises(ValueError):
            web.awg_steps("iof", {"action": "add", "label": "Семья"}, [client], {"role": "source"})
        conf = [("test", "192.0.2.1", "local", "Тест")]
        body = {"action": "install_awg", "name": "test", "port": 51821}
        _, _, steps = web.node_steps("iof", body, conf, [], Path("missing"), None)
        self.assertEqual(steps[0][1], ["iof", "awg", "install", "--port", "51821", "--", "test"])
        for invalid in (0, 65536, True, "51821"):
            with self.assertRaises(ValueError):
                web.node_steps("iof", dict(body, port=invalid), conf, [], Path("missing"), None)

    def test_install_reuses_clients_only_on_ready_nodes(self):
        with tempfile.TemporaryDirectory() as tmp:
            script = r'''
set -euo pipefail
source lib/common.sh
source lib/awg.sh
NODES_FILE="$1/nodes.conf"
AWG_INDEX="$1/index.tsv"
printf 'a | a.example | root@a\nb | b.example | root@b\nc | c.example | root@c\n' > "$NODES_FILE"
printf 'family\tFamily\t2026-11-21 12:00:00\n' > "$AWG_INDEX"
run_on() {
  printf '%s %s %s\n' "$@" >> "$1.trace"
  [[ "$1" != root@b ]] || return 255
  echo 'установлен'
}
awg_add() { printf 'клиент: %s, индексы: %s\n' "$1" "${*:2}"; }
cd "$1"
awg_install --port 05182 -- a b
cat root@*.trace
'''
            result = subprocess.run(["bash", "-c", script, "awg-test", tmp], cwd=ROOT,
                                    capture_output=True, text=True, check=True)
            self.assertIn("Ошибки (1)", result.stdout)
            self.assertIn("клиент: Family, индексы: 0", result.stdout)
            self.assertIn("root@a n_awg_install 5182", result.stdout)
            self.assertIn("root@b n_awg_install 5182", result.stdout)
            self.assertNotIn("root@c", result.stdout)


class RenameNode(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.write("nodes.conf", "# серверы\nold-node | 192.0.2.1 | local |\nother | 192.0.2.2 | root@host | Другая подпись\n")
        self.write("relays.conf", "old-node | other | 20001 | 443 | - | -\nother | old-node | 20002 | 443 | - | -\n")
        for folder in ("state", "ru"):
            self.write(folder + "/old-node", "ok\n")
        for block in ("server", "dpi"):
            self.write(f"audit/{block}.json", json.dumps({"nodes": {"old-node": {"checks": []}}}))
        self.write("check.last", "problems=old-node other\n")
        self.write("check.daily", "ru_nodes=2\nru_cut=old-node\n")
        self.write("awg/group/old-node.conf", "PrivateKey = секрет\n")
        self.write("awg/group/old-node.pub", "публичный ключ\n")
        self.write("hy2/group.txt", "hy2://secret@192.0.2.1:443/#old-node\n")

    def write(self, filename, text):
        path = self.base / filename
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)

    def rename(self, new="renamed"):
        return subprocess.run(["bash", "-c", 'source "$1/lib/node.sh"; BASE="$2"; cmd_node_rename old-node "$3"',
                               "test", str(ROOT), str(self.base), new], capture_output=True, text=True)

    def snapshot(self):
        return {str(p.relative_to(self.base)): p.read_bytes() for p in self.base.rglob("*") if p.is_file()}

    def test_related_records_and_keys(self):
        result = self.rename()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("renamed | 192.0.2.1 | local | old-node", (self.base / "nodes.conf").read_text())
        self.assertNotIn("old-node", (self.base / "relays.conf").read_text())
        for folder in ("state", "ru"):
            self.assertEqual((self.base / folder / "renamed").read_text(), "ok\n")
            self.assertFalse((self.base / folder / "old-node").exists())
        for block in ("server", "dpi"):
            self.assertEqual(json.loads((self.base / f"audit/{block}.json").read_text())["nodes"], {"renamed": {"checks": []}})
        self.assertEqual((self.base / "check.last").read_text(), "problems=renamed other\n")
        self.assertEqual((self.base / "check.daily").read_text(), "ru_nodes=2\nru_cut=renamed\n")
        self.assertEqual((self.base / "awg/group/old_node.conf").read_text(), "PrivateKey = секрет\n")
        self.assertTrue((self.base / "awg/group/old_node.pub").exists())
        self.assertIn("#old-node", (self.base / "hy2/group.txt").read_text())

    def test_invalid_names_do_not_change_files(self):
        before = self.snapshot()
        for name in ("other", "..", "all", "../outside", "bad\nname", "", "x" * 41):
            with self.subTest(name=name):
                self.assertNotEqual(self.rename(name).returncode, 0)
                self.assertEqual(self.snapshot(), before)

    def test_preflight_failure_does_not_change_files(self):
        self.write("audit/dpi.json", "сломан JSON")
        before = self.snapshot()
        self.assertNotEqual(self.rename().returncode, 0)
        self.assertEqual(self.snapshot(), before)

    def test_active_probe(self):
        self.write("audit/probe/session.json", json.dumps({"expires": 9999999999, "stopped": 0, "nodes": {}}))
        before = self.snapshot()
        self.assertNotEqual(self.rename().returncode, 0)
        self.assertEqual(self.snapshot(), before)

    def test_panel_validation(self):
        conf = web.read_conf(self.base / "nodes.conf", 4)
        body = {"action": "rename", "name": "old-node", "new_name": "renamed"}
        name, _, steps = web.node_steps("iof", body, conf, [], Path("unused"), None)
        self.assertEqual(name, "old-node")
        self.assertEqual(steps[0][1], ["iof", "node", "rename", "old-node", "renamed"])
        for patch, migrate in (({"new_name": "other"}, None), ({"new_name": ".."}, None), ({}, {"role": "source"})):
            with self.assertRaises(ValueError):
                web.node_steps("iof", {**body, **patch}, conf, [], Path("unused"), migrate)


class Setup(unittest.TestCase):
    def test_steps(self):
        _, steps = web.setup_steps("/usr/bin/iof", {"mode": "local", "name": "main", "addr": "vpn.example", "port": 443, "obfs": "salamander"})
        argv = steps[0][1]
        self.assertEqual(argv[:3], ["/usr/bin/iof", "setup", "--name"])
        self.assertIn("vpn.example", argv)
        self.assertIsNone(steps[0][2])
        _, steps = web.setup_steps("iof", {"mode": "template-only"})
        self.assertEqual(steps[0][1], ["iof", "setup", "--template-only"])
        for patch in ({"mode": None}, {"name": ".."}, {"addr": "localhost"}, {"addr": "127.0.0.1"},
                      {"addr": "::1"}, {"port": True}, {"port": 65536}, {"obfs": "unknown"}):
            with self.subTest(patch=patch), self.assertRaises(ValueError):
                web.setup_steps("iof", {"mode": "local", "name": "main", "addr": "vpn.example", **patch})

    def test_local_info_and_template(self):
        with tempfile.TemporaryDirectory() as folder:
            base = Path(folder)
            srv = SimpleNamespace(base=base, hy2_template=None, jobs=SimpleNamespace(busy=lambda: False), cache=Mock())
            self.assertFalse(web.setup_view(srv)["template"])
            (base / "hy2-template.yaml").write_text("auth:\n  password: secret\n")
            (base / "setup.state").write_text("mode=template-only\nphase=done\npassword=secret\n")
            info = web.setup_view(srv)
            self.assertTrue(info["template"])
            self.assertEqual(info["nodes"], 0)
            self.assertEqual(info["state"]["mode"], "template-only")
            self.assertNotIn("secret", json.dumps(info))
            srv.cache.get.assert_not_called()
            srv.hy2_template = base / "missing-explicit.yaml"
            self.assertFalse(web.setup_view(srv)["template"])

    def test_migration_blocks_api(self):
        with tempfile.TemporaryDirectory() as folder:
            base = Path(folder)
            (base / "migrate.conf").write_text("role=source\npeer=new\n")
            handler = web.Handler.__new__(web.Handler)
            handler.server = SimpleNamespace(base=base, iof="iof")
            with self.assertRaises(ValueError):
                handler.job_for("/api/setup", {"mode": "template-only"})

    def test_udp_port_conflicts(self):
        script = r'''
set -euo pipefail
source lib/common.sh; source lib/setup.sh
ss() { :; }
timeout() { shift; "$@"; }
IPT="$1"; NFT="$2"
iptables() { printf '%s\n' "$IPT"; }
nft() { printf '%s\n' "$NFT"; }
setup_port_check 443
'''
        for ipt, nft, ok in (("-A DOCKER -p tcp --dport 443 -j DNAT", "", True),
                             ("-A DOCKER -p udp --dport 443 -j DNAT", "", False),
                             ("-A PREROUTING -p udp --dports 400:500 -j REDIRECT", "", False),
                             ("", "udp dport { 443, 8443 } redirect to :9000", False),
                             ("", "tcp dport 443 redirect to :9000", True)):
            with self.subTest(ipt=ipt, nft=nft):
                result = subprocess.run(["bash", "-c", script, "port-test", ipt, nft], cwd=ROOT, capture_output=True, text=True)
                self.assertEqual(result.returncode == 0, ok, result.stderr)

    def test_cli_failed_install_retry_and_conflict(self):
        with tempfile.TemporaryDirectory() as folder:
            base = Path(folder)
            template = f"listen: :443\ntls:\n  cert: {base}/server.crt\n  key: {base}/server.key\nauth:\n  type: password\n  password: saved-secret\n"
            (base / "hy2-template.yaml").write_text(template)
            (base / "fail").touch()
            # Подмена только границы узлового установщика; реальные /etc и systemd не используются.
            source = (ROOT / "lib/setup.sh").read_text().replace("/etc/hysteria/config.yaml", str(base / "local.yaml"))
            script = r'''
set -euo pipefail
source lib/common.sh
BASE="$1"; ENV_FILE="$BASE/iof.env"; NODES_FILE="$BASE/nodes.conf"
HY2_DIR="$BASE/hy2"; STATE_DIR="$BASE/state"; SSH_KEY="$BASE/key"
MIGRATE_FILE="$BASE/migrate.conf"
source lib/remote.sh; source lib/node.sh; source lib/migrate.sh; source lib/service.sh
hy2_template_path() { printf '%s/hy2-template.yaml' "$BASE"; }
systemctl() { [[ -f "$BASE/active" ]]; }
ss() { if [[ -f "$BASE/active" ]]; then echo 'UNCONN 0 0 0.0.0.0:443 0.0.0.0:*'; fi; }
run_on() {
  if [[ ! -f "$BASE/local.yaml" ]]; then printf '%s' "$3" | base64 -d > "$BASE/local.yaml"; fi
  if [[ -f "$BASE/fail" ]]; then return 1; fi
  touch "$BASE/active"; echo installed
}
'''
            script += source + '\ncmd_setup --name main --addr vpn.example\n'
            def run():
                return subprocess.run(["bash", "-c", script, "setup-test", str(base)], cwd=ROOT, capture_output=True, text=True)
            (base / "server.crt").write_text("keep-existing-certificate")
            incomplete = run()
            self.assertNotEqual(incomplete.returncode, 0)
            self.assertEqual((base / "server.crt").read_text(), "keep-existing-certificate")
            self.assertFalse((base / "local.yaml").exists())
            (base / "server.crt").unlink()
            first = run()
            self.assertNotEqual(first.returncode, 0)
            self.assertNotIn("saved-secret", first.stdout + first.stderr)
            config = (base / "local.yaml").read_bytes()
            nodes = (base / "nodes.conf").read_bytes()
            (base / "fail").unlink()
            self.assertEqual(run().returncode, 0)
            self.assertEqual((base / "local.yaml").read_bytes(), config)
            self.assertEqual((base / "nodes.conf").read_bytes(), nodes)
            self.assertEqual((base / "hy2-template.yaml").read_text(), template)
            # После завершения остановленная неизвестная установка не восстанавливается вслепую.
            (base / "active").unlink()
            self.assertNotEqual(run().returncode, 0)
            self.assertEqual((base / "local.yaml").read_bytes(), config)
            (base / "nodes.conf").write_text("main | another.example | local | Main\n")
            conflict = run()
            self.assertNotEqual(conflict.returncode, 0)
            self.assertIn("конфликт", conflict.stderr)

    def test_cli_template_and_retry(self):
        # Подключаем функции без точки входа и подменяем только пути данных: никакого /root и SSH.
        with tempfile.TemporaryDirectory() as folder:
            base = Path(folder)
            script = r'''
set -euo pipefail
source lib/common.sh
BASE="$1"; ENV_FILE="$BASE/iof.env"; NODES_FILE="$BASE/nodes.conf"
HY2_DIR="$BASE/hy2"; STATE_DIR="$BASE/state"; SSH_KEY="$BASE/key"
MIGRATE_FILE="$BASE/migrate.conf"
source lib/remote.sh
source lib/node.sh
source lib/migrate.sh
source lib/service.sh
source lib/setup.sh
hy2_template_path() { printf '%s/hy2-template.yaml' "$BASE"; }
shift
cmd_setup "$@"
'''
            def run(*args):
                return subprocess.run(["bash", "-c", script, "setup-test", str(base), *args], cwd=ROOT, text=True, capture_output=True)
            first = run("--template-only", "--port", "8443", "--obfs", "salamander")
            self.assertEqual(first.returncode, 0, first.stdout + first.stderr)
            template = (base / "hy2-template.yaml").read_bytes()
            self.assertIn(b"listen: :8443", template)
            self.assertIn(b"salamander:", template)
            self.assertNotIn("password:", first.stdout)
            self.assertFalse(any(line.strip() and not line.startswith("#") for line in (base / "nodes.conf").read_text().splitlines()))
            second = run("--template-only", "--port", "8443", "--obfs", "salamander")
            self.assertEqual(second.returncode, 0, second.stderr)
            self.assertEqual((base / "hy2-template.yaml").read_bytes(), template)
            self.assertEqual((base / "hy2-template.yaml").stat().st_mode & 0o777, 0o600)
            self.assertNotEqual(run("--template-only", "--port", "9999").returncode, 0)
            self.assertEqual((base / "hy2-template.yaml").read_bytes(), template)
            (base / "migrate.conf").write_text("role=source\npeer=new\n")
            self.assertNotEqual(run("--template-only").returncode, 0)


if __name__ == "__main__":
    unittest.main()
