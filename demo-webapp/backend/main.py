"""
Demo webapp — backend proxy (FastAPI).
No tiene lógica de negocio propia, solo reenvía al balanceador+coordinador.
Sirve una lista fija de posts en memoria.
"""

import logging
import os
import sys
import uuid

import httpx
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    handlers=[logging.StreamHandler(sys.stdout)],
)
log = logging.getLogger("demo-backend")

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
BALANCEADOR_URL = os.getenv("BALANCEADOR_URL", "http://192.168.1.100:8080")

# ---------------------------------------------------------------------------
# Posts fijos en memoria (spec-demo-webapp §1)
# ---------------------------------------------------------------------------
POSTS = [
    {"id": "post-1", "autor": "ana", "texto": "Mi primer post"},
    {"id": "post-2", "autor": "luis", "texto": "Otro post de prueba"},
    {"id": "post-3", "autor": "maria", "texto": "Sistemas distribuidos son geniales"},
]

# ---------------------------------------------------------------------------
# App
# ---------------------------------------------------------------------------
app = FastAPI(title="Demo Webapp — Backend Proxy")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

# ---------------------------------------------------------------------------
# Endpoints
# ---------------------------------------------------------------------------

@app.get("/posts")
def get_posts():
    """Devuelve la lista fija de posts."""
    return POSTS


@app.post("/posts/{post_id}/like")
async def like_post(post_id: str):
    """Genera like_id (uuid4) y reenvía al balanceador."""
    like_id = str(uuid.uuid4())
    async with httpx.AsyncClient(timeout=5.0) as client:
        try:
            resp = await client.post(
                f"{BALANCEADOR_URL}/like",
                json={"post_id": post_id, "like_id": like_id},
            )
            return resp.json()
        except Exception as exc:
            return {"error": str(exc)}


@app.get("/posts/{post_id}/likes")
async def get_post_likes(post_id: str):
    """Reenvía la lectura de likes al balanceador."""
    async with httpx.AsyncClient(timeout=5.0) as client:
        try:
            resp = await client.get(f"{BALANCEADOR_URL}/likes/{post_id}")
            return resp.json()
        except Exception as exc:
            return {"error": str(exc)}


@app.get("/status")
async def get_status():
    """Reenvía el estado del clúster desde el balanceador."""
    async with httpx.AsyncClient(timeout=5.0) as client:
        try:
            resp = await client.get(f"{BALANCEADOR_URL}/status")
            return resp.json()
        except Exception as exc:
            return {"error": str(exc)}


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=3001, log_level="info")
