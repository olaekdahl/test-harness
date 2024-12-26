package com.example.demo.controller;

import com.example.demo.model.User;
import com.example.demo.repository.UserRepository;
import org.springframework.web.bind.annotation.*;

import java.util.List;
import java.util.Map;

@RestController
@RequestMapping("/api")
public class UserController {

    private final UserRepository userRepository;

    // Constructor injection ensures userRepository is never null
    public UserController(UserRepository userRepository) {
        this.userRepository = userRepository;
    }

    // CREATE a new User
    // Example JSON: { "name": "John Doe", "email": "john@example.com" }
    @PostMapping
    public User createUser(@RequestBody User user) {
        return userRepository.save(user);
    }

    @GetMapping("/health")
    public Map<String, String> healthCheck() {
        return Map.of(
            "status", "healthy",
            "message", "Application is running"
        );
    }

    // READ all Users
    @GetMapping("/users")
    public List<User> getAllUsers() {
        return userRepository.findAll();
    }

    // READ a single User by ID
    @GetMapping("/users/{id}")
    public User getUserById(@PathVariable Long id) {
        return userRepository.findById(id)
                             .orElseThrow(() -> new RuntimeException("User not found with id: " + id));
    }

    // UPDATE a User
    @PutMapping("/users/{id}")
    public User updateUser(@PathVariable Long id, @RequestBody User updatedUser) {
        User existingUser = userRepository.findById(id)
                             .orElseThrow(() -> new RuntimeException("User not found with id: " + id));
        
        existingUser.setName(updatedUser.getName());
        existingUser.setEmail(updatedUser.getEmail());

        return userRepository.save(existingUser);
    }

    // DELETE a User
    @DeleteMapping("/users/{id}")
    public String deleteUser(@PathVariable Long id) {
        userRepository.deleteById(id);
        return "User with ID " + id + " deleted successfully.";
    }
}