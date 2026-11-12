"""Demo MVP: lat/lon in, metres inside, lat/lon legs out."""

from __future__ import annotations

import math
import os
import sys

import pytest

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
sys.path.insert(0, os.path.join(REPO, "services", "graph-service", "src"))

from geo import (InsufficientBreadcrumbs, build_graph_latlon,  # noqa: E402
                 group_breadcrumbs, project, unproject)
from routing import route_latlon  # noqa: E402


def test_project_roundtrip_and_scale():
    o = (12.97, 77.59)
    x, y = project(12.97 + 0.001, 77.59 + 0.001, o)
    assert abs(y - 110.54) < 0.01
    assert abs(x - 111.32 * math.cos(math.radians(12.97))) < 0.01
    lat, lon = unproject(x, y, o)
    assert abs(lat - 12.971) < 1e-9 and abs(lon - 77.591) < 1e-9


def test_group_breadcrumbs_orders_and_drops_short():
    pts = [{"trace_id": "a", "seq": 1, "lat": 1.1, "lon": 2.1},
           {"trace_id": "a", "seq": 0, "lat": 1.0, "lon": 2.0},
           {"trace_id": "b", "seq": 0, "lat": 5.0, "lon": 5.0}]
    assert group_breadcrumbs(pts) == [[(1.0, 2.0), (1.1, 2.1)]]


def _lane(lat0, lon0, n=60, step_m=2.0):
    # straight north-south walk, ~2 m spacing
    return [(lat0 + i * step_m / 110540, lon0) for i in range(n)]


def test_latlon_route_on_a_walked_lane():
    g = build_graph_latlon([_lane(12.97, 77.59), _lane(12.97, 77.59 + 1e-6)], build_version=1)
    r = route_latlon(g, {"lat": 12.97, "lon": 77.59}, {"lat": 12.97 + 100 / 110540, "lon": 77.59})
    assert r.reachable
    assert 80 < r.total_distance_m < 130
    d = r.to_dict()
    assert {"lat", "lon"} <= d["legs"][0]["from"].keys()


def test_far_destination_is_refused_in_metres():
    g = build_graph_latlon([_lane(12.97, 77.59)], build_version=1)
    # ~100 m east of the lane
    r = route_latlon(g, {"lat": 12.97, "lon": 77.59}, {"lat": 12.97, "lon": 77.59 + 100 / 108500})
    assert not r.reachable
    assert any("outside_mapped_network" in w for w in r.warnings)


def test_too_few_breadcrumbs_raises():
    with pytest.raises(InsufficientBreadcrumbs):
        build_graph_latlon([_lane(12.97, 77.59, n=5)], build_version=1)


# --------------------------------------------------------------------------
# HTTP: rebuild from the registry, route in lat/lon
# --------------------------------------------------------------------------

import json  # noqa: E402
import threading  # noqa: E402
import urllib.error  # noqa: E402
import urllib.request  # noqa: E402
from http.server import BaseHTTPRequestHandler, HTTPServer  # noqa: E402

import server as graph_server  # noqa: E402


def _serve(httpd):
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    return f"http://127.0.0.1:{httpd.server_address[1]}"


def _fake_registry(points):
    class H(BaseHTTPRequestHandler):
        def do_GET(self):
            body = json.dumps({"points": points}).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *a):
            pass
    return _serve(HTTPServer(("127.0.0.1", 0), H))


def _post(url, payload):
    req = urllib.request.Request(url, data=json.dumps(payload).encode(), method="POST",
                                 headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            return r.status, json.loads(r.read())
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read())


def _rows(trace_id, lane):
    return [{"trace_id": trace_id, "seq": i, "lat": la, "lon": lo} for i, (la, lo) in enumerate(lane)]


def test_rebuild_from_registry_then_route_in_latlon(monkeypatch):
    pts = _rows("a", _lane(12.97, 77.59)) + _rows("b", _lane(12.97, 77.59 + 1e-6))
    monkeypatch.setenv("REGISTRY_URL", _fake_registry(pts))
    base = _serve(graph_server.create_server(0))
    code, out = _post(f"{base}/v1/graph/rebuild", {"source": "registry"})
    assert code == 200, out
    code, out = _post(f"{base}/v1/graph/route", {
        "from": {"lat": 12.97, "lon": 77.59},
        "to": {"lat": 12.97 + 100 / 110540, "lon": 77.59}})
    assert code == 200, out
    assert {"lat", "lon"} <= out["legs"][0]["from"].keys()


def test_rebuild_with_too_few_breadcrumbs_is_422(monkeypatch):
    monkeypatch.setenv("REGISTRY_URL", _fake_registry(_rows("a", _lane(12.97, 77.59, n=5))))
    base = _serve(graph_server.create_server(0))
    code, out = _post(f"{base}/v1/graph/rebuild", {"source": "registry"})
    assert code == 422
    assert out["error"] == "insufficient_breadcrumbs"


def test_rebuild_from_registry_needs_registry_url(monkeypatch):
    monkeypatch.delenv("REGISTRY_URL", raising=False)
    base = _serve(graph_server.create_server(0))
    code, out = _post(f"{base}/v1/graph/rebuild", {"source": "registry"})
    assert code == 400
    assert out["error"] == "registry_url_not_configured"
