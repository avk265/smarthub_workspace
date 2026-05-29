import json
import pika
import os
from fastapi.security import OAuth2PasswordBearer
from pydantic import BaseModel
from typing import Optional
from datetime import datetime, timedelta
from fastapi import FastAPI, Depends, HTTPException, status
from fastapi.security import OAuth2PasswordBearer, OAuth2PasswordRequestForm
from fastapi.middleware.cors import CORSMiddleware
from sqlalchemy.orm import Session
from pydantic import BaseModel
from passlib.context import CryptContext
from jose import JWTError, jwt
from fastapi import BackgroundTasks
from .database import SessionLocal, engine
from .models import Base, NotificationJob, User
import shutil
import uuid
import random
import hashlib
import csv
import io
import string
import secrets
from fastapi import FastAPI, Depends, HTTPException, status, Form, File, UploadFile
from fastapi.staticfiles import StaticFiles
from .database import SessionLocal, engine, Base
from fastapi.responses import StreamingResponse
import httpx
from .rag_processor import process_document_background
from . import models, schemas  # <--- THIS IS THE CRITICAL LINE
Base.metadata.create_all(bind=engine)

app = FastAPI(title="SmartHub API", version="1.0")
# Create a directory to store profile pictures
os.makedirs("uploads/avatars", exist_ok=True)
# Tell FastAPI to serve files from this directory so the app can load them
app.mount("/static", StaticFiles(directory="uploads"), name="static")
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

# --- SECURITY CONFIGURATION ---
SECRET_KEY = os.getenv("SECRET_KEY", "super_secret_dev_key_change_in_prod")
ALGORITHM = "HS256"
ACCESS_TOKEN_EXPIRE_MINUTES = 30 # As per PDF spec

pwd_context = CryptContext(schemes=["bcrypt"], deprecated="auto")
oauth2_scheme = OAuth2PasswordBearer(tokenUrl="/api/v1/auth/login")

def verify_password(plain_password, hashed_password):
    return pwd_context.verify(plain_password, hashed_password)

def get_password_hash(password):
    return pwd_context.hash(password)

def create_access_token(data: dict, expires_delta: timedelta | None = None):
    to_encode = data.copy()
    expire = datetime.utcnow() + (expires_delta if expires_delta else timedelta(minutes=15))
    to_encode.update({"exp": expire})
    return jwt.encode(to_encode, SECRET_KEY, algorithm=ALGORITHM)

def get_db():
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()
def get_current_user(token: str = Depends(oauth2_scheme), db: Session = Depends(get_db)):
    credentials_exception = HTTPException(
        status_code=status.HTTP_401_UNAUTHORIZED,
        detail="Could not validate credentials",
        headers={"WWW-Authenticate": "Bearer"},
    )
    try:
        payload = jwt.decode(token, SECRET_KEY, algorithms=[ALGORITHM])
        email: str = payload.get("sub")
        if email is None: 
            raise credentials_exception
    except JWTError:
        raise credentials_exception
        
    user = db.query(models.User).filter(models.User.email == email).first()
    if user is None: 
        raise credentials_exception
    return user
    pass

# ADD THIS NEW FUNCTION:
def get_admin_user(current_user: models.User = Depends(get_current_user)):
    """Enforces that the authenticated user has Admin privileges."""
    if not current_user.is_admin:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="Admin privileges required to perform this action."
        )
    return current_user

def process_bulk_users_background(csv_content: str, db_session_factory):
    """Parses CSV, creates users, and queues credential emails."""
    db = db_session_factory()
    reader = csv.DictReader(io.StringIO(csv_content))
    notification_tasks = []
    
    try:
        for row in reader:
            email = row.get("email", "").strip()
            full_name = row.get("full_name", "").strip()
            phone = row.get("phone", "").strip()
            
            # Skip invalid rows
            if not email or not full_name:
                continue
                
            # Skip if user already exists
            if db.query(models.User).filter(models.User.email == email).first():
                continue 
                
            # Generate a secure 12-character random password
            alphabet = string.ascii_letters + string.digits
            raw_password = "".join(secrets.choice(alphabet) for _ in range(12))
            hashed_password = get_password_hash(raw_password)
            
            # Create user in DB
            new_user = models.User(
                email=email,
                full_name=full_name,
                phone=phone,
                hashed_password=hashed_password
            )
            db.add(new_user)
            
            # Queue the welcome email with temp credentials
            notification_tasks.append({
                "job_id": "single_send", # Dispatch via real API
                "task_id": str(uuid.uuid4()),
                "recipient": email,
                "message": (
                    f"Welcome to SmartHub, {full_name}!\n\n"
                    f"Your account has been created by the administrator.\n"
                    f"Temporary Password: {raw_password}\n\n"
                    f"Please log in and update your profile."
                )
            })
            
        db.commit()
        
        # Dispatch to RabbitMQ if any users were successfully created
        if notification_tasks:
            publish_batch_to_queue("email.process", notification_tasks)
            print(f"[BULK IMPORT] Queued {len(notification_tasks)} welcome emails.")
            
    except Exception as e:
        print(f"[BULK IMPORT ERROR] Failed to process CSV: {e}")
    finally:
        db.close()
