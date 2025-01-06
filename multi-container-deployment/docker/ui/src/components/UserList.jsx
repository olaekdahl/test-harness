import React, { useEffect, useState } from 'react';
import { getUsers } from '../api';

const UserList = ({ onSelectUser }) => {
  const [users, setUsers] = useState([]);
  const [error, setError] = useState(null);

  useEffect(() => {
    const fetchUsers = async () => {
      try {
        const data = await getUsers();
        setUsers(data);
      } catch (err) {
        setError(err.message);
      }
    };
    fetchUsers();
  }, []);

  if (error) return <p>Error: {error}</p>;

  return (
    <div>
      <h1>User List</h1>
      <ul>
        {users.map((user) => (
          <li key={user.id} onClick={() => onSelectUser(user.id)}>
            {user.name}
          </li>
        ))}
      </ul>
    </div>
  );
};

export default UserList;