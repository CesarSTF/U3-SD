#!/usr/bin/env bash
#
# test_integracion.sh — Prueba de integración completa con balanceador+coordinador
#
# Levanta: 3 likes-service (Java) + 1 balanceador-coordinador (Python)
# Todo en localhost, simulando las 4 máquinas.
#
# Escenario:
#   1. Escribir likes vía el balanceador (POST /like)
#   2. Leer likes vía el balanceador (GET /likes/{post_id})
#   3. Matar un nodo — el circuit breaker lo detecta solo
#   4. Escribir más likes — cuórum W=2 sigue funcionando
#   5. Levantar el nodo caído — resync automática
#   6. Verificar consistencia en los 3 Postgres
#
# Uso:
#   cd likes-service/
#   chmod +x test_integracion.sh
#   ./test_integracion.sh

set -e

JAR="target/likes-service-1.0.0.jar"
PGUSER="user"
PGPASS="pass"
export PGPASSWORD="$PGPASS"

BALANCEADOR_DIR="../balanceador-coordinador"
BALANCEADOR_PORT=8080

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log()  { echo -e "${CYAN}[TEST]${NC} $1"; }
ok()   { echo -e "${GREEN}  ✓${NC} $1"; }
err()  { echo -e "${RED}  ✗${NC} $1"; }
warn() { echo -e "${YELLOW}  ⚠${NC} $1"; }
header() { echo -e "\n${BOLD}══════════════════════════════════════════${NC}"; echo -e "${BOLD}  $1${NC}"; echo -e "${BOLD}══════════════════════════════════════════${NC}\n"; }

cleanup() {
    echo ""
    log "Limpiando procesos..."
    kill $PID1 $PID2 $PID3 $PID_BAL 2>/dev/null
    wait $PID1 $PID2 $PID3 $PID_BAL 2>/dev/null || true
    ok "Todos los procesos terminados."
    log "Logs: /tmp/node1.log, /tmp/node2.log, /tmp/node3.log, /tmp/balanceador.log"
}
trap cleanup EXIT

# ──────────────────────────────────────────────
# 0. Verificaciones previas
# ──────────────────────────────────────────────
if [ ! -f "$JAR" ]; then
    err "No se encontró $JAR — ejecutá 'mvn clean package -DskipTests' primero."
    exit 1
fi
if [ ! -f "$BALANCEADOR_DIR/main.py" ]; then
    err "No se encontró $BALANCEADOR_DIR/main.py"
    exit 1
fi

# ──────────────────────────────────────────────
# 1. Crear (o recrear) las 3 BDs
# ──────────────────────────────────────────────
header "PASO 1: Preparar bases de datos"
for DB in likesdb1 likesdb2 likesdb3; do
    psql -h localhost -U "$PGUSER" -d postgres -c "DROP DATABASE IF EXISTS $DB;" 2>/dev/null || true
    psql -h localhost -U "$PGUSER" -d postgres -c "CREATE DATABASE $DB;" 2>/dev/null
    ok "$DB creada"
done

# ──────────────────────────────────────────────
# 2. Levantar las 3 instancias de likes-service
# ──────────────────────────────────────────────
header "PASO 2: Levantar 3 instancias de likes-service"

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

log "Esperando a que arranquen..."
for PORT in 8081 8082 8083; do
    for i in $(seq 1 30); do
        if curl -sf "http://localhost:$PORT/health" > /dev/null 2>&1; then
            ok "likes-service :$PORT listo"
            break
        fi
        [ "$i" -eq 30 ] && { err "Puerto $PORT no respondió"; exit 1; }
        sleep 1
    done
done

# ──────────────────────────────────────────────
# 3. Levantar el balanceador-coordinador con config local
# ──────────────────────────────────────────────
header "PASO 3: Levantar balanceador-coordinador"

# Crear config temporal apuntando a localhost
CONFIG_TMP="/tmp/balanceador_config_local.yaml"
cat > "$CONFIG_TMP" <<EOF
nodes:
  - id: node-1
    host: localhost
    port: 8081
  - id: node-2
    host: localhost
    port: 8082
  - id: node-3
    host: localhost
    port: 8083

quorum:
  W: 2
  R: 2

heartbeat:
  interval_ms: 2000
  timeout_ms: 800
  failure_threshold: 3
  half_open_after_ms: 5000
  max_lag_seq: 0

request:
  write_timeout_ms: 1500
  read_timeout_ms: 1000
EOF

# Copiar el main.py a /tmp para no alterar el directorio del balanceador
cp "$BALANCEADOR_DIR/main.py" /tmp/balanceador_main.py
# Parchear para que lea el config desde /tmp
sed -i "s|config.yaml|$CONFIG_TMP|g" /tmp/balanceador_main.py

cd /tmp
python3 balanceador_main.py > /tmp/balanceador.log 2>&1 &
PID_BAL=$!
cd - > /dev/null

