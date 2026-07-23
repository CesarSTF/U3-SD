#!/usr/bin/env bash
#
# test_3_nodos.sh — Prueba de integración local: 3 instancias de likes-service
#
# Simula las 3 máquinas en localhost con puertos 8081/8082/8083 y BDs separadas.
# Pasos:
#   1. Crea 3 BDs en Postgres local
#   2. Levanta 3 instancias del JAR
#   3. Escribe likes (con duplicados para generar gaps en BIGSERIAL)
#   4. Mata una instancia
#   5. Escribe más likes (cuórum W=2 sigue funcionando)
#   6. Levanta la instancia caída (resync)
#   7. Compara los 3 Postgres — deben tener el mismo count
#
# Uso:
#   cd likes-service/
#   chmod +x test_3_nodos.sh
#   ./test_3_nodos.sh
#
# Prerequisito: Postgres corriendo, usuario "user" con password "pass" creado.
# Si las BDs ya existen de una prueba anterior, las dropea y recrea.

set -e

JAR="target/likes-service-1.0.0.jar"
PGUSER="user"
PGPASS="pass"
export PGPASSWORD="$PGPASS"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

log() { echo -e "${CYAN}[TEST]${NC} $1"; }
ok()  { echo -e "${GREEN}  ✓${NC} $1"; }
err() { echo -e "${RED}  ✗${NC} $1"; }
warn(){ echo -e "${YELLOW}  ⚠${NC} $1"; }

# ──────────────────────────────────────────────
# 0. Verificar que el JAR existe
# ──────────────────────────────────────────────
if [ ! -f "$JAR" ]; then
    err "No se encontró $JAR — ejecutá 'mvn clean package -DskipTests' primero."
    exit 1
fi

# ──────────────────────────────────────────────
# 1. Crear (o recrear) las 3 BDs
# ──────────────────────────────────────────────
log "Creando bases de datos..."
for DB in likesdb1 likesdb2 likesdb3; do
    psql -h localhost -U "$PGUSER" -d postgres -c "DROP DATABASE IF EXISTS $DB;" 2>/dev/null || true
    psql -h localhost -U "$PGUSER" -d postgres -c "CREATE DATABASE $DB;" 2>/dev/null
    ok "$DB creada"
done

# ──────────────────────────────────────────────
# 2. Levantar las 3 instancias
# ──────────────────────────────────────────────
log "Levantando 3 instancias..."

java -jar "$JAR" \
    --server.port=8081 \
    --spring.datasource.url=jdbc:postgresql://localhost:5432/likesdb1 \
    --spring.datasource.username="$PGUSER" --spring.datasource.password="$PGPASS" \
    --peers[0].id=node-2 --peers[0].host=localhost --peers[0].port=8082 \
    --peers[1].id=node-3 --peers[1].host=localhost --peers[1].port=8083 \
    > /tmp/node1.log 2>&1 &
PID1=$!

java -jar "$JAR" \
    --server.port=8082 \
    --spring.datasource.url=jdbc:postgresql://localhost:5432/likesdb2 \
    --spring.datasource.username="$PGUSER" --spring.datasource.password="$PGPASS" \
    --peers[0].id=node-1 --peers[0].host=localhost --peers[0].port=8081 \
    --peers[1].id=node-3 --peers[1].host=localhost --peers[1].port=8083 \
    > /tmp/node2.log 2>&1 &
PID2=$!

java -jar "$JAR" \
    --server.port=8083 \
    --spring.datasource.url=jdbc:postgresql://localhost:5432/likesdb3 \
    --spring.datasource.username="$PGUSER" --spring.datasource.password="$PGPASS" \
    --peers[0].id=node-1 --peers[0].host=localhost --peers[0].port=8081 \
    --peers[1].id=node-2 --peers[1].host=localhost --peers[1].port=8082 \
    > /tmp/node3.log 2>&1 &
PID3=$!

ok "PIDs: node-1=$PID1, node-2=$PID2, node-3=$PID3"

