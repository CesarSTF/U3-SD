package com.example.likesservice;

import java.util.List;
import java.util.Map;

import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Component;
import org.springframework.transaction.annotation.Transactional;

/**
 * Acceso directo a Postgres vía JdbcTemplate — sin JPA/Hibernate.
 * Contiene todas las queries que usan los endpoints y la resincronización.
 */
@Component
public class LikesRepository {

    private final JdbcTemplate jdbc;

    public LikesRepository(JdbcTemplate jdbc) {
        this.jdbc = jdbc;
    }

    /** Conteo total de operaciones en el WAL. Lo usa GET /health. */
    public long getMaxSeq() {
        Long count = jdbc.queryForObject(
                "SELECT COUNT(*) FROM wal_log", Long.class);
        return count != null ? count : 0;
    }

    /**
     * Intenta insertar en wal_log. Devuelve el seq asignado si se insertó,
     * o null si hubo conflicto (likeId ya existía para ese postId).
     */
    public Long insertWalEntry(String postId, String likeId) {
        return jdbc.query(
                "INSERT INTO wal_log (post_id, like_id) VALUES (?, ?) " +
                "ON CONFLICT (post_id, like_id) DO NOTHING RETURNING seq",
                rs -> rs.next() ? rs.getLong("seq") : null,
                postId, likeId);
    }

    /** Busca el seq de una entrada que ya existe (para el caso de conflicto). */
    public long getSeqForExisting(String postId, String likeId) {
        Long seq = jdbc.queryForObject(
                "SELECT seq FROM wal_log WHERE post_id = ? AND like_id = ?",
                Long.class, postId, likeId);
        return seq != null ? seq : 0;
    }

    /** Incrementa (o inicializa en 1) el contador de likes para un postId. */
    public void upsertLikeCount(String postId) {
        jdbc.update(
                "INSERT INTO likes (post_id, count) VALUES (?, 1) " +
                "ON CONFLICT (post_id) DO UPDATE SET count = likes.count + 1",
                postId);
    }

    /** Lee el conteo de likes para un postId (0 si no existe). */
    public int getCount(String postId) {
        Integer count = jdbc.query(
                "SELECT count FROM likes WHERE post_id = ?",
                rs -> rs.next() ? rs.getInt("count") : 0, postId);
        return count != null ? count : 0;
    }

    /** Conteo de operaciones para un postId específico (no global). Lo usa GET /read. */
    public long getMaxSeqForPost(String postId) {
        Long count = jdbc.queryForObject(
                "SELECT COUNT(*) FROM wal_log WHERE post_id = ?",
                Long.class, postId);
        return count != null ? count : 0;
    }

    /** Entradas del WAL con seq > sinceSeq, ordenadas. Lo usa GET /wal y la resync. */
    public List<Map<String, Object>> getWalSince(long sinceSeq) {
        return jdbc.queryForList(
                "SELECT seq, post_id, like_id FROM wal_log WHERE seq > ? ORDER BY seq",
                sinceSeq);
    }

    /**
     * Reproduce entradas del WAL contra Postgres local — misma lógica
     * transaccional que POST /write (incluyendo ON CONFLICT DO NOTHING).
     * Vive acá (no en ResyncRunner) para que la llamada cruce beans
     * y el proxy de Spring aplique la transacción.
     */
    @Transactional
    public void applyWalEntries(List<Map<String, Object>> entries) {
        for (Map<String, Object> entry : entries) {
            String postId = (String) entry.get("post_id");
            String likeId = (String) entry.get("like_id");
            Long seq = insertWalEntry(postId, likeId);
            if (seq != null) {
                // Se insertó — actualizar likes.count
                upsertLikeCount(postId);
            }
            // Si seq == null → conflicto, ya existía, no tocar likes.count
        }
    }
}
