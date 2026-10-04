"""
M4 cross-service end-to-end: the real graph service answering a real dispatch.

This is the MVP flow from PRD §3, executed across two real processes worth of
code: registry-api (Node) holds identity and zones, graph-service (Python) holds
the inferred path graph, and dispatch calls both.

Run: .venv-spike/bin/python services/graph-service/test/test_e2e_dispatch.py
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request

import pytest

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
sys.path[:0] = [
    os.path.join(REPO, "spike"),
    os.path.join(REPO, "services", "graph-service", "src"),
]

from m0_ground_truth import generate_dataset  # noqa: E402

REG_PORT = 8095
GRAPH_PORT = 8096
NODE = os.path.join(REPO, "services", "registry-api")


def _req(url, payload=None, role="dispatcher", method=None):
    data = json.dumps(payload).encode() if payload is not None else None
    m = method or ("POST" if data else "GET")
    r = urllib.request.Request(
        url, data=data, method=m,
        headers={"Content-Type": "application/json", "X-Role": role},
    )
    try:
        with urllib.request.urlopen(r, timeout=20) as resp:
            return resp.status, json.loads(resp.read() or b"{}")
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read() or b"{}")


@pytest.fixture(scope="module")
def services():
    """Start both services on their real ports."""
    env = {**os.environ}
    graph_proc = subprocess.Popen(
        [sys.executable, os.path.join(REPO, "services", "graph-service", "src", "server.py")],
        env={**env, "PORT": str(GRAPH_PORT)},
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )
    reg_proc = subprocess.Popen(
        ["node", "-e",
         f"const {{createServer}}=require('{NODE}/src/server.js');"
         f"createServer().listen({REG_PORT});"],
        cwd=NODE, env=env,
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )

    def wait(url, tries=60):
        for _ in range(tries):
            try:
                urllib.request.urlopen(url, timeout=1)
                return True
            except Exception:
                time.sleep(0.2)
        return False

    ok_g = wait(f"http://127.0.0.1:{GRAPH_PORT}/v1/graph/health")
    ok_r = wait(f"http://127.0.0.1:{REG_PORT}/v1/sync/health")
    assert ok_g, "graph-service failed to start"
    assert ok_r, "registry-api failed to start"

    yield {"graph": f"http://127.0.0.1:{GRAPH_PORT}", "reg": f"http://127.0.0.1:{REG_PORT}"}

    for p in (graph_proc, reg_proc):
        p.terminate()
        try:
            p.wait(timeout=5)
        except Exception:
            p.kill()


@pytest.fixture(scope="module")
def built_graph(services):
    """Build a graph from the campus traces, through the real HTTP API."""
    gt, traces = generate_dataset(seed=7)
    payload = {"traces": [{"noisy": t.noisy} for t in traces]}
    status, body = _req(f"{services['graph']}/v1/graph/rebuild", payload, role="admin")
    assert status == 200, body
    return gt


# ---------------------------------------------------------------------------


def test_graph_service_reports_inference_not_ground_truth(services):
    status, body = _req(f"{services['graph']}/v1/graph/health")
    assert status == 200
    assert body["evidence_class"] == "inference"
    assert body["state"] == "candidate"
    assert body["approved_algorithm"] == "hybrid_mapmatch_delaunay"


def test_rebuild_publishes_a_new_version(services, built_graph):
    status, body = _req(f"{services['graph']}/v1/graph/health")
    assert status == 200
    assert body["graph_version"] == 1
    assert body["nodes"] > 0 and body["edges"] > 0
    assert body["building"] is False


def test_only_the_approved_algorithm_serves_routes(services, built_graph):
    """C9: a comparison build may not serve dispatch routes."""
    gt, traces = generate_dataset(seed=13)
    status, body = _req(
        f"{services['graph']}/v1/graph/rebuild",
        {"algorithm": "kmeans_delaunay", "traces": [{"noisy": t.noisy} for t in traces]},
        role="admin",
    )
    assert status == 200
    assert body["approved"] is False
    assert body["serves_routes"] is False, "an unapproved build must not serve routes"


def test_routing_over_http_refuses_a_fabricated_path(services, built_graph):
    status, body = _req(
        f"{services['graph']}/v1/graph/route",
        {"from": {"lat": 9999.0, "lon": 9999.0}, "to": {"lat": 9998.0, "lon": 9998.0}},
        role="dispatcher",
    )
    # outside the mapped network: refused, never snapped to the nearest node
    assert status == 422
    assert body["error"] == "no_route"
    assert any("outside_mapped_network" in w for w in body["warnings"])


def test_route_inside_the_network_succeeds_and_flags_inference(services, built_graph):
    gt = built_graph
    start, end = gt.destinations[0][:2], gt.destinations[5][:2]
    status, body = _req(
        f"{services['graph']}/v1/graph/route",
        {"from": {"lat": start[0], "lon": start[1]},
         "to": {"lat": end[0], "lon": end[1]}, "profile": "foot"},
        role="dispatcher",
    )
    assert status == 200, body
    assert body["reachable"] is True
    # pin whatever version the registry currently serves — a prior test may
    # legitimately have published a later one
    _st, health = _req(f"{services['graph']}/v1/graph/health")
    assert body["graph_version"] == health["graph_version"]
    assert body["unverified_legs"] == len(body["legs"]) > 0
    assert any("INFERRED" in w for w in body["warnings"]), \
        "a responder must be told the path is machine-inferred (C8)"


def test_segments_are_all_candidates(services, built_graph):
    status, body = _req(f"{services['graph']}/v1/graph/segments")
    assert status == 200
    segs = body["segments"]
    assert len(segs) > 0
    for s in segs:
        assert s["evidence_class"] == "inference"
        assert s["state"] == "candidate"
        assert s["passable"] is None, "passability stays unknown until observed"
        assert s["algorithm"] == "hybrid_mapmatch_delaunay"


# ---------------------------------------------------------------------------
# The MVP dispatch flow, across both services
# ---------------------------------------------------------------------------

def test_C7_blocks_dispatch_until_the_zone_is_enabled(services):
    """C7 end to end: a valid code is still refused outside an enabled zone.

    Runs against its own registry state so it cannot be skipped by ordering.
    """
    st, zones = _req(f"{services['reg']}/v1/zones", role="admin")
    enabled = [z for z in zones.get("zones", []) if z.get("dispatch_enabled")]
    if enabled:
        pytest.fail(
            "zone is dispatch-enabled, so the C7 refusal cannot be demonstrated; "
            "the pilot default must be disabled"
        )

    # Two structures a few metres apart, so the second one generates a dedup
    # candidate and can receive a code from the reviewer's decision. A code is
    # ONLY ever issued that way (C1), so the test has to go through review.
    st, push = _req(f"{services['reg']}/v1/sync/push", {
        "device_id": "e2e-c7",
        "ops": [
            {"clientOpId": "e2e-c7-a", "clientSeq": 1,
             "table": "local_structure", "op": "create",
             "payload": {"centroid": {"lat": 12.9700, "lon": 77.5900},
                         "structure_type": "standalone_dwelling"}},
            {"clientOpId": "e2e-c7-b", "clientSeq": 2,
             "table": "local_structure", "op": "create",
             "payload": {"centroid": {"lat": 12.97005, "lon": 77.59005},
                         "structure_type": "shared_wall_dwelling",
                         "entrance_independent": True}},
        ],
    }, role="mapper")
    assert st == 200, push
    assert push["results"][0]["state"] == "applied"
    # the second pin is close enough to generate a dedup candidate
    assert push["results"][1]["state"] == "dedup_required", push
    sid = push["results"][1]["serverId"]

    # issue a code the way a dedup decision would
    st, dec = _req(f"{services['reg']}/v1/dedup", None, role="reviewer")
    code = None
    for item in dec.get("items", []):
        if sid in (item.get("structure_a"), item.get("structure_b")):
            st, res = _req(f"{services['reg']}/v1/dedup/{item['id']}/decision",
                           {"decision": "distinct",
                            "classification": {"structureType": "shared_wall_dwelling",
                                               "entranceIndependent": True}},
                           role="reviewer")
            assert st == 200, res
            code = res.get("code")
            break
    assert code, f"could not obtain a code for {sid}"

    # C7: refused, even though the code is valid and the structure is real
    st, look = _req(f"{services['reg']}/v1/dispatch/lookup", {"code": code}, role="dispatcher")
    assert st == 403, look
    assert look["error"] == "outside_mapped_zone"
