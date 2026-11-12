"""
graph-service HTTP surface.

Exposes routing over the inferred graph. Every response carries the
`graph_version` it was computed against: a dispatch call pins one version for
its whole life, so a rebuild never serves a half-built graph.

Holds NO database credentials. It builds from breadcrumbs and holds candidates
only, so it cannot write structure identity (C1) or ground truth (C8).

Run:  .venv-spike/bin/python services/graph-service/src/server.py
"""

from __future__ import annotations

import json
import os
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import urllib.request  # noqa: E402

from geo import InsufficientBreadcrumbs, build_graph_latlon, group_breadcrumbs  # noqa: E402
from hybrid import ALGORITHM as APPROVED_ALGORITHM, build_graph   # noqa: E402
from routing import GraphRegistry, route_latlon                 # noqa: E402

PORT = int(os.environ.get("PORT", "8092"))

# A rebuild publishes a NEW version rather than mutating in place, so an
# in-flight routing call keeps reading the version it started with.
registry = GraphRegistry()
building = False


class Handler(BaseHTTPRequestHandler):
    def _send(self, code, payload):
        body = json.dumps(payload).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format, *args):  # noqa: A002
        pass  # keep the test output readable

    def do_OPTIONS(self):
        self._send(204, {})

    def do_GET(self):
        path = self.path.split("?")[0]

        if path == "/v1/graph/health":
            g = registry.get()
            self._send(200, {
                "graph_version": registry.latest_version,
                "known_versions": registry.known_versions(),
                "building": building,
                "approved_algorithm": APPROVED_ALGORITHM,
                "nodes": g.n_nodes if g else 0,
                "edges": g.n_edges if g else 0,
                # Inference, never ground truth (C8)
                "evidence_class": "inference",
                "state": "candidate",
            })
            return

        if path == "/v1/graph/segments":
            g = registry.get()
            if g is None:
                self._send(503, {"error": "no_graph_available"})
                return
            self._send(200, {
                "graph_version": g.build_version,
                "algorithm": g.stats["algorithm"],
                "segments": [e.to_dict() for e in g.edges],
            })
            return

        self._send(404, {"error": "not_found", "path": path})

    def do_POST(self):
        global building

        path = self.path.split("?")[0]
        length = int(self.headers.get("Content-Length") or 0)
        try:
            body = json.loads(self.rfile.read(length) or b"{}")
        except json.JSONDecodeError:
            self._send(400, {"error": "invalid_json"})
            return

        # ---- route ---------------------------------------------------------
        if path == "/v1/graph/route":
            frm, to = body.get("from"), body.get("to")
            if not frm or not to:
                self._send(400, {"error": "missing_from_or_to"})
                return

            # A rebuild in progress must not serve a half-built graph.
            if building:
                self._send(503, {
                    "error": "graph_rebuilding",
                    "retry_after": 5,
                    "graph_version": registry.latest_version,
                })
                return

            g = registry.get(body.get("graph_version"))
            if g is None:
                self._send(503, {"error": "no_graph_available",
                                 "detail": "no graph has been built yet"})
                return

            r = route_latlon(g, frm, to,
                             profile=body.get("profile", "foot"),
                             confidence_floor=body.get("confidence_floor", 0.0))

            if not r.reachable:
                # Honest failure: never a fabricated path.
                self._send(422, {
                    "error": "no_route",
                    "detail": "; ".join(r.warnings) or "no path in the current graph",
                    "graph_version": g.build_version,
                    "warnings": r.warnings,
                })
                return
            self._send(200, r.to_dict())
            return

        # ---- rebuild -------------------------------------------------------
        if path == "/v1/graph/rebuild":
            algorithm = body.get("algorithm", APPROVED_ALGORITHM)
            compare_only = algorithm != APPROVED_ALGORITHM

            if building:
                self._send(409, {"error": "build_in_progress"})
                return

            # Production: {"source": "registry"} pulls the mappers' breadcrumbs
            # (lat/lon). Raw {"traces": [{noisy: [[x,y], ...]}]} stays for
            # metric spike/test inputs.
            latlon = None
            raw = None
            if body.get("source") == "registry":
                reg_url = os.environ.get("REGISTRY_URL")
                if not reg_url:
                    self._send(400, {"error": "registry_url_not_configured",
                                     "detail": "set REGISTRY_URL to rebuild from breadcrumbs"})
                    return
                try:
                    with urllib.request.urlopen(
                            f"{reg_url.rstrip('/')}/v1/breadcrumbs?limit=100000", timeout=30) as resp:
                        latlon = group_breadcrumbs(json.loads(resp.read()).get("points", []))
                except Exception as e:  # noqa: BLE001
                    self._send(502, {"error": "registry_unreachable", "detail": str(e)})
                    return
            else:
                raw = body.get("traces")
                if not raw:
                    self._send(400, {
                        "error": "missing_traces",
                        "detail": "production builds consume breadcrumbs",
                    })
                    return

            building = True
            try:
                next_version = (registry.latest_version or 0) + 1
                if latlon is not None:
                    g = build_graph_latlon(latlon, build_version=next_version)
                else:
                    g = build_graph([_Trace(t) for t in raw], build_version=next_version)
                registry.publish(g)
            except InsufficientBreadcrumbs as e:
                self._send(422, {"error": "insufficient_breadcrumbs", "detail": str(e)})
                return
            finally:
                building = False

            self._send(200, {
                "graph_version": g.build_version,
                "algorithm": g.stats["algorithm"],
                "approved": not compare_only,
                # C9: only the approved algorithm may serve dispatch routes.
                "serves_routes": not compare_only,
                "stats": g.stats,
                "build_seconds": round(g.build_seconds, 3),
            })
            return

        self._send(404, {"error": "not_found", "path": path})


class _Trace:
    """Minimal shape the builder needs: `.noisy` is an (n,2) array."""

    __slots__ = ("noisy",)

    def __init__(self, raw):
        import numpy as np

        pts = raw.get("noisy") if isinstance(raw, dict) else raw
        self.noisy = np.asarray(pts, dtype=float)


def create_server(port=0):
    return HTTPServer(("127.0.0.1", port), Handler)


if __name__ == "__main__":
    srv = create_server(PORT)
    print(f"graph-service on :{PORT}")
    srv.serve_forever()