import fitz  # PyMuPDF
import chromadb
import httpx
from sqlalchemy.orm import Session
from . import models  # Assumes models.py is in the same directory

# TRAP 1 FIXED: Removed global chroma_client from here!

def process_document_background(file_path: str, user_id: str, document_id: str, db_session_factory):
    # TRAP 1 FIXED: Lazy-load the client inside the function
    chroma_client = chromadb.HttpClient(host="localhost", port=8002)

    print(f"[*] Starting vector indexing for document ID: {document_id}")
    
    # 1. Extract plain text from PDF
    text = ""
    try:
        doc = fitz.open(file_path)
        for page in doc:
            text += page.get_text()
    except Exception as e:
        print(f"[!] PyMuPDF extraction failed: {e}")
        return

    # 2. Chunk text into manageable sliding segments (~500 words)
    words = text.split()
    chunks = [" ".join(words[i:i + 500]) for i in range(0, len(words), 450)]

    # TRAP 2 FIXED: Removed .replace('-', '') so it matches main.py exactly
    collection_name = f"user_{user_id}"
    collection = chroma_client.get_or_create_collection(name=collection_name)

    # 4. Convert chunks to vectors and store in ChromaDB
    for i, chunk in enumerate(chunks):
        if not chunk.strip(): 
            continue
        try:
            res = httpx.post("http://localhost:11434/api/embeddings", json={
                "model": "nomic-embed-text",
                "prompt": chunk
            }, timeout=30.0).json()
            
            embedding = res.get("embedding", [])
            if embedding:
                collection.add(
                    ids=[f"{document_id}_chunk_{i}"],
                    embeddings=[embedding],
                    documents=[chunk]
                )
        except Exception as e:
            print(f"[!] Token embedding breakdown: {e}")

    # 5. Update state in PostgreSQL using a clean session lifecycle
    db: Session = db_session_factory()
    try:
        db_doc = db.query(models.Document).filter(models.Document.id == document_id).first()
        if db_doc:
            db_doc.processed = True
            db_doc.chroma_collection = collection_name
            db.commit()
            print(f"[+] Document {document_id} marked as fully indexed in Postgres.")
    except Exception as e:
        print(f"[!] Database callback state failed: {e}")
    finally:
        db.close()