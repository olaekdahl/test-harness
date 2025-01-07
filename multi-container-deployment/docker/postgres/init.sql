-- Check if the users database exists and create it if it doesn't
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT FROM pg_database WHERE datname = 'users'
    ) THEN
        CREATE DATABASE users;
    END IF;
END
$$;

-- Connect to the users database
\c users;

-- Create a table for users
CREATE TABLE users (
    id SERIAL PRIMARY KEY,      -- Auto-incrementing ID
    name VARCHAR(100) NOT NULL, -- User's name
    email VARCHAR(150) UNIQUE NOT NULL, -- Unique email address
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP -- Timestamp of creation
);

-- Insert initial user data
INSERT INTO users (name, email) VALUES
('Alice Johnson', 'alice.johnson@example.com'),
('Bob Smith1', 'bob.smith@example.com'),
('Carol Williams', 'carol.williams@example.com');

-- Create a table for roles
CREATE TABLE roles (
    id SERIAL PRIMARY KEY,      -- Auto-incrementing ID
    role_name VARCHAR(50) UNIQUE NOT NULL -- Unique role name
);

-- Insert initial roles
INSERT INTO roles (role_name) VALUES
('Admin'),
('User'),
('Guest');

-- Create a table to assign roles to users
CREATE TABLE user_roles (
    user_id INT REFERENCES users(id) ON DELETE CASCADE, -- User ID from users table
    role_id INT REFERENCES roles(id) ON DELETE CASCADE, -- Role ID from roles table
    PRIMARY KEY (user_id, role_id)
);

-- Assign roles to users
INSERT INTO user_roles (user_id, role_id) VALUES
(1, 1), -- Alice is an Admin
(2, 2), -- Bob is a User
(3, 3); -- Carol is a Guest