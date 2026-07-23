package com.example.likesservice;

import java.util.List;
import java.util.Map;

import org.springframework.transaction.annotation.Transactional;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

/**
 * 4 endpoints del likes-service (spec-nodo.md §2).
 * Un solo controller, sin capa service intermedia.
 */
@RestController
public class LikesController {

    private final LikesRepository repo;

    public LikesController(LikesRepository repo) {
        this.repo = repo;
    }

    /**
     * GET /health — seq global (de toda la tabla wal_log).
     * Lo usa el coordinador para el circuit breaker.
     */
    @GetMapping("/health")
    public Map<String, Object> health() {
        long seq = repo.getMaxSeq();
        return Map.of("seq", seq);
    }

    /**
     * POST /write — escribe un like con guard de idempotencia.
     * Si el likeId ya existe (conflicto), NO toca likes.count.
     */
    @Transactional
    @PostMapping("/write")
    public Map<String, Object> write(@RequestBody WriteRequest req) {
        Long newSeq = repo.insertWalEntry(req.postId(), req.likeId());

        if (newSeq == null) {
            // Conflicto — likeId repetido, no-op idempotente
            long existingSeq = repo.getSeqForExisting(req.postId(), req.likeId());
            return Map.of("ok", true, "seq", existingSeq);
        }

        // Like nuevo — incrementar contador
        repo.upsertLikeCount(req.postId());
        return Map.of("ok", true, "seq", newSeq);
    }

    /**
     * GET /read?post_id=... — count + seq específico de ese postId.
     * El seq acá es el máximo de wal_log para ESE post, no el global.
     */
    @GetMapping("/read")
    public Map<String, Object> read(@RequestParam("post_id") String postId) {
        int count = repo.getCount(postId);
        long seq = repo.getMaxSeqForPost(postId);
        return Map.of("count", count, "seq", seq);
    }

    /**
     * GET /wal?since_seq=0 — entradas del WAL para resincronización entre nodos.
     */
    @GetMapping("/wal")
    public Map<String, Object> wal(
            @RequestParam(value = "since_seq", defaultValue = "0") long sinceSeq) {
        List<Map<String, Object>> entries = repo.getWalSince(sinceSeq);
        return Map.of("entries", entries);
    }
}