# Esperar a que los 3 estén listos
log "Esperando a que arranquen..."
for PORT in 8081 8082 8083; do
    for i in $(seq 1 30); do
        if curl -sf "http://localhost:$PORT/health" > /dev/null 2>&1; then
            ok "Puerto $PORT listo"
            break
        fi
        if [ "$i" -eq 30 ]; then
            err "Puerto $PORT no respondió en 30s"
            kill $PID1 $PID2 $PID3 2>/dev/null; exit 1
        fi
        sleep 1
    done
done

# ──────────────────────────────────────────────
# 3. Escribir likes directamente a los 3 nodos (con duplicados para generar gaps)
# ──────────────────────────────────────────────
log "Escribiendo likes iniciales a los 3 nodos..."

# Like A a los 3 (todos lo tienen)
for PORT in 8081 8082 8083; do
    curl -sf -X POST "http://localhost:$PORT/write" \
        -H "Content-Type: application/json" \
        -d '{"post_id":"post-1","like_id":"like-A"}' > /dev/null
done
ok "like-A escrito en los 3"

# Like B a los 3
for PORT in 8081 8082 8083; do
    curl -sf -X POST "http://localhost:$PORT/write" \
        -H "Content-Type: application/json" \
        -d '{"post_id":"post-1","like_id":"like-B"}' > /dev/null
done
ok "like-B escrito en los 3"

# Duplicado: mandar like-A otra vez a nodo 1 y 2 (genera gaps en BIGSERIAL)
for PORT in 8081 8082; do
    curl -sf -X POST "http://localhost:$PORT/write" \
        -H "Content-Type: application/json" \
        -d '{"post_id":"post-1","like_id":"like-A"}' > /dev/null
done
ok "like-A duplicado en nodos 1 y 2 (genera gaps en BIGSERIAL)"

# Verificar estado de los 3
log "Estado actual de los 3 nodos:"
for PORT in 8081 8082 8083; do
    HEALTH=$(curl -sf "http://localhost:$PORT/health")
    READ=$(curl -sf "http://localhost:$PORT/read?post_id=post-1")
    echo -e "  Puerto $PORT: health=$HEALTH  read=$READ"
done

# ──────────────────────────────────────────────
# 4. Matar nodo 3
# ──────────────────────────────────────────────
log "Matando nodo 3 (PID=$PID3, puerto 8083)..."
kill $PID3 2>/dev/null
wait $PID3 2>/dev/null || true
ok "Nodo 3 caído"

sleep 1

# Verificar que nodo 3 no responde
if curl -sf "http://localhost:8083/health" > /dev/null 2>&1; then
    err "Nodo 3 sigue respondiendo — debería estar caído"
    kill $PID1 $PID2 2>/dev/null; exit 1
fi
ok "Confirmado: nodo 3 no responde"

# ──────────────────────────────────────────────
# 5. Escribir más likes mientras nodo 3 está caído
# ──────────────────────────────────────────────
log "Escribiendo likes con nodo 3 caído (solo a nodos 1 y 2)..."

for LID in like-C like-D like-E; do
    for PORT in 8081 8082; do
        curl -sf -X POST "http://localhost:$PORT/write" \
            -H "Content-Type: application/json" \
            -d "{\"post_id\":\"post-1\",\"like_id\":\"$LID\"}" > /dev/null
    done
    ok "$LID escrito en nodos 1 y 2"
done

# Duplicados extra para más gaps
curl -sf -X POST "http://localhost:8081/write" \
    -H "Content-Type: application/json" \
    -d '{"post_id":"post-1","like_id":"like-C"}' > /dev/null
ok "like-C duplicado en nodo 1 (más gaps)"

log "Estado de nodos 1 y 2 (nodo 3 caído):"
for PORT in 8081 8082; do
    HEALTH=$(curl -sf "http://localhost:$PORT/health")
    READ=$(curl -sf "http://localhost:$PORT/read?post_id=post-1")
    echo -e "  Puerto $PORT: health=$HEALTH  read=$READ"
done

# ──────────────────────────────────────────────
# 6. Levantar nodo 3 de nuevo (debe hacer resync)
# ──────────────────────────────────────────────
log "Levantando nodo 3 de nuevo (debe resincronizar)..."

