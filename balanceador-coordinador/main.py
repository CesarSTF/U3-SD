"""
Balanceador + Coordinador — máquina 1.
Componente único: round robin, circuit breaker por nodo, lógica de cuórum.
Stateless salvo NodeState[] en memoria y rr_index.
"""

import asyncio
import logging
import sys
import time
from contextlib import asynccontextmanager
from enum import Enum

import httpx
import yaml
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    handlers=[logging.StreamHandler(sys.stdout)],
)
log = logging.getLogger("coordinador")

# ---------------------------------------------------------------------------
# Config — lee de variables de entorno (Docker) o de config.yaml (producción)
# ---------------------------------------------------------------------------
import os

def _load_config():
    if os.getenv("NODES"):
        # Modo Docker: config por variables de entorno
        nodes_cfg = []
        for pair in os.getenv("NODES", "").split(","):
            if ":" not in pair:
                continue
            parts = pair.split(":", 1)
            node_id = parts[0]
            url = parts[1]
            from urllib.parse import urlparse
            parsed = urlparse(url)
            nodes_cfg.append({"id": node_id, "host": parsed.hostname, "port": parsed.port or 8081})
        return {
            "nodes": nodes_cfg,
            "quorum": {"W": 2, "R": 2},
            "heartbeat": {
                "interval_ms": 2000, "timeout_ms": 800,
                "failure_threshold": 3, "half_open_after_ms": 5000, "max_lag_seq": 0,
            },
            "request": {"write_timeout_ms": 1500, "read_timeout_ms": 1000},
        }
    else:
        with open("config.yaml") as f:
            return yaml.safe_load(f)

CFG = _load_config()
NODES_CFG = CFG["nodes"]
W = CFG["quorum"]["W"]
R = CFG["quorum"]["R"]

HB_INTERVAL = CFG["heartbeat"]["interval_ms"] / 1000.0
HB_TIMEOUT = CFG["heartbeat"]["timeout_ms"] / 1000.0
FAILURE_THRESHOLD = CFG["heartbeat"]["failure_threshold"]
HALF_OPEN_AFTER = CFG["heartbeat"]["half_open_after_ms"] / 1000.0
MAX_LAG_SEQ = CFG["heartbeat"]["max_lag_seq"]

WRITE_TIMEOUT = CFG["request"]["write_timeout_ms"] / 1000.0
READ_TIMEOUT = CFG["request"]["read_timeout_ms"] / 1000.0

# ---------------------------------------------------------------------------
# Estado interno por nodo (spec §2)
# ---------------------------------------------------------------------------

class Circuit(str, Enum):
    CLOSED = "CLOSED"
    OPEN = "OPEN"
    HALF_OPEN = "HALF_OPEN"


class NodeState:
    def __init__(self, node_cfg: dict):
        self.id: str = node_cfg["id"]
        self.host: str = node_cfg["host"]
        self.port: int = node_cfg["port"]
        self.circuit: Circuit = Circuit.CLOSED
        self.consecutive_failures: int = 0
        self.last_heartbeat_at: float = 0.0
        self.last_known_seq: int = 0
        self._opened_at: float = 0.0  # timestamp de cuándo pasó a OPEN

    @property
    def base_url(self) -> str:
        return f"http://{self.host}:{self.port}"

    def to_dict(self) -> dict:
        return {
            "id": self.id,
            "circuit": self.circuit.value,
            "seq": self.last_known_seq,
        }


nodes: list[NodeState] = [NodeState(n) for n in NODES_CFG]
rr_index: int = 0

# ---------------------------------------------------------------------------
# Circuit breaker — heartbeats (spec §3)
# ---------------------------------------------------------------------------

async def heartbeat_loop():
    """Hilo async que hace ping a cada nodo cada HB_INTERVAL."""
    async with httpx.AsyncClient(timeout=HB_TIMEOUT) as client:
        while True:
            tasks = [_heartbeat_one(client, node) for node in nodes]
            await asyncio.gather(*tasks, return_exceptions=True)
            await asyncio.sleep(HB_INTERVAL)


async def _heartbeat_one(client: httpx.AsyncClient, node: NodeState):
    now = time.time()

    if node.circuit == Circuit.OPEN:
        # Esperar half_open_after_ms antes de probar
        if now - node._opened_at < HALF_OPEN_AFTER:
            return
        node.circuit = Circuit.HALF_OPEN
        log.info("Nodo %s: OPEN -> HALF_OPEN (probando)", node.id)

    try:
        resp = await client.get(f"{node.base_url}/health")
        resp.raise_for_status()
        data = resp.json()
        peer_seq = data.get("seq", 0)
        node.last_heartbeat_at = now
        node.last_known_seq = peer_seq

        if node.circuit == Circuit.HALF_OPEN:
            # Validar que ya está al día
            max_active_seq = max(
                (n.last_known_seq for n in nodes if n.circuit == Circuit.CLOSED),
                default=0,
            )
            if peer_seq >= max_active_seq - MAX_LAG_SEQ:
                node.circuit = Circuit.CLOSED
                node.consecutive_failures = 0
                log.info("Nodo %s: HALF_OPEN -> CLOSED (sincronizado, seq=%d)", node.id, peer_seq)
            else:
                log.info(
                    "Nodo %s: sigue HALF_OPEN (seq=%d, necesita >=%d)",
                    node.id, peer_seq, max_active_seq - MAX_LAG_SEQ,
                )
        else:
            # CLOSED — heartbeat OK
            node.consecutive_failures = 0

    except Exception as exc:
        if node.circuit == Circuit.HALF_OPEN:
            node.circuit = Circuit.OPEN
            node._opened_at = time.time()
            log.warning("Nodo %s: HALF_OPEN -> OPEN (falló heartbeat: %s)", node.id, exc)
            return

        node.consecutive_failures += 1
        if node.consecutive_failures >= FAILURE_THRESHOLD:
            if node.circuit != Circuit.OPEN:
                node.circuit = Circuit.OPEN
                node._opened_at = time.time()
                log.warning(
                    "Nodo %s: CLOSED -> OPEN (%d fallos consecutivos)",
                    node.id, node.consecutive_failures,
                )

