package com.example.likesservice;

/**
 * DTO para POST /write.
 * Jackson con SNAKE_CASE global mapea {"post_id": "...", "like_id": "..."} → postId, likeId.
 */
public record WriteRequest(String postId, String likeId) {
}
