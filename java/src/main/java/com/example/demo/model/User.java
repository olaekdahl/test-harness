package com.example.demo.model;

import jakarta.persistence.*;

@Entity
@Table(name = "users") // This will map to a table named 'users'
public class User {

    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    private Long id;   // Primary key

    private String name;
    private String email;

    // Constructors
    public User() {}

    public User(String name, String email) {
        this.name = name;
        this.email = email;
    }

    // Getters and setters
    public Long getId() {
        return id;
    }
    
    public String getName() {
        return name;
    }
    public void setName(String name) {
        this.name = name;
    }
    
    public String getEmail() {
        return email;
    }
    public void setEmail(String email) {
        this.email = email;
    }
}