# --- Pydantic Schemas ---

@app.post("/api/v1/auth/register", status_code=status.HTTP_201_CREATED)
def register_user(
    email: str = Form(...),
    full_name: str = Form(...),
    password: str = Form(...),
    phone: Optional[str] = Form(None),
    device_token: Optional[str] = Form(None),
    avatar: Optional[UploadFile] = File(None), # The optional image file
    db: Session = Depends(get_db)
    
):
    if db.query(models.User).filter(models.User.email == email).first():
        raise HTTPException(status_code=400, detail="Email already registered")
    
    avatar_url = None
    if avatar:
        # Generate a unique filename and save the file
        file_ext = avatar.filename.split(".")[-1]
        file_name = f"{uuid.uuid4()}.{file_ext}"
        file_path = os.path.join("uploads/avatars", file_name)
        
        with open(file_path, "wb") as buffer:
            shutil.copyfileobj(avatar.file, buffer)
        
        avatar_url = f"/static/avatars/{file_name}"
    
    hashed_password = get_password_hash(password)
    initial_tokens = [device_token] if device_token else []
    
    new_user = models.User(
        email=email, 
        full_name=full_name, 
        hashed_password=hashed_password,
        phone=phone,
        avatar_url=avatar_url, # Save the path to the DB
        device_tokens=initial_tokens
    )
    db.add(new_user)
    db.commit()
    return {"message": "User created successfully"}

# UPDATE YOUR PROFILE GETTER TO RETURN THE AVATAR
# UPDATE YOUR PROFILE GETTER
@app.get("/api/v1/auth/profile")
def get_profile(current_user: models.User = Depends(get_current_user)):
    return {
        "email": current_user.email, 
        "full_name": current_user.full_name, 
        "phone": current_user.phone,
        "avatar_url": current_user.avatar_url,
        "is_admin": current_user.is_admin # <-- ADD THIS NEW LINE
    }
# Add this endpoint under your /auth/login route
@app.post("/api/v1/auth/login")
def login(form_data: OAuth2PasswordRequestForm = Depends(), db: Session = Depends(get_db)):
    user = db.query(User).filter(User.email == form_data.username).first()
    if not user or not verify_password(form_data.password, user.hashed_password):
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Incorrect email or password",
            headers={"WWW-Authenticate": "Bearer"},
        )
    
    access_token_expires = timedelta(minutes=ACCESS_TOKEN_EXPIRE_MINUTES)
    access_token = create_access_token(
        data={"sub": user.email}, expires_delta=access_token_expires
    )
    return {"access_token": access_token, "token_type": "bearer"}

class ResetPasswordRequest(BaseModel):
    token: str
    otp: str
    new_password: str

@app.post("/api/v1/auth/forgot-password")
def forgot_password(request: schemas.ForgotPasswordRequest, db: Session = Depends(get_db)):
    user = db.query(models.User).filter(models.User.email == request.email).first()
    
    if not user:
        return {"message": "If that email is registered, an OTP has been sent."}
    
    # 1. Generate a 6-digit OTP and hash it securely
    otp_code = str(random.randint(100000, 999999))
    otp_hash = hashlib.sha256(otp_code.encode()).hexdigest()
    
    # 2. Store the HASHED OTP inside the JWT (never the raw OTP!)
    reset_token = create_access_token(
        data={"sub": user.email, "type": "password_reset", "otp_hash": otp_hash}, 
        expires_delta=timedelta(minutes=15)
    )
    
    # 3. Create the Queue payload
    # TWILIO UPGRADE: If you want to use Twilio SMS right now, change "recipient" to user.phone 
    # and change the queue target below to "sms.process"!
    payload = [{
        "job_id": "otp_reset",
        "task_id": str(uuid.uuid4()),
        "recipient": user.email, 
        "message": f"Your SmartHub password reset code is: {otp_code}. This code expires in 15 minutes."
    }]
    
    # Push to the worker queue
    publish_batch_to_queue("email.process", payload) 
    
    # 4. Return the secure token to the Flutter app so it can hold onto it
    return {"message": "OTP sent successfully.", "reset_token": reset_token}