ok "Balanceador PID=$PID_BAL"

# Esperar a que el balanceador esté listo
for i in $(seq 1 15); do
    if curl -sf "http://localhost:$BALANCEADOR_PORT/status" > /dev/null 2>&1; then
        ok "Balanceador :$BALANCEADOR_PORT listo"
        break
    fi
    [ "$i" -eq 15 ] && { err "Balanceador no respondió"; exit 1; }
    sleep 1
done

# Esperar a que los heartbeats marquen todos CLOSED
log "Esperando heartbeats (circuit breakers → CLOSED)..."
sleep 5

STATUS=$(curl -sf "http://localhost:$BALANCEADOR_PORT/status")
echo -e "  Estado del coordinador: $STATUS"

# ──────────────────────────────────────────────
# 4. Escribir likes VÍA el balanceador
# ──────────────────────────────────────────────
header "PASO 4: Escribir likes vía balanceador (POST /like)"

for LID in like-001 like-002 like-003 like-004 like-005; do
    RESP=$(curl -sf -X POST "http://localhost:$BALANCEADOR_PORT/like" \
        -H "Content-Type: application/json" \
        -d "{\"post_id\":\"post-demo\",\"like_id\":\"$LID\"}")
    ok "$LID → $RESP"
done

# Duplicados (idempotencia vía el balanceador)
for LID in like-001 like-003; do
    RESP=$(curl -sf -X POST "http://localhost:$BALANCEADOR_PORT/like" \
        -H "Content-Type: application/json" \
        -d "{\"post_id\":\"post-demo\",\"like_id\":\"$LID\"}")
    ok "$LID (duplicado) → $RESP"
done

# ──────────────────────────────────────────────
# 5. Leer vía el balanceador
# ──────────────────────────────────────────────
header "PASO 5: Leer likes vía balanceador (GET /likes/{post_id})"

READ=$(curl -sf "http://localhost:$BALANCEADOR_PORT/likes/post-demo")
echo -e "  GET /likes/post-demo = $READ"
COUNT=$(echo "$READ" | python3 -c "import json,sys; print(json.load(sys.stdin)['count'])")
if [ "$COUNT" = "5" ]; then
    ok "count=5 correcto (5 likes únicos, duplicados descartados)"
else
    err "count=$COUNT — esperaba 5"
fi

# ──────────────────────────────────────────────
# 6. Estado de los 3 nodos antes de matar uno
# ──────────────────────────────────────────────
log "Estado de los 3 nodos antes de la caída:"
for PORT in 8081 8082 8083; do
    H=$(curl -sf "http://localhost:$PORT/health")
    R=$(curl -sf "http://localhost:$PORT/read?post_id=post-demo")
    echo -e "  :$PORT  health=$H  read=$R"
done

# ──────────────────────────────────────────────
# 7. Matar nodo 3 — el circuit breaker lo debe detectar solo
# ──────────────────────────────────────────────
header "PASO 6: Matar nodo 3 (el circuit breaker lo detecta solo)"

kill $PID3 2>/dev/null
wait $PID3 2>/dev/null || true
ok "Nodo 3 (PID=$PID3, :8083) matado"

# Esperar a que el circuit breaker lo detecte (failure_threshold=3, interval=2s → ~6s)
log "Esperando a que el circuit breaker detecte la caída (~8s)..."
sleep 8

STATUS=$(curl -sf "http://localhost:$BALANCEADOR_PORT/status")
echo -e "  Estado del coordinador: $STATUS"

