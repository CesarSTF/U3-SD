package com.example.likesservice;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.scheduling.annotation.EnableAsync;

@SpringBootApplication
@EnableAsync
public class LikesServiceApplication {

    public static void main(String[] args) {
        SpringApplication.run(LikesServiceApplication.class, args);
    }
}
