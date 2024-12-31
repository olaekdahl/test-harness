import React, { useState } from 'react';
import UserList from './components/UserList';
import UserDetail from './components/UserDetail';

const App = () => {
  const [selectedUserId, setSelectedUserId] = useState(null);

  const handleSelectUser = (id) => {
    setSelectedUserId(id);
  };

  const handleBack = () => {
    setSelectedUserId(null);
  };

  return (
    <div>
      {selectedUserId ? (
        <UserDetail userId={selectedUserId} onBack={handleBack} />
      ) : (
        <UserList onSelectUser={handleSelectUser} />
      )}
    </div>
  );
};

export default App;