@app.post("/api/v1/auth/reset-password")
def reset_password(request: ResetPasswordRequest, db: Session = Depends(get_db)):
    credentials_exception = HTTPException(
        status_code=status.HTTP_401_UNAUTHORIZED,
        detail="Invalid or expired reset token/OTP",
    )
    
    try:
        # 1. Decode the JWT to get the user and the hashed OTP
        payload = jwt.decode(request.token, SECRET_KEY, algorithms=[ALGORITHM])
        email: str = payload.get("sub")
        token_type: str = payload.get("type")
        stored_otp_hash: str = payload.get("otp_hash")
        
        if email is None or token_type != "password_reset":
            raise credentials_exception
            
        # 2. Hash the OTP the user typed in and verify it matches the token
        provided_otp_hash = hashlib.sha256(request.otp.encode()).hexdigest()
        if provided_otp_hash != stored_otp_hash:
            raise credentials_exception
            
    except JWTError:
        raise credentials_exception
        
    # 3. Find the user and update the password
    user = db.query(models.User).filter(models.User.email == email).first()
    if not user:
        raise credentials_exception
        
    user.hashed_password = get_password_hash(request.new_password)
    db.commit()
    
    return {"message": "Password reset successful! You can now log in."}

# --- SECURITY DEPENDENCY ---
# This function intercepts requests, reads the token, and fetches the secure user.


# --- PROFILE ENDPOINTS ---

@app.put("/api/v1/auth/profile")
def update_profile(profile: schemas.ProfileUpdate, db: Session = Depends(get_db), current_user: User = Depends(get_current_user)):
    current_user.full_name = profile.full_name
    current_user.phone = profile.phone
    db.commit()
    return {"message": "Profile updated successfully"}
# ==========================================
# --- MODULE: ADMIN ---
# ==========================================

# ==========================================
# --- MODULE: ADMIN ---
# ==========================================

@app.get("/api/v1/admin/users")
def list_all_users(db: Session = Depends(get_db), admin_user: models.User = Depends(get_admin_user)):
    """List all users (Admin Only)"""
    return db.query(models.User).order_by(models.User.created_at.desc()).all()

@app.delete("/api/v1/admin/users/{id}")
def delete_user(id: str, db: Session = Depends(get_db), admin_user: models.User = Depends(get_admin_user)):
    """Delete a user account (Admin Only)"""
    user_to_delete = db.query(models.User).filter(models.User.id == id).first()
    if not user_to_delete:
        raise HTTPException(status_code=404, detail="User not found")
        
    db.delete(user_to_delete)
    db.commit()
    return {"message": "User deleted successfully"}
@app.post("/api/v1/auth/logout")
def logout():
    # Since JWTs are stateless, actual logout is handled by the Flutter app deleting the token.
    # This endpoint satisfies the PDF specification for the backend API.
    return {"message": "Successfully logged out"}
# --- QUEUE ENDPOINTS (From Previous Step) ---
# ... Keep your existing /notify/bulk and /notify/jobs/{job_id} endpoints here ...

# RabbitMQ Publisher Setup
def publish_batch_to_queue(queue_name: str, messages: list):
    """Opens ONE connection, sends ALL messages, then closes."""
    connection = pika.BlockingConnection(pika.ConnectionParameters(host='localhost'))
    channel = connection.channel()
    
    # Ensure the queue exists before publishing
    channel.queue_declare(queue=queue_name, durable=True)
    
    for message in messages:
        channel.basic_publish(
            exchange='',
            routing_key=queue_name,
            body=json.dumps(message),
            properties=pika.BasicProperties(
                delivery_mode=pika.spec.PERSISTENT_DELIVERY_MODE
            )
        )
        
    # Close the connection only after all messages are sent
    connection.close()
# --- ADD TO NOTIFICATIONS SECTION ---

