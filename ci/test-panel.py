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


if __name__ == "__main__":
    unittest.main()
