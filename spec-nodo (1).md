# Spec: likes-service (máquinas 2, 3, 4)

Microservicio Java, 3 instancias idénticas (mismo `.jar`, distinta `application.yml`), cada una con su propio Postgres local, independiente.

## 0. Configuración (`application.yml`)

```yaml
server:
  port: 8081

spring:
  datasource:
    url: jdbc:postgresql://localhost:5432/likesdb
    username: user
    password: pass

peers:
  - id: node-2
    host: 192.168.1.102
    port: 8081
  - id: node-3
    host: 192.168.1.103
    port: 8081
```

No hay autenticación entre componentes — la red del clúster es privada (switch dedicado), no expuesta a internet.

## 1. Esquema en Postgres local

```sql
CREATE TABLE likes (
  post_id   TEXT PRIMARY KEY,
  count     INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE wal_log (
  seq       BIGSERIAL PRIMARY KEY,
  post_id   TEXT NOT NULL,
  like_id   TEXT NOT NULL,
  applied_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (post_id, like_id)
);
```

Sin JPA/Hibernate — SQL directo vía `JdbcTemplate`. No hace falta mapear entidades para 2 tablas y 4 queries.

## 2. Endpoints (`@RestController`)

### `GET /health`
```java
@GetMapping("/health")
Map<String, Object> health() {
    Long seq = jdbc.queryForObject(
        "SELECT COALESCE(max(seq), 0) FROM wal_log", Long.class);
    return Map.of("seq", seq);
}
```
`seq` global (de toda la tabla) — lo usa el coordinador solo para el circuit breaker.

### `POST /write`
Body: `{ "postId": "...", "likeId": "..." }`

```java
@PostMapping("/write")
Map<String, Object> write(@RequestBody WriteRequest req) {
    Long existingSeq = jdbc.query(
        "INSERT INTO wal_log (post_id, like_id) VALUES (?, ?) " +
        "ON CONFLICT (post_id, like_id) DO NOTHING RETURNING seq",
        rs -> rs.next() ? rs.getLong("seq") : null,
        req.postId(), req.likeId());

    if (existingSeq == null) {
        // conflicto — ya existía, no-op idempotente, no tocar likes.count
        Long seq = jdbc.queryForObject(
            "SELECT seq FROM wal_log WHERE post_id = ? AND like_id = ?",
            Long.class, req.postId(), req.likeId());
        return Map.of("ok", true, "seq", seq);
    }

    jdbc.update(
        "INSERT INTO likes (post_id, count) VALUES (?, 1) " +
        "ON CONFLICT (post_id) DO UPDATE SET count = likes.count + 1",
        req.postId());

    return Map.of("ok", true, "seq", existingSeq);
}
```
El guard es el mismo que en la versión anterior del spec: si el INSERT al WAL no insertó nada (conflicto de `likeId` repetido), **no se toca `likes.count`** — evita contar dos veces un reintento.

### `GET /read?postId=...`
```java
@GetMapping("/read")
Map<String, Object> read(@RequestParam String postId) {
    Integer count = jdbc.query(
        "SELECT count FROM likes WHERE post_id = ?",
        rs -> rs.next() ? rs.getInt("count") : 0, postId);

    Long seq = jdbc.queryForObject(
        "SELECT COALESCE(max(seq), 0) FROM wal_log WHERE post_id = ?",
        Long.class, postId);

    return Map.of("count", count, "seq", seq);
}
```
`seq` acá es **específico de ese `postId`**, no el global de `/health` — es el que usa el coordinador para elegir la respuesta más fresca entre los nodos consultados en una lectura.

### `GET /wal?sinceSeq=0`
```java
@GetMapping("/wal")
Map<String, Object> wal(@RequestParam(defaultValue = "0") long sinceSeq) {
    List<Map<String, Object>> entries = jdbc.queryForList(
        "SELECT seq, post_id, like_id FROM wal_log WHERE seq > ? ORDER BY seq",
        sinceSeq);
    return Map.of("entries", entries);
}
```

## 3. Resincronización al arrancar (`@EventListener(ApplicationReadyEvent.class)`)

Igual que en la versión anterior, pero con `RestTemplate` (o `WebClient` si prefieren reactivo, no hace falta) en vez de `httpx`:

1. Al arrancar (`ApplicationReadyEvent`), llama `GET /health` de cada peer (de `application.yml`).
2. Identifica el peer con mayor `seq` entre los que respondieron.
3. Si ese `seq` es mayor al propio, llama `GET /wal?sinceSeq=<miSeq>` en ese peer.
4. Reproduce cada entrada contra su Postgres local, misma lógica transaccional que `/write` (incluyendo el `ON CONFLICT DO NOTHING`).
5. Repite el ciclo (por si entraron escrituras nuevas durante la resync) hasta igualar el `seq` del peer.
6. Recién ahí queda "listo" — el coordinador lo detecta al día vía su propio chequeo de `HALF_OPEN` (spec-balanceador-coordinador.md §3), este servicio no le avisa nada activamente, solo empieza a responder con `seq` actualizado en sus heartbeats.

Esto corre en un método separado, no bloquea el arranque del servidor HTTP (Spring ya expone el puerto aunque la resync tarde unos segundos — no hay problema porque el coordinador de todos modos no le manda tráfico hasta verlo `CLOSED`).

## 4. Simular la caída

Igual que antes: independiente de cómo se mate el proceso (kill, `systemctl stop`, apagar la laptop) — el servicio simplemente deja de responder `GET /health`, y el circuit breaker del coordinador lo detecta por heartbeats fallidos consecutivos.

## 5. Dependencias (`pom.xml`)

- `spring-boot-starter-web`
- `spring-boot-starter-jdbc`
- `org.postgresql:postgresql` (driver JDBC)
- `spring-boot-starter-test` (si quieren tests, no obligatorio para el alcance del trabajo)
