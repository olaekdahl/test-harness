import psycopg
from psycopg.rows import dict_row
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel
from typing import List

# Database configuration
DATABASE_CONFIG = {
    "dbname": "users",
    "user": "postgres",
    "password": "postgres",
    "host": "127.0.0.1",
    "port": 5432,
}

# Create FastAPI app
app = FastAPI()

# Pydantic model for User
class User(BaseModel):
    id: int
    name: str
    email: str

# Health check response model
class HealthCheckResponse(BaseModel):
    status: str
    message: str

# Database connection utility
def get_db_connection():
    try:
        conn = psycopg.connect(**DATABASE_CONFIG)
        return conn
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Database connection error: {e}")

@app.get("/api/health", response_model=HealthCheckResponse)
async def health_check():
    """
    Health check endpoint to verify the application is running.
    """
    return {
        "status": "healthy",
        "message": "Application is running"
    }

@app.get("/test", response_model=HealthCheckResponse)
async def test():
    """
    Health check endpoint to verify the application is running.
    """
    return {
        "status": "200",
        "message": "test"
    }

@app.get("/api/users", response_model=List[User])
async def read_users():
    """
    Fetch all users from the database.
    """
    conn = get_db_connection()
    try:
        # Use dict_row for returning rows as dictionaries
        with conn.cursor(row_factory=dict_row) as cursor:
            cursor.execute("SELECT id, name, email FROM users")
            users = cursor.fetchall()
            return users
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))
    finally:
        conn.close()

@app.get("/api/users/{user_id}", response_model=User)
async def read_user(user_id: int):
    """
    Fetch a single user by ID from the database.
    """
    conn = get_db_connection()
    try:
        # Use dict_row for returning rows as dictionaries
        with conn.cursor(row_factory=dict_row) as cursor:
            cursor.execute("SELECT id, name, email FROM users WHERE id = %s", (user_id,))
            user = cursor.fetchone()
            if user is None:
                raise HTTPException(status_code=404, detail="User not found")
            return user
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))
    finally:
        conn.close()