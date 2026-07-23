# Spec: Arquitectura de software

## 1. Estilo de arquitectura

**Microservicio replicado con coordinador centralizado para cuórum** (estilo Dynamo, sin elección de líder entre nodos). Un único microservicio de dominio (`likes-service`) corre en **3 instancias independientes**, cada una en su propia máquina con su propio Postgres — eso es lo que lo hace "microservicios" en plural: no son 3 servicios de dominios distintos, es el mismo servicio replicado horizontalmente, que es un patrón válido y común de arquitectura de microservicios para alta disponibilidad. Al frente, un gateway (balanceador+coordinador) con circuit breaker decide a cuáles instancias les habla:

```
cliente  →  balanceador+coordinador (Python)  →  likes-service ×3 (Java, cada uno con su Postgres)
```

Nada de colas de mensajes, nada de service discovery dinámico, nada de contenedores orquestados (Docker Compose como mucho, si quieren, pero ni eso es necesario — son 4 máquinas físicas con IP fija). Minimalista a propósito: cada componente es responsable de una sola cosa y no sabe nada de lo que no le corresponde.

## 1.1 Stack tecnológico

- **Balanceador+coordinador**: Python — FastAPI + Uvicorn (async nativo, útil para el heartbeat en paralelo y el fan-out de escrituras/lecturas). httpx para las llamadas HTTP hacia las instancias de `likes-service`.
- **likes-service (×3 instancias)**: **Java + Spring Boot + Spring Web** (REST simple, sin Spring Data JPA — SQL directo vía `JdbcTemplate`, para no meter una capa de mapeo objeto-relacional que no aporta nada acá). `spring-boot-starter-web` + `spring-boot-starter-jdbc` + driver JDBC de Postgres.
- **Cliente / generador de carga**: Python (httpx o requests + asyncio/threading para concurrencia).
- **Backend de la demo**: Python (FastAPI), proxy delgado hacia el balanceador.
- **Frontend de la demo**: React + Vite, sin router ni manejo de estado global — es una sola pantalla.

## 2. Patrones de diseño usados (y por qué, uno solo por problema)

| Patrón | Dónde | Resuelve |
|---|---|---|
| **Quorum consensus (N, W, R)** | Coordinador | Consistencia sin depender de que TODOS los nodos respondan — tolera 1 caído con N=3, W=2, R=2. |
| **Circuit breaker** | Coordinador, por nodo | Deja de mandarle tráfico a un nodo caído en vez de que cada request espere timeout. |
| **Heartbeat / health check** | Coordinador ↔ nodos | Es la señal que alimenta al circuit breaker — sin esto no hay forma de saber quién está vivo. |
| **Round robin** | Coordinador | Reparte de qué orden se consultan los nodos activos, para no sobrecargar siempre a los mismos 2. |
| **Write-ahead log (WAL)** | Nodo | Durabilidad: la operación se registra antes/junto con aplicarse, y da el número de secuencia gratis. |
| **Idempotent receiver** | Nodo (`like_id` único) | Un mismo like reintentado por timeout no se cuenta dos veces. |

No hay más patrones que estos seis. Si en algún momento sienten la tentación de meter uno más (event sourcing, CQRS, saga, lo que sea), es señal de que se están complicando de más — el trabajo no lo pide y el enunciado ya se resuelve con esto.

## 3. Los 3 componentes (specs detallados aparte)

- `spec-balanceador-coordinador.md` — round robin + circuit breaker + lógica de cuórum (Python).
- `spec-nodo.md` — WAL, Postgres local, endpoints, resincronización (Java + Spring Boot, corre como `likes-service`).
- `spec-cliente.md` — generador de tráfico concurrente para la demo y el CSV de resultados.

## 4. Contrato de API (resumen — el detalle de cada uno está en su spec)

**Cliente → Balanceador+Coordinador:**
| Método | Ruta | Body/Query | Respuesta |
|---|---|---|---|
| POST | `/like` | `{post_id, like_id}` | `{ok, seq}` \| `503` |
| GET | `/likes/{post_id}` | — | `{count, seq}` \| `503` |

**Balanceador+Coordinador → Nodo:**
| Método | Ruta | Body/Query | Respuesta |
|---|---|---|---|
| GET | `/health` | — | `{seq}` (global del nodo) |
| POST | `/write` | `{post_id, like_id}` | `{ok, seq}` (local, por operación) |
| GET | `/read` | `?post_id=` | `{count, seq}` (seq específico de ese post) |

**Nodo → Nodo (peer, solo para resync):**
| Método | Ruta | Query | Respuesta |
|---|---|---|---|
| GET | `/wal` | `?since_seq=` | `{entries: [{seq, post_id, like_id}]}` |

## 5. Estructura de carpetas mínima

```
PROYECTO_U3/
├── balanceador-coordinador/   # Python — 1 solo archivo o módulo principal
├── likes-service/             # Java + Spring Boot — mismo jar corre en las 3 máquinas de nodo, solo cambia application.yml
│   ├── pom.xml
│   └── src/main/java/.../LikesServiceApplication.java  (+ un par de clases más, no capas de más)
├── cliente/                   # Python — el generador de carga
├── demo-webapp/
│   ├── backend/                # Python (FastAPI)
│   └── frontend/                # React + Vite
└── docs/
    ├── spec-arquitectura.md
    ├── spec-balanceador-coordinador.md
    ├── spec-nodo.md
    └── spec-cliente.md
```

Un solo archivo/módulo por componente alcanza — no hace falta separar en capas (controller/service/repository) para algo de este tamaño. En Java es tentador caer en la estructura de capas típica de Spring Boot (`controller/`, `service/`, `repository/`) por costumbre — para este trabajo no hace falta: un controller con los 4 endpoints + una clase con los métodos JDBC alcanza. No fuercen una "arquitectura limpia" de 6 capas — no aporta nada acá y sí complica seguirle el hilo al código durante la sustentación.

## 6. Explícitamente fuera de alcance (para no tentarse)

- Autenticación/autorización entre componentes.
- TLS entre nodos (red privada del switch).
- Reintentos automáticos en el cliente o el coordinador.
- Persistencia del estado del circuit breaker (se reconstruye solo con el próximo ciclo de heartbeats si el coordinador reinicia).
- Balanceo de carga del propio balanceador (es 1 sola máquina, punto único de fallo conocido y aceptado — no hay tiempo ni justifica la complejidad de resolverlo para este trabajo).
