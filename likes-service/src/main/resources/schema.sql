-- Esquema de Postgres local para cada instancia del likes-service
-- Spring Boot lo ejecuta automáticamente al arrancar (spring.sql.init.mode=always)

CREATE TABLE IF NOT EXISTS likes (
    post_id   TEXT PRIMARY KEY,
    count     INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS wal_log (
    seq        BIGSERIAL PRIMARY KEY,
    post_id    TEXT NOT NULL,
    like_id    TEXT NOT NULL,
    applied_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (post_id, like_id)
);