# ==========================================
# --- MODULE: NOTIFICATIONS ---
# ==========================================

class SingleNotificationRequest(BaseModel):
    channel: str # 'email', 'sms', 'push', 'whatsapp'
    recipient: str
    message: str

class BulkJobRequest(BaseModel):
    channel: str
    total: int
    message: Optional[str] = "Bulk broadcast from SmartHub Admin."

@app.get("/api/v1/notify/jobs")
def list_all_jobs(db: Session = Depends(get_db), admin_user: models.User = Depends(get_admin_user)):
    """List all bulk notification jobs (Admin Only)"""
    return db.query(models.NotificationJob).order_by(models.NotificationJob.created_at.desc()).all()

@app.get("/api/v1/notify/jobs/{job_id}")
def get_job_status(job_id: str, db: Session = Depends(get_db), admin_user: models.User = Depends(get_admin_user)):
    """Check specific job status (Admin Only)"""
    job = db.query(models.NotificationJob).filter(models.NotificationJob.id == job_id).first()
    if not job:
        raise HTTPException(status_code=404, detail="Job not found")
    
    return {
        "id": job.id, "channel": job.channel, "total": job.total,
        "sent": job.sent, "failed": job.failed, "retrying": job.retrying, "completed": job.completed
    }

@app.post("/api/v1/notify/send")
def send_single_notification(
    payload: SingleNotificationRequest,
    db: Session = Depends(get_db), 
    current_user: models.User = Depends(get_current_user)
):
    """Send a single immediate notification (User to User, or System to User)"""
    queue_target = f"{payload.channel}.process"
    task = [{
        "job_id": "single_send",
        "task_id": str(uuid.uuid4()),
        "recipient": payload.recipient,
        "message": payload.message,
        "sender_id": str(current_user.id) # Track who sent it
    }]
    publish_batch_to_queue(queue_target, task)
    return {"message": f"Notification dispatched via {payload.channel}"}

@app.post("/api/v1/notify/bulk", status_code=202)
def create_bulk_job(
    job: BulkJobRequest, 
    db: Session = Depends(get_db),
    admin_user: models.User = Depends(get_admin_user) # <-- STRICT ADMIN CHECK
):
    """Trigger a massive bulk send (Admin Only)"""
    new_job = models.NotificationJob(
        channel=job.channel, total=job.total, sent=0, failed=0, retrying=0
    )
    db.add(new_job)
    db.commit()
    db.refresh(new_job)

    queue_target = f"{job.channel}.process"
    tasks = []
    
    for i in range(job.total):
        # Format payload specifically for Twilio if SMS/WhatsApp
        is_phone_channel = job.channel in ["sms", "whatsapp"]
        recipient = f"+1234567890{i}" if is_phone_channel else f"user_{i}@example.com"
        
        tasks.append({
            "job_id": str(new_job.id),
            "task_id": i + 1,
            "channel": job.channel,
            "recipient": recipient,
            "message": job.message,
            "is_twilio": is_phone_channel # Flag for the RabbitMQ worker
        })
        
    publish_batch_to_queue(queue_target, tasks)
    return {"job_id": new_job.id, "status": "queued", "channel": job.channel}

@app.post("/api/v1/admin/users/bulk", status_code=status.HTTP_202_ACCEPTED)
async def upload_bulk_users_csv(
    background_tasks: BackgroundTasks,
    file: UploadFile = File(...),
    db: Session = Depends(get_db),
    admin_user: models.User = Depends(get_admin_user) # Strictly Admin Only
):
    """Accepts a CSV file to create users in bulk (Admin Only)"""
    
    if not file.filename.lower().endswith('.csv'):
        raise HTTPException(status_code=400, detail="Only .csv files are allowed.")
    
    # Read file content into memory
    content = await file.read()
    
    try:
        decoded_content = content.decode('utf-8')
    except UnicodeDecodeError:
        raise HTTPException(status_code=400, detail="CSV file must be UTF-8 encoded.")
        
    # Hand off to the background task to prevent blocking
    background_tasks.add_task(process_bulk_users_background, decoded_content, SessionLocal)
    
    return {
        "message": "CSV upload successful. Background processing started.",
        "filename": file.filename
    }
# ==========================================
# --- MODULE 3: DOCUMENTS ENDPOINTS ---
# ==========================================

# Create a local storage directory for uploaded documents
os.makedirs("uploads/documents", exist_ok=True)

