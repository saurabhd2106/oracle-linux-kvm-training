package com.example.catalog;

import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.*;
import org.springframework.web.server.ResponseStatusException;

import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.atomic.AtomicLong;

@RestController
public class ProductController {

    private final AtomicLong nextId = new AtomicLong(1);
    private final Map<Long, Product> products = new ConcurrentHashMap<>();

    public ProductController() {
        products.put(1L, new Product(1L, "Oracle Linux Cap", 19.99, true));
        products.put(2L, new Product(2L, "Docker Sticker Pack", 4.50, true));
        products.put(3L, new Product(3L, "KVM Lab Notebook", 12.00, false));
        nextId.set(4);
    }

    @GetMapping("/health")
    public Map<String, String> health() {
        return Map.of("status", "ok");
    }

    @GetMapping("/api/products")
    public List<Product> listProducts() {
        return new ArrayList<>(products.values());
    }

    @GetMapping("/api/products/{id}")
    public Product getProduct(@PathVariable Long id) {
        Product product = products.get(id);
        if (product == null) {
            throw new ResponseStatusException(HttpStatus.NOT_FOUND, "Product not found");
        }
        return product;
    }

    @PostMapping("/api/products")
    public ResponseEntity<Product> createProduct(@RequestBody ProductRequest request) {
        if (request.name() == null || request.name().isBlank()) {
            throw new ResponseStatusException(HttpStatus.BAD_REQUEST, "name is required");
        }
        long id = nextId.getAndIncrement();
        Product product = new Product(id, request.name().trim(), request.price(), request.inStock());
        products.put(id, product);
        return ResponseEntity.status(HttpStatus.CREATED).body(product);
    }

    @DeleteMapping("/api/products/{id}")
    public ResponseEntity<Void> deleteProduct(@PathVariable Long id) {
        if (products.remove(id) == null) {
            throw new ResponseStatusException(HttpStatus.NOT_FOUND, "Product not found");
        }
        return ResponseEntity.noContent().build();
    }

    public record ProductRequest(String name, double price, boolean inStock) {
    }
}
