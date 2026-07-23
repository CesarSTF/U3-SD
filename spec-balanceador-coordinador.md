# Spec: Balanceador + Coordinador (máquina 1)

Componente único, un solo proceso, expone una API HTTP al cliente y habla HTTP con los 3 nodos.

## 1. Configuración

```yaml
nodes:
  - id: node-1
    host: 192.168.1.101
    port: 8081
  - id: node-2
    host: 192.168.1.102
    port: 8081
  - id: node-3
    host: 192.168.1.103
    port: 8081

quorum:
  W: 2          # confirmaciones mínimas para aceptar una escritura
  R: 2          # respuestas mínimas para aceptar una lectura

heartbeat:
  interval_ms: 2000       # cada cuánto se envía un heartbeat a cada nodo
  timeout_ms: 800          # cuánto se espera una respuesta antes de contarla como fallo
  failure_threshold: 3     # fallos consecutivos para abrir el circuito
  half_open_after_ms: 5000 # cuánto esperar en OPEN antes de probar de nuevo
  max_lag_seq: 0            # diferencia máxima de seq permitida para reingresar al pool (0 = exige estar 100% al día)

request:
  write_timeout_ms: 1500
  read_timeout_ms: 1000
```

## 2. Estado interno por nodo

```
NodeState {
  id: string
  circuit: CLOSED | OPEN | HALF_OPEN
  consecutive_failures: int
  last_heartbeat_at: timestamp
  last_known_seq: int        # última secuencia/LSN vista de ese nodo (para elegir el más fresco en lecturas)
}
```

## 3. Circuit breaker por nodo (heartbeats)

Un hilo/goroutine independiente hace ping a cada nodo cada `interval_ms`:

- **CLOSED** (nodo sano, recibe tráfico normal):
  - Heartbeat OK → resetea `consecutive_failures = 0`.
  - Heartbeat falla (timeout o error) → `consecutive_failures += 1`.
  - Si `consecutive_failures >= failure_threshold` → pasa a **OPEN**.

- **OPEN** (nodo aislado — excluido del pool activo, no se le manda ni lecturas ni escrituras):
  - No recibe tráfico de cliente. Mientras dure esto, los otros nodos activos siguen aceptando escrituras normalmente (con `W=2` de 3 nodos, 1 caído no bloquea nada) — es justamente lo que este nodo se está perdiendo.
  - Sigue recibiendo heartbeats (para detectar cuándo vuelve a responder).
  - Pasado `half_open_after_ms` → pasa a **HALF_OPEN**.

- **HALF_OPEN** (responde, pero puede estar desactualizado — sigue aislado del tráfico de cliente):
  - Se le manda un heartbeat de prueba. Si falla → vuelve a **OPEN**, reinicia el temporizador.
  - Si responde OK, **no pasa directo a CLOSED** — primero se valida que ya está al día:
    - `max_active_seq = max(seq de los nodos actualmente CLOSED)`
    - Si `node.seq >= max_active_seq - max_lag_seq` → está sincronizado, pasa a **CLOSED** (`consecutive_failures = 0`), recién ahí vuelve a recibir tráfico.
    - Si no → sigue en **HALF_OPEN**, se vuelve a chequear en el próximo ciclo de heartbeat (no hay timeout para esto: Postgres aplica el WAL pendiente de la réplica a su propio ritmo, el nodo se reingresa cuando esté listo, no antes).
  - `max_lag_seq` (nuevo parámetro de config, default `0` = exigir sincronización exacta) controla qué tan estricta es la condición de reingreso.

Endpoint que cada nodo debe exponer para esto: `GET /health` → `200 OK` con `{ "seq": <int> }` (la secuencia le sirve también al coordinador para trackear qué tan fresco está cada nodo sin esperar a una lectura real, y para decidir cuándo un nodo en HALF_OPEN ya se puso al día).

## 4. Round robin

El round robin no reemplaza al cuórum — decide **el orden/punto de partida** con el que se recorren los nodos activos en cada operación, para no sobrecargar siempre a los mismos 2 de los 3.

```
active_nodes = [n for n in nodes if n.circuit == CLOSED]
rr_index = (rr_index + 1) % len(active_nodes)
ordered = active_nodes[rr_index:] + active_nodes[:rr_index]
```

`ordered` es la lista que usan tanto el path de escritura como el de lectura para decidir a quién contactar primero.

## 5. Path de escritura (`POST /like`)

1. `active = active_nodes()`. Si `len(active) < W` → responder `503 Service Unavailable` (`{ "error": "no hay cuórum de escritura disponible" }`).
2. Enviar `POST /write { post_id, like_id }` en paralelo a `ordered` (todos los activos, no solo W — más confirmaciones no duelen).
3. Esperar hasta `write_timeout_ms` o hasta juntar `W` confirmaciones `200 OK`, lo que ocurra primero.
4. Si se juntaron `>= W` confirmaciones → `200 OK` al cliente.
5. Si no → `503 Service Unavailable` (no se alcanzó cuórum a tiempo). No hacer rollback manual: cada nodo ya escribió en su propio WAL/transacción Postgres lo que alcanzó a confirmar; es responsabilidad del nodo, no del coordinador.

Cada nodo debe responder `POST /write` con `{ "ok": true, "seq": <int> }`, donde `seq` es su número de secuencia (LSN de replicación o contador propio) después de aplicar la escritura.

## 6. Path de lectura (`GET /likes/{post_id}`)

1. `active = active_nodes()`. Si `len(active) < R` → `503 Service Unavailable`.
2. Enviar `GET /read?post_id=...` en paralelo a los primeros `R` nodos de `ordered`.
3. Esperar hasta `read_timeout_ms` o hasta juntar `R` respuestas.
4. Si se juntaron `< R` respuestas a tiempo → `503`.
5. De las respuestas recibidas, quedarse con la de mayor `seq` (la más fresca) y devolver ese valor al cliente.

Cada nodo debe responder `GET /read` con `{ "count": <int>, "seq": <int> }`.

## 7. Qué NO hace este componente

- No decide *cómo* replica Postgres entre nodos (eso es config de Postgres, va en el spec del nodo).
- No persiste nada — es stateless salvo el estado de circuito en memoria (`NodeState[]`) y el `rr_index`.
- No reintenta automáticamente una escritura fallida — el cliente decide si reintenta.