@app.post("/api/v1/documents/upload", status_code=status.HTTP_201_CREATED)
async def upload_document(
    background_tasks: BackgroundTasks, # <-- 1. ADD THIS HERE
    file: UploadFile = File(...),
    db: Session = Depends(get_db),
    current_user: models.User = Depends(get_current_user)
):
    # 1. Determine file type
    ext = file.filename.split(".")[-1].lower()
    allowed_types = {"pdf": "pdf", "docx": "docx", "txt": "txt", "png": "image", "jpg": "image", "jpeg": "image"}
    
    if ext not in allowed_types:
        raise HTTPException(status_code=400, detail="Unsupported file format")
        
    file_type = allowed_types[ext]
    
    # 2. Save physical file
    safe_filename = f"{uuid.uuid4()}_{file.filename}"
    file_path = os.path.join("uploads/documents", safe_filename)
    
    with open(file_path, "wb") as buffer:
        shutil.copyfileobj(file.file, buffer)
        
    file_size = os.path.getsize(file_path)
    
    # 3. Save to database
    new_doc = models.Document(
        user_id=current_user.id,
        filename=file.filename,
        file_type=file_type,
        file_size=file_size,
        storage_path=file_path,
        processed=False 
    )
    db.add(new_doc)
    db.commit()
    db.refresh(new_doc)
    
    # --- THE FIX: TRIGGER THE BACKGROUND TASK ---
    background_tasks.add_task(
        process_document_background, 
        file_path,               
        str(current_user.id),    
        str(new_doc.id),         
        SessionLocal             
    )
    # ------------------------------------------

    return {"message": "Document uploaded successfully", "document_id": new_doc.id}

@app.get("/api/v1/documents")
def list_documents(
    db: Session = Depends(get_db),
    current_user: models.User = Depends(get_current_user)
):
    """List all documents belonging to the current user."""
    documents = db.query(models.Document).filter(models.Document.user_id == current_user.id).all()
    return documents

@app.delete("/api/v1/documents/{document_id}")
def delete_document(
    document_id: str,
    db: Session = Depends(get_db),
    current_user: models.User = Depends(get_current_user)
):
    """Deletes the file from disk and removes DB record."""
    doc = db.query(models.Document).filter(models.Document.id == document_id, models.Document.user_id == current_user.id).first()
    
    if not doc:
        raise HTTPException(status_code=404, detail="Document not found")
        
    # 1. Delete physical file
    if os.path.exists(doc.storage_path):
        os.remove(doc.storage_path)
        
    # 2. Delete from DB
    db.delete(doc)
    db.commit()
    
    return {"message": "Document deleted successfully"}

from typing import Optional
# (Ensure schemas.TodoCreate and schemas.TodoUpdate are in your schemas.py)

# ==========================================
# --- MODULE 6: TODOS ENDPOINTS ---
# ==========================================

@app.get("/api/v1/todos")
def list_todos(
    completed: Optional[bool] = None,
    db: Session = Depends(get_db),
    current_user: models.User = Depends(get_current_user)
):
    """Fetch all active todos for the current user."""
    query = db.query(models.Todo).filter(models.Todo.user_id == current_user.id)
    if completed is not None:
        query = query.filter(models.Todo.completed == completed)
    return query.all()

@app.post("/api/v1/todos", status_code=status.HTTP_201_CREATED)
def create_todo(
    todo: schemas.TodoCreate,
    db: Session = Depends(get_db),
    current_user: models.User = Depends(get_current_user)
):
    """Add a new task."""
    new_todo = models.Todo(
        user_id=current_user.id,
        title=todo.title,
        description=todo.description,
        due_date=todo.due_date
    )
    db.add(new_todo)
    db.commit()
    db.refresh(new_todo)
    return new_todo

@app.put("/api/v1/todos/{todo_id}")
def update_todo(
    todo_id: str,
    todo_update: schemas.TodoUpdate,
    db: Session = Depends(get_db),
    current_user: models.User = Depends(get_current_user)
):
    """Edit an existing task title or due date."""
    todo = db.query(models.Todo).filter(models.Todo.id == todo_id, models.Todo.user_id == current_user.id).first()
    if not todo:
        raise HTTPException(status_code=404, detail="Todo not found")
        
    if todo_update.title:
        todo.title = todo_update.title
    if todo_update.due_date:
        todo.due_date = todo_update.due_date
        
    db.commit()
    db.refresh(todo)
    return todo

@app.put("/api/v1/todos/{todo_id}/complete")
def toggle_todo_complete(
    todo_id: str,
    db: Session = Depends(get_db),
    current_user: models.User = Depends(get_current_user)
):
    """Toggle a task between finished and unfinished."""
    todo = db.query(models.Todo).filter(models.Todo.id == todo_id, models.Todo.user_id == current_user.id).first()
    if not todo:
        raise HTTPException(status_code=404, detail="Todo not found")
        
    todo.completed = not todo.completed
    db.commit()
    return {"message": "Status updated", "completed": todo.completed}

@app.delete("/api/v1/todos/{todo_id}")
def delete_todo(
    todo_id: str,
    db: Session = Depends(get_db),
    current_user: models.User = Depends(get_current_user)
):
    """Permanently delete a task."""
    todo = db.query(models.Todo).filter(models.Todo.id == todo_id, models.Todo.user_id == current_user.id).first()
    if not todo:
        raise HTTPException(status_code=404, detail="Todo not found")
        
    db.delete(todo)
    db.commit()
    return {"message": "Todo deleted"}
# ==========================================
# --- MODULE 2: AI CHAT SESSIONS ---
# ==========================================

@app.post("/api/v1/chat/sessions", status_code=status.HTTP_201_CREATED)
def create_chat_session(
    session: schemas.ChatSessionCreate,
    db: Session = Depends(get_db),
    current_user: models.User = Depends(get_current_user)
):
    """Create new chat session"""
    new_session = models.ChatSession(user_id=current_user.id, title=session.title)
    db.add(new_session)
    db.commit()
    db.refresh(new_session)
    return new_session

@app.get("/api/v1/chat/sessions")
def list_user_sessions(
    db: Session = Depends(get_db),
    current_user: models.User = Depends(get_current_user)
):
    """List user's sessions"""
    return db.query(models.ChatSession).filter(
        models.ChatSession.user_id == current_user.id
    ).order_by(models.ChatSession.created_at.desc()).all()

@app.get("/api/v1/chat/sessions/{id}/messages")
def get_session_history(
    id: str,
    db: Session = Depends(get_db),
    current_user: models.User = Depends(get_current_user)
):
    """Get message history"""
    session = db.query(models.ChatSession).filter(
        models.ChatSession.id == id, models.ChatSession.user_id == current_user.id
    ).first()
    if not session:
        raise HTTPException(status_code=404, detail="Session not found")

    return db.query(models.ChatMessage).filter(
        models.ChatMessage.session_id == id
    ).order_by(models.ChatMessage.created_at.asc()).all()

@app.delete("/api/v1/chat/sessions/{id}")
def delete_chat_session(
    id: str,
    db: Session = Depends(get_db),
    current_user: models.User = Depends(get_current_user)
):
    """Delete session + messages"""
    session = db.query(models.ChatSession).filter(
        models.ChatSession.id == id, models.ChatSession.user_id == current_user.id
    ).first()
    if not session:
        raise HTTPException(status_code=404, detail="Session not found")

    db.delete(session)
    db.commit()
    return {"message": "Chat session deleted"}

