package com.example.demo.controller;

import com.example.demo.model.User;
import com.example.demo.repository.UserRepository;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.web.bind.annotation.*;

import java.util.List;

@RestController
@RequestMapping("/api/users")
public class UserController {

    // @Autowired
    private UserRepository userRepository;

    // CREATE a new User
    // Example JSON: { "name": "John Doe", "email": "john@example.com" }
    @PostMapping
    public User createUser(@RequestBody User user) {
        return userRepository.save(user);
    }

    // READ all Users
    @GetMapping
    public String getAllUsers() {
        return "test";
    }

    // READ a single User by ID
    @GetMapping("/{id}")
    public User getUserById(@PathVariable Long id) {
        return userRepository.findById(id)
                             .orElseThrow(() -> new RuntimeException("User not found with id: " + id));
    }

    // UPDATE a User
    @PutMapping("/{id}")
    public User updateUser(@PathVariable Long id, @RequestBody User updatedUser) {
        User existingUser = userRepository.findById(id)
                             .orElseThrow(() -> new RuntimeException("User not found with id: " + id));
        
        existingUser.setName(updatedUser.getName());
        existingUser.setEmail(updatedUser.getEmail());

        return userRepository.save(existingUser);
    }

    // DELETE a User
    @DeleteMapping("/{id}")
    public String deleteUser(@PathVariable Long id) {
        userRepository.deleteById(id);
        return "User with ID " + id + " deleted successfully.";
    }
}