# ---------------------------------------------------------------------------
# Round robin (spec §4)
# ---------------------------------------------------------------------------

def get_ordered_active() -> list[NodeState]:
    """Devuelve los nodos activos (CLOSED) ordenados por round robin."""
    global rr_index
    active = [n for n in nodes if n.circuit == Circuit.CLOSED]
    if not active:
        return []
    rr_index = (rr_index + 1) % len(active)
    return active[rr_index:] + active[:rr_index]

# ---------------------------------------------------------------------------
# Lifespan
# ---------------------------------------------------------------------------

@asynccontextmanager
async def lifespan(app: FastAPI):
    task = asyncio.create_task(heartbeat_loop())
    log.info("Heartbeat loop iniciado.")
    yield
    task.cancel()

app = FastAPI(title="Balanceador + Coordinador", lifespan=lifespan)

# CORS para la demo webapp
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

# ---------------------------------------------------------------------------
# Modelos
# ---------------------------------------------------------------------------

class LikeRequest(BaseModel):
    post_id: str
    like_id: str

# ---------------------------------------------------------------------------
# Path de escritura — POST /like (spec §5)
# ---------------------------------------------------------------------------

@app.post("/like")
async def post_like(req: LikeRequest):
    ordered = get_ordered_active()
    if len(ordered) < W:
        from fastapi.responses import JSONResponse
        return JSONResponse(
            status_code=503,
            content={"error": "no hay cuorum de escritura disponible"},
        )

    # Fan-out paralelo a todos los activos, cortar apenas se junten W confirmaciones
    async with httpx.AsyncClient(timeout=WRITE_TIMEOUT) as client:
        pending = {
            asyncio.ensure_future(
                client.post(f"{node.base_url}/write", json={"post_id": req.post_id, "like_id": req.like_id})
            )
            for node in ordered
        }
        confirmations = []
        deadline = time.time() + WRITE_TIMEOUT

        while pending and len(confirmations) < W:
            remaining = deadline - time.time()
            if remaining <= 0:
                break
            done, pending = await asyncio.wait(pending, timeout=remaining, return_when=asyncio.FIRST_COMPLETED)
            for task in done:
                try:
                    resp = task.result()
                    if resp.status_code == 200:
                        confirmations.append(resp.json())
                except Exception:
                    pass

        # Dejar las tareas pendientes corriendo en segundo plano (no cancelar)
        for task in pending:
            asyncio.ensure_future(task)

    if len(confirmations) >= W:
        best = max(confirmations, key=lambda c: c.get("seq", 0))
        return {"ok": True, "seq": best["seq"]}
    else:
        from fastapi.responses import JSONResponse
        return JSONResponse(
            status_code=503,
            content={"error": "no se alcanzo cuorum a tiempo"},
        )

# ---------------------------------------------------------------------------
# Path de lectura — GET /likes/{post_id} (spec §6)
# ---------------------------------------------------------------------------

@app.get("/likes/{post_id}")
async def get_likes(post_id: str):
    ordered = get_ordered_active()
    if len(ordered) < R:
        from fastapi.responses import JSONResponse
        return JSONResponse(
            status_code=503,
            content={"error": "no hay cuorum de lectura disponible"},
        )

    # Enviar a los primeros R nodos de ordered
    targets = ordered[:R]
    async with httpx.AsyncClient(timeout=READ_TIMEOUT) as client:
        tasks = [
            client.get(f"{node.base_url}/read", params={"post_id": post_id})
            for node in targets
        ]
        results = await asyncio.gather(*tasks, return_exceptions=True)

    responses = []
    for r in results:
        if isinstance(r, Exception):
            continue
        if hasattr(r, "status_code") and r.status_code == 200:
            responses.append(r.json())

    if len(responses) < R:
        from fastapi.responses import JSONResponse
        return JSONResponse(
            status_code=503,
            content={"error": "no se alcanzo cuorum de lectura a tiempo"},
        )

    # La respuesta más fresca (mayor seq para este post_id)
    best = max(responses, key=lambda r: r.get("seq", 0))
    return {"count": best["count"], "seq": best["seq"]}

# ---------------------------------------------------------------------------
# Observabilidad — GET /status (spec §7)
# ---------------------------------------------------------------------------

@app.get("/status")
def status():
    return {"nodes": [n.to_dict() for n in nodes]}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8080, log_level="info")