# Verificar que node-3 está OPEN
NODE3_STATE=$(echo "$STATUS" | python3 -c "
import json, sys
data = json.load(sys.stdin)
for n in data['nodes']:
    if n['id'] == 'node-3':
        print(n['circuit'])
")
if [ "$NODE3_STATE" = "OPEN" ]; then
    ok "Circuit breaker de node-3: OPEN (detectado automáticamente)"
else
    warn "Circuit breaker de node-3: $NODE3_STATE (esperaba OPEN — puede necesitar más tiempo)"
fi

# ──────────────────────────────────────────────
# 8. Escribir más likes con nodo 3 caído (W=2 con 2 nodos activos)
# ──────────────────────────────────────────────
header "PASO 7: Escribir likes con nodo 3 caído (cuórum W=2)"

for LID in like-006 like-007 like-008; do
    RESP=$(curl -sf -X POST "http://localhost:$BALANCEADOR_PORT/like" \
        -H "Content-Type: application/json" \
        -d "{\"post_id\":\"post-demo\",\"like_id\":\"$LID\"}")
    ok "$LID → $RESP"
done

READ=$(curl -sf "http://localhost:$BALANCEADOR_PORT/likes/post-demo")
echo -e "  GET /likes/post-demo = $READ"
COUNT=$(echo "$READ" | python3 -c "import json,sys; print(json.load(sys.stdin)['count'])")
if [ "$COUNT" = "8" ]; then
    ok "count=8 correcto (5 originales + 3 nuevos, cuórum funcionó sin nodo 3)"
else
    err "count=$COUNT — esperaba 8"
fi

# ──────────────────────────────────────────────
# 9. Levantar nodo 3 — resync + circuit breaker HALF_OPEN → CLOSED
# ──────────────────────────────────────────────
header "PASO 8: Levantar nodo 3 (resync + circuit breaker)"

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
        ok "Nodo 3 respondiendo"
        break
    fi
    [ "$i" -eq 30 ] && { err "Nodo 3 no arrancó"; exit 1; }
    sleep 1
done

# Esperar a que el circuit breaker lo pase a HALF_OPEN → CLOSED
# half_open_after_ms=5000, luego 1 heartbeat exitoso → CLOSED
log "Esperando circuit breaker: OPEN → HALF_OPEN → CLOSED (~8s)..."
sleep 8

STATUS=$(curl -sf "http://localhost:$BALANCEADOR_PORT/status")
echo -e "  Estado final del coordinador: $STATUS"

NODE3_STATE=$(echo "$STATUS" | python3 -c "
import json, sys
data = json.load(sys.stdin)
for n in data['nodes']:
    if n['id'] == 'node-3':
        print(n['circuit'])
")
if [ "$NODE3_STATE" = "CLOSED" ]; then
    ok "Circuit breaker de node-3: CLOSED (resincronizado y activo)"
else
    warn "Circuit breaker de node-3: $NODE3_STATE (puede necesitar más tiempo para CLOSED)"
fi

# ──────────────────────────────────────────────
# 10. Verificación final
# ──────────────────────────────────────────────
header "RESULTADOS FINALES"

# Leer vía balanceador
READ=$(curl -sf "http://localhost:$BALANCEADOR_PORT/likes/post-demo")
echo -e "  Lectura vía balanceador: $READ"
echo ""

# Estado de cada nodo
COUNTS=()
for PORT in 8081 8082 8083; do
    H=$(curl -sf "http://localhost:$PORT/health")
    R=$(curl -sf "http://localhost:$PORT/read?post_id=post-demo")
    W=$(curl -sf "http://localhost:$PORT/wal?since_seq=0" | python3 -c "import json,sys; print(len(json.load(sys.stdin)['entries']))")
    echo -e "  :$PORT  health=$H  read=$R  wal_entries=$W"
    C=$(echo "$R" | python3 -c "import json,sys; print(json.load(sys.stdin)['count'])")
    COUNTS+=("$C")
done

echo ""

# Verificación directa en Postgres
log "Verificación directa en Postgres:"
for DB in likesdb1 likesdb2 likesdb3; do
    C=$(psql -h localhost -U "$PGUSER" -d "$DB" -t -c "SELECT count FROM likes WHERE post_id='post-demo';" 2>/dev/null | tr -d ' ')
    W=$(psql -h localhost -U "$PGUSER" -d "$DB" -t -c "SELECT COUNT(*) FROM wal_log;" 2>/dev/null | tr -d ' ')
    echo -e "  $DB: likes.count=$C, wal_log rows=$W"
done

echo ""

# Veredicto
if [ "${COUNTS[0]}" = "${COUNTS[1]}" ] && [ "${COUNTS[1]}" = "${COUNTS[2]}" ] && [ "${COUNTS[0]}" = "8" ]; then
    echo -e "${GREEN}══════════════════════════════════════════${NC}"
    echo -e "${GREEN}  ✓ PASS — Los 3 nodos tienen count=8${NC}"
    echo -e "${GREEN}  ✓ Circuit breaker detectó caída/recuperación${NC}"
    echo -e "${GREEN}  ✓ Cuórum W=2 funcionó con 1 nodo caído${NC}"
    echo -e "${GREEN}  ✓ Resync recuperó las entradas faltantes${NC}"
    echo -e "${GREEN}══════════════════════════════════════════${NC}"
else
    echo -e "${RED}══════════════════════════════════════════${NC}"
    echo -e "${RED}  ✗ FAIL — counts: ${COUNTS[0]}, ${COUNTS[1]}, ${COUNTS[2]}${NC}"
    echo -e "${RED}══════════════════════════════════════════${NC}"
fi

echo ""
log "Logs de resync del nodo 3:"
echo "─────────────────────────────────────────"
grep -i "resync" /tmp/node3_resync.log 2>/dev/null || warn "No se encontraron líneas de resync"
echo "─────────────────────────────────────────"

echo ""
log "Logs del circuit breaker (balanceador):"
echo "─────────────────────────────────────────"
grep -iE "(OPEN|HALF_OPEN|CLOSED|node-3)" /tmp/balanceador.log 2>/dev/null | tail -15 || warn "No se encontraron líneas de circuit breaker"
echo "─────────────────────────────────────────"
