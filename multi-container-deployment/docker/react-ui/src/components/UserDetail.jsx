import React, { useEffect, useState } from 'react';
import { getUserById } from '../api';

const UserDetail = ({ userId, onBack }) => {
  const [user, setUser] = useState(null);
  const [error, setError] = useState(null);

  useEffect(() => {
    const fetchUser = async () => {
      try {
        const data = await getUserById(userId);
        setUser(data);
      } catch (err) {
        setError(err.message);
      }
    };
    fetchUser();
  }, [userId]);

  if (error) return <p>Error: {error}</p>;
  if (!user) return <p>Loading user details...</p>;

  return (
    <div>
      <h1>User Detail</h1>
      <p>Name: {user.name}</p>
      <p>Email: {user.email}</p>
      <button onClick={onBack}>Back to List</button>
    </div>
  );
};

export default UserDetail;