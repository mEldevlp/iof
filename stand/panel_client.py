"""Получает cookie тестового администратора локального стенда."""

import json
import urllib.request


def panel_cookie(base):
    request = urllib.request.Request(
        base + "/api/login", data=json.dumps({"login": "admin", "password": "iof-stand-panel"}).encode(),
        headers={"Content-Type": "application/json", "X-IOF-Request": "1", "Origin": base})
    with urllib.request.urlopen(request, timeout=20) as response:
        return response.headers["Set-Cookie"].split(";", 1)[0]
