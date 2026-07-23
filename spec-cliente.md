# Spec: Cliente (generador de tráfico)

Simula usuarios dándole like a posts, concurrentemente, contra el balanceador+coordinador. No corre en una máquina dedicada del clúster — se ejecuta desde donde sea (tu laptop de pruebas), apuntando a la IP del balanceador.

## 1. Configuración

```yaml
target:
  base_url: "http://192.168.1.100:8080"   # IP:puerto del balanceador+coordinador

load:
  concurrent_clients: 50        # hilos/goroutines simulando usuarios en paralelo
  duration_s: 60                 # duración de la prueba
  write_ratio: 0.8               # 80% likes (POST), 20% lecturas (GET)
  post_ids: ["post-1", "post-2", "post-3"]   # pool de posts sobre los que se generan likes

output:
  log_file: "resultados.csv"
```

## 2. Generación de carga

Cada "cliente" simulado corre un loop mientras `duration_s` no se cumpla:

```
loop:
  post_id = random.choice(post_ids)
  if random() < write_ratio:
    like_id = uuid4()                      # único por request, para no chocar con dedup del nodo
    t0 = now()
    resp = POST {base_url}/like  { post_id, like_id }
    log(t0, "write", post_id, resp.status, elapsed(t0), resp.body)
  else:
    t0 = now()
    resp = GET {base_url}/likes/{post_id}
    log(t0, "read", post_id, resp.status, elapsed(t0), resp.body)
```

Nada de esperar entre requests dentro de un mismo cliente simulado (fire-as-fast-as-possible) — la concurrencia real la da tener `concurrent_clients` corriendo el loop en paralelo.

## 3. Formato del log (`resultados.csv`)

```
timestamp,tipo,post_id,status_http,latencia_ms,detalle
2026-07-19T10:00:01.123,write,post-1,200,45,"seq=101"
2026-07-19T10:00:01.140,read,post-2,503,1002,"timeout, no hubo cuorum"
```

Esto es lo que alimenta directamente la sección de **Resultados** del documento: tasa de éxito, latencia promedio/p95, y cuántas operaciones fallaron por falta de cuórum durante la ventana en que un nodo estuvo caído.

## 4. Protocolo de la demo de tolerancia a fallos

Para demostrar el objetivo general (que el sistema sigue funcionando con 1 nodo caído), la corrida de prueba se hace en 3 tramos manuales, disparados por vos, no por el cliente:

1. **Tramo A (0–20s)**: los 3 nodos activos. Arrancás el generador de tráfico.
2. **Tramo B (20–40s)**: matás un nodo (el mecanismo de matarlo es independiente, ya definido). El generador sigue mandando tráfico sin enterarse — debe seguir viendo mayormente `200 OK`, quizás algunos `503` puntuales mientras el circuit breaker detecta la caída (los heartbeats tardan `failure_threshold * interval_ms` en abrir el circuito).
3. **Tramo C (40–60s)**: reiniciás el nodo. Debe reincorporarse solo (resync, spec del nodo §3) y el tráfico vuelve a fluir hacia los 3.

El cliente no necesita saber en qué tramo está — el CSV con timestamps te alcanza para, después, graficar tasa de éxito vs. tiempo y marcar ahí los 3 tramos a mano en el informe.

## 5. Qué NO hace este componente

- No decide cuándo matar o reiniciar un nodo — eso lo hacés vos a mano durante la demo, en paralelo.
- No reintenta requests fallidos — cada fallo se loggea tal cual (un 503 es un dato válido para el informe, no un error a esconder).
