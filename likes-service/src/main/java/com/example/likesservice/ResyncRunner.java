package com.example.likesservice;

import java.util.List;
import java.util.Map;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.boot.context.event.ApplicationReadyEvent;
import org.springframework.boot.context.properties.ConfigurationProperties;
import org.springframework.context.event.EventListener;
import org.springframework.scheduling.annotation.Async;
import org.springframework.stereotype.Component;
import org.springframework.web.client.RestTemplate;

/**
 * Resincronización al arrancar (spec-nodo.md §3).
 *
 * Al levantar el servicio:
 * 1. Consulta GET /health de cada peer definido en application.yml.
 * 2. Identifica el peer con mayor seq.
 * 3. Si está atrás, pide GET /wal?since_seq=X para ponerse al día.
 * 4. Repite hasta igualar el seq del peer.
 *
 * Corre en un thread aparte (@Async) — no bloquea el arranque del servidor HTTP.
 */
@Component
public class ResyncRunner {

    private static final Logger log = LoggerFactory.getLogger(ResyncRunner.class);

    private final LikesRepository repo;
    private final PeersConfig peersConfig;
    private final RestTemplate restTemplate;

    public ResyncRunner(LikesRepository repo, PeersConfig peersConfig) {
        this.repo = repo;
        this.peersConfig = peersConfig;
        this.restTemplate = new RestTemplate();
    }

    @Async
    @EventListener(ApplicationReadyEvent.class)
    public void onReady() {
        try {
            resync();
        } catch (Exception e) {
            log.warn("Resync falló — el nodo arranca con los datos que tiene: {}", e.getMessage());
        }
    }

    private void resync() {
        List<PeersConfig.Peer> peers = peersConfig.getPeers();
        if (peers == null || peers.isEmpty()) {
            log.info("Resync — sin peers configurados, nada que sincronizar.");
            return;
        }

        long mySeq = repo.getMaxSeq();
        log.info("Resync — seq local: {}", mySeq);

        // 1. Consultar /health de cada peer, identificar el más adelantado
        PeersConfig.Peer bestPeer = null;
        long bestSeq = mySeq;

        for (PeersConfig.Peer peer : peers) {
            String url = "http://" + peer.getHost() + ":" + peer.getPort() + "/health";
            try {
                @SuppressWarnings("unchecked")
                Map<String, Object> body = restTemplate.getForObject(url, Map.class);
                if (body != null) {
                    long peerSeq = ((Number) body.get("seq")).longValue();
                    if (peerSeq > bestSeq) {
                        bestSeq = peerSeq;
                        bestPeer = peer;
                    }
                }
            } catch (Exception e) {
                log.warn("Resync: peer {} no responde ({})", peer.getId(), e.getMessage());
            }
        }

        if (bestPeer == null) {
            log.info("Resync — ya estoy al día o no hay peers disponibles.");
            return;
        }

        // 2. Jalar entradas faltantes usando cursor del peer (no comparar contra seq local)
        long sinceSeq = 0;
        while (true) {
            String walUrl = "http://" + bestPeer.getHost() + ":" + bestPeer.getPort()
                    + "/wal?since_seq=" + sinceSeq;
            try {
                @SuppressWarnings("unchecked")
                Map<String, Object> body = restTemplate.getForObject(walUrl, Map.class);
                if (body == null) break;

                @SuppressWarnings("unchecked")
                List<Map<String, Object>> entries = (List<Map<String, Object>>) body.get("entries");
                if (entries == null || entries.isEmpty()) break;

                repo.applyWalEntries(entries);
                log.info("Resync — aplicadas {} entradas", entries.size());

                // Avanzar el cursor con el ULTIMO seq que el peer devolvió (numeración del peer)
                long lastPeerSeq = ((Number) entries.get(entries.size() - 1).get("seq")).longValue();
                sinceSeq = lastPeerSeq;
            } catch (Exception e) {
                log.warn("Resync: error jalando WAL ({})", e.getMessage());
                break;
            }
        }

        log.info("Resync completa. Seq final: {}", repo.getMaxSeq());
    }



    // -------------------------------------------------------------------------
    // Configuración de peers desde application.yml
    // -------------------------------------------------------------------------

    @Component
    @ConfigurationProperties(prefix = "")
    public static class PeersConfig {

        private List<Peer> peers;

        public List<Peer> getPeers() {
            return peers;
        }

        public void setPeers(List<Peer> peers) {
            this.peers = peers;
        }

        public static class Peer {
            private String id;
            private String host;
            private int port;

            public String getId() { return id; }
            public void setId(String id) { this.id = id; }
            public String getHost() { return host; }
            public void setHost(String host) { this.host = host; }
            public int getPort() { return port; }
            public void setPort(int port) { this.port = port; }
        }
    }
}