java -jar "$JAR" \
    --server.port=8083 \
    --spring.datasource.url=jdbc:postgresql://localhost:5432/likesdb3 \
    --spring.datasource.username="$PGUSER" --spring.datasource.password="$PGPASS" \
    --peers[0].id=node-1 --peers[0].host=localhost --peers[0].port=8081 \
    --peers[1].id=node-2 --peers[1].host=localhost --peers[1].port=8082 \
    > /tmp/node3_resync.log 2>&1 &
PID3=$!

ok "Nodo 3 reiniciado (PID=$PID3)"

# Esperar a que arranque
for i in $(seq 1 30); do
    if curl -sf "http://localhost:8083/health" > /dev/null 2>&1; then
        ok "Nodo 3 respondiendo de nuevo"
        break
    fi
    if [ "$i" -eq 30 ]; then
        err "Nodo 3 no arrancó en 30s"
        kill $PID1 $PID2 $PID3 2>/dev/null; exit 1
    fi
    sleep 1
done

# Darle un par de segundos extra para que la resync termine (corre @Async)
sleep 3

# ──────────────────────────────────────────────
# 7. Verificar que los 3 nodos tienen los mismos datos
# ──────────────────────────────────────────────
log "Verificando consistencia de los 3 nodos..."

echo ""
echo "═══════════════════════════════════════════════"
echo "  RESULTADOS FINALES"
echo "═══════════════════════════════════════════════"
echo ""

COUNTS=()
for PORT in 8081 8082 8083; do
    HEALTH=$(curl -sf "http://localhost:$PORT/health")
    READ=$(curl -sf "http://localhost:$PORT/read?post_id=post-1")
    WAL_COUNT=$(curl -sf "http://localhost:$PORT/wal?since_seq=0" | python3 -c "import json,sys; print(len(json.load(sys.stdin)['entries']))")
    echo -e "  Puerto $PORT:"
    echo -e "    /health = $HEALTH"
    echo -e "    /read   = $READ"
    echo -e "    WAL entries = $WAL_COUNT"
    echo ""

    COUNT=$(echo "$READ" | python3 -c "import json,sys; print(json.load(sys.stdin)['count'])")
    COUNTS+=("$COUNT")
done

# Verificar igualdad
if [ "${COUNTS[0]}" = "${COUNTS[1]}" ] && [ "${COUNTS[1]}" = "${COUNTS[2]}" ]; then
    echo -e "${GREEN}═══════════════════════════════════════════════${NC}"
    echo -e "${GREEN}  ✓ PASS — Los 3 nodos tienen count=${COUNTS[0]}${NC}"
    echo -e "${GREEN}═══════════════════════════════════════════════${NC}"
else
    echo -e "${RED}═══════════════════════════════════════════════${NC}"
    echo -e "${RED}  ✗ FAIL — counts no coinciden: ${COUNTS[0]}, ${COUNTS[1]}, ${COUNTS[2]}${NC}"
    echo -e "${RED}═══════════════════════════════════════════════${NC}"
fi

echo ""
log "Logs de resync del nodo 3:"
echo "─────────────────────────────────────────────"
grep -i "resync" /tmp/node3_resync.log || warn "No se encontraron líneas de resync"
echo "─────────────────────────────────────────────"

# ──────────────────────────────────────────────
# 8. Verificación directa en Postgres
# ──────────────────────────────────────────────
echo ""
log "Verificación directa en Postgres:"
for DB in likesdb1 likesdb2 likesdb3; do
    COUNT=$(psql -h localhost -U "$PGUSER" -d "$DB" -t -c "SELECT count FROM likes WHERE post_id='post-1';" 2>/dev/null | tr -d ' ')
    WAL=$(psql -h localhost -U "$PGUSER" -d "$DB" -t -c "SELECT COUNT(*) FROM wal_log;" 2>/dev/null | tr -d ' ')
    echo -e "  $DB: likes.count=$COUNT, wal_log rows=$WAL"
done

# ──────────────────────────────────────────────
# Cleanup
# ──────────────────────────────────────────────
echo ""
log "Matando los 3 procesos..."
kill $PID1 $PID2 $PID3 2>/dev/null
wait $PID1 $PID2 $PID3 2>/dev/null || true
ok "Limpio."
echo ""
log "Logs guardados en /tmp/node1.log, /tmp/node2.log, /tmp/node3_resync.log"
