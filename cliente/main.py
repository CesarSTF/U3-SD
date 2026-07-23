"""
Cliente — generador de tráfico concurrente.
Simula N usuarios en paralelo mandando likes y lecturas al balanceador.
Genera un CSV con timestamp, tipo, post_id, status_http, latencia_ms, detalle.
"""

import asyncio
import csv
import logging
import random
import sys
import time
import uuid
from datetime import datetime, timezone

import httpx
import yaml

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    handlers=[logging.StreamHandler(sys.stdout)],
)
log = logging.getLogger("cliente")

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
with open("config.yaml") as f:
    CFG = yaml.safe_load(f)

BASE_URL = CFG["target"]["base_url"]
CONCURRENT = CFG["load"]["concurrent_clients"]
DURATION = CFG["load"]["duration_s"]
WRITE_RATIO = CFG["load"]["write_ratio"]
POST_IDS = CFG["load"]["post_ids"]
LOG_FILE = CFG["output"]["log_file"]

# ---------------------------------------------------------------------------
# Log CSV compartido (thread-safe con asyncio.Lock)
# ---------------------------------------------------------------------------

csv_lock = asyncio.Lock()
csv_file = None
csv_writer = None


def init_csv():
    global csv_file, csv_writer
    csv_file = open(LOG_FILE, "w", newline="", encoding="utf-8")
    csv_writer = csv.writer(csv_file)
    csv_writer.writerow(["timestamp", "tipo", "post_id", "status_http", "latencia_ms", "detalle"])


async def log_result(ts: str, tipo: str, post_id: str, status: int, latencia_ms: float, detalle: str):
    async with csv_lock:
        csv_writer.writerow([ts, tipo, post_id, status, f"{latencia_ms:.1f}", detalle])
        csv_file.flush()

# ---------------------------------------------------------------------------
# Worker — un "cliente simulado"
# ---------------------------------------------------------------------------

async def worker(client: httpx.AsyncClient, end_time: float, worker_id: int):
    """Loop fire-as-fast-as-possible mientras no se cumpla duration_s."""
    ops = 0
    while time.time() < end_time:
        post_id = random.choice(POST_IDS)
        ts = datetime.now(timezone.utc).isoformat(timespec="milliseconds")

        if random.random() < WRITE_RATIO:
            # --- WRITE ---
            like_id = str(uuid.uuid4())
            t0 = time.time()
            try:
                resp = await client.post(
                    f"{BASE_URL}/like",
                    json={"post_id": post_id, "like_id": like_id},
                )
                elapsed = (time.time() - t0) * 1000
                body = resp.text
                detalle = ""
                try:
                    data = resp.json()
                    if "seq" in data:
                        detalle = f"seq={data['seq']}"
                    elif "error" in data:
                        detalle = data["error"]
                except Exception:
                    detalle = body[:100]
                await log_result(ts, "write", post_id, resp.status_code, elapsed, detalle)
            except Exception as exc:
                elapsed = (time.time() - t0) * 1000
                await log_result(ts, "write", post_id, 0, elapsed, str(exc)[:100])
        else:
            # --- READ ---
            t0 = time.time()
            try:
                resp = await client.get(f"{BASE_URL}/likes/{post_id}")
                elapsed = (time.time() - t0) * 1000
                detalle = ""
                try:
                    data = resp.json()
                    if "count" in data:
                        detalle = f"count={data['count']},seq={data.get('seq', '?')}"
                    elif "error" in data:
                        detalle = data["error"]
                except Exception:
                    detalle = resp.text[:100]
                await log_result(ts, "read", post_id, resp.status_code, elapsed, detalle)
            except Exception as exc:
                elapsed = (time.time() - t0) * 1000
                await log_result(ts, "read", post_id, 0, elapsed, str(exc)[:100])

        ops += 1

    log.info("Worker %d terminó (%d operaciones).", worker_id, ops)

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

async def main():
    init_csv()
    log.info(
        "Iniciando %d clientes concurrentes durante %ds contra %s",
        CONCURRENT, DURATION, BASE_URL,
    )
    log.info("Write ratio: %.0f%%, Posts: %s", WRITE_RATIO * 100, POST_IDS)
    log.info("Resultados en: %s", LOG_FILE)

    end_time = time.time() + DURATION

    async with httpx.AsyncClient(timeout=5.0) as client:
        tasks = [worker(client, end_time, i) for i in range(CONCURRENT)]
        await asyncio.gather(*tasks)

    csv_file.close()

    # Resumen rápido
    total_ops = 0
    ok_ops = 0
    with open(LOG_FILE, "r") as f:
        reader = csv.DictReader(f)
        for row in reader:
            total_ops += 1
            if row["status_http"] == "200":
                ok_ops += 1

    log.info("=== RESUMEN ===")
    log.info("Total operaciones: %d", total_ops)
    log.info("Exitosas (200): %d (%.1f%%)", ok_ops, (ok_ops / total_ops * 100) if total_ops else 0)
    log.info("Fallidas: %d", total_ops - ok_ops)


if __name__ == "__main__":
    asyncio.run(main())