@app.post("/api/v1/chat/sessions/{id}/messages")
async def send_message_to_ai(
    id: str,
    message: schemas.ChatMessageCreate,
    db: Session = Depends(get_db),
    current_user: models.User = Depends(get_current_user)
):
    """Send message (SSE stream)"""
    # 1. Verify Session
    session = db.query(models.ChatSession).filter(
        models.ChatSession.id == id, models.ChatSession.user_id == current_user.id
    ).first()
    if not session:
        raise HTTPException(status_code=404, detail="Session not found")

    # 2. Save User Message
    user_msg = models.ChatMessage(session_id=id, role="user", content=message.content)
    db.add(user_msg)
    db.commit()

    # 3. Pull short history
    recent_history = db.query(models.ChatMessage).filter(
        models.ChatMessage.session_id == id
    ).order_by(models.ChatMessage.created_at.desc()).limit(10).all()

    # Flip the list so it reads in correct chronological order (oldest to newest)
    history = list(reversed(recent_history))
    # 4. SSE Generator function
    # 4. SSE Generator function
    async def streaming_generator():
        import chromadb
        import httpx
        
        yield f"data: {json.dumps({'type': 'log', 'message': 'Searching documents...'})}\n\n"
        
        retrieved_context = ""
        try:
            chroma_client = chromadb.HttpClient(host="localhost", port=8002)
            collection_name = f"user_{current_user.id}"
            
            print(f"\n=== RAG DIAGNOSTICS ===")
            print(f"1. Looking for collection: {collection_name}")
            collection = chroma_client.get_collection(name=collection_name)
            
            count = collection.count()
            print(f"2. Collection found! It contains {count} chunks of text.")
            
            if count == 0:
                print("-> ERROR: Collection is empty! The PDF had no readable text.")
            
            print(f"3. Asking Ollama to embed the chat message...")
            async with httpx.AsyncClient() as client:
                embed_res = await client.post(
                    "http://localhost:11434/api/embeddings", 
                    json={"model": "nomic-embed-text", "prompt": message.content},
                    timeout=30.0
                )
                query_embedding = embed_res.json().get("embedding", [])
                
            print(f"4. Embedding generated: {len(query_embedding)} dimensions.")
            
            if query_embedding and count > 0:
                print(f"5. Searching ChromaDB for matches...")
                results = collection.query(
                    query_embeddings=[query_embedding], 
                    n_results=3 
                )
                
                docs = results.get('documents', [[]])[0]
                print(f"6. Search complete. Found {len(docs)} matching paragraphs.")
                
                if docs:
                    retrieved_context = "\n\n".join(docs)
                    yield f"data: {json.dumps({'type': 'log', 'message': 'Found relevant information!'})}\n\n"
                    print("7. SUCCESS: Context injected into AI prompt!")
                else:
                    yield f"data: {json.dumps({'type': 'log', 'message': 'Warning: No match found.'})}\n\n"
            print(f"=======================\n")
                    
        except Exception as e:
            print(f"\n[!] RAG ERROR: {e}\n")
            pass

        # Prepare the Prompt (Leave this exactly as you had it below)
        # Prepare the Prompt
        # Prepare the Prompt (The Small-Model Hack)
        sys_prompt = "You are SmartHub, an AI assistant for TKM students. Always be helpful."
        ollama_payload = [{"role": "system", "content": sys_prompt}]
        
        # Add the chat history
        for past in history:
            ollama_payload.append({"role": past.role, "content": past.content})

        # --- THE FIX: INJECT RAG INTO THE LAST USER MESSAGE ---
        if retrieved_context and len(ollama_payload) > 1:
            # Grab the user's current question
            original_question = ollama_payload[-1]["content"]
            
            # Tape the document text right above their question
            forced_prompt = (
                f"Read this text from my uploaded document:\n"
                f"---START---\n{retrieved_context}\n---END---\n\n"
                f"Based ONLY on that text, answer my question: {original_question}"
            )
            # Overwrite the last message in the payload
            ollama_payload[-1]["content"] = forced_prompt
            
            # (Optional) Print to terminal so you can see exactly what the AI sees!
            print("\n=== WHAT THE AI ACTUALLY SEES ===")
            print(forced_prompt[:300] + "...(truncated)")
            print("=================================\n")

        full_ai_response = ""
        
        # Connect to Ollama
        async with httpx.AsyncClient() as client:
            try:
                async with client.stream(
                    "POST", "http://localhost:11434/api/chat", 
                    json={"model": "llama3.2:3b", "messages": ollama_payload, "stream": True}, 
                    timeout=None # <-- THE FIX: Change 60.0 to None
                ) as response:
                    async for raw_line in response.aiter_lines():
                        if raw_line:
                            chunk_data = json.loads(raw_line)
                            if "message" in chunk_data and "content" in chunk_data["message"]:
                                delta = chunk_data["message"]["content"]
                                full_ai_response += delta
                                yield f"data: {json.dumps({'type': 'content', 'content': delta})}\n\n"
                            if chunk_data.get("done"):
                                yield f"data: {json.dumps({'type': 'done'})}\n\n"
                                break
            except httpx.ConnectError:
                yield f"data: {json.dumps({'type': 'error', 'message': 'Ollama connection failed.'})}\n\n"
                return

        # Save AI Response
        if full_ai_response:
            db_write = SessionLocal()
            try:
                ai_msg = models.ChatMessage(session_id=id, role="assistant", content=full_ai_response)
                db_write.add(ai_msg)
                db_write.commit()
            finally:
                db_write.close()

    return StreamingResponse(streaming_generator(), media_type="text/event-stream")