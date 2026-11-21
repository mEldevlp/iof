#!/usr/bin/env python3
"""Проверки ссылок, панели и локальных команд без SSH и настоящего Telegram."""
import base64
import html
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import Mock
import zlib

ROOT = Path(__file__).resolve().parents[1]
sys.dont_write_bytecode = True


def module(name, path):
    spec = importlib.util.spec_from_file_location(name, ROOT / path)
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


bot = module("iof_bot", "web/iof_bot.py")
web = module("iof_web", "web/iof-web.py")


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
            handler.server = SimpleNamespace(base=base, hosts={"localhost"}, password="test")
            handler.path = "/api/awg/keys?name=family"
            handler.headers = {"Host": "localhost"}
            handler.send_response, handler.send_header, handler.end_headers = Mock(), Mock(), Mock()
            handler.send_body = Mock()
            handler.do_GET()
            handler.send_response.assert_called_once_with(401)
            handler.send_body.assert_not_called()
            handler.headers["Authorization"] = "Basic " + base64.b64encode(b"iof:test").decode()
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
