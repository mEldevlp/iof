#!/usr/bin/env python3
"""Проверки выдачи группы ботом и переименования узла без SSH и настоящего Telegram."""
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
