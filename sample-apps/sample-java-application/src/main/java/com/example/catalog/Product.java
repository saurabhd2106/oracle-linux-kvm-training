package com.example.catalog;

public record Product(Long id, String name, double price, boolean inStock) {
}
