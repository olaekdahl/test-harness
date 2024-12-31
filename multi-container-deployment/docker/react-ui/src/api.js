// const API_BASE_URL = import.meta.env.VITE_API_URL || 'http://localhost:8080';

const API_BASE_URL = 'http://localhost:8080';

export const getUsers = async () => {
  const response = await fetch(`${API_BASE_URL}/api/users`);
  if (!response.ok) {
    throw new Error(`Error fetching users: ${response.statusText}`);
  }
  return response.json();
};

export const getUserById = async (id) => {
  const response = await fetch(`${API_BASE_URL}/api/users/${id}`);
  if (!response.ok) {
    throw new Error(`Error fetching user ${id}: ${response.statusText}`);
  }
  return response.json();
};