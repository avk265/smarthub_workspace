import os
import sys
import json
import time
import random
import smtplib
from email.mime.text import MIMEText

import pika
import psycopg2
import firebase_admin
from firebase_admin import credentials, messaging
from dotenv import load_dotenv

# ==========================================
# --- CONFIGURATION & INITIALIZATION ---
# ==========================================
load_dotenv()
DB_URL = os.getenv("DATABASE_URL")
MAX_RETRIES = 3

try:
    cred = credentials.Certificate("firebase-credentials.json")
    firebase_admin.initialize_app(cred)
    print("[*] Firebase Admin initialized successfully.")
except Exception as e:
    print(f"[!] Warning: Firebase initialization failed: {e}")

# ==========================================
# --- DATABASE HELPERS (For Job Status Only) ---
# ==========================================
# Notice: No SQLAlchemy! Just lightweight SQL to update job progress.
def update_job_success(job_id):
    try:
        conn = psycopg2.connect(DB_URL)
        cur = conn.cursor()
        cur.execute("UPDATE notification_jobs SET sent = sent + 1 WHERE id = %s;", (job_id,))
        conn.commit()
        cur.close()
        conn.close()
    except Exception as e:
        print(f"Database error (Success Update): {e}")

def update_job_failed(job_id):
    try:
        conn = psycopg2.connect(DB_URL)
        cur = conn.cursor()
        cur.execute("UPDATE notification_jobs SET failed = failed + 1 WHERE id = %s;", (job_id,))
        conn.commit()
        cur.close()
        conn.close()
    except Exception as e:
        print(f"Database error (Failure Update): {e}")

# ==========================================
# --- NOTIFICATION DISPATCHERS ---
# ==========================================
def send_email(recipient: str, message_body: str):
    smtp_server = os.getenv("SMTP_SERVER", "smtp.gmail.com")
    smtp_port = int(os.getenv("SMTP_PORT", 587))
    smtp_user = os.getenv("SMTP_USERNAME")
    smtp_pass = os.getenv("SMTP_PASSWORD")
    
    if not smtp_user or not smtp_pass:
        print(f"[MOCK EMAIL] To {recipient}: {message_body}")
        return

    msg = MIMEText(message_body)
    msg['Subject'] = "SmartHub Notification"
    msg['From'] = smtp_user
    msg['To'] = recipient

    try:
        server = smtplib.SMTP(smtp_server, smtp_port)
        server.starttls()
        server.login(smtp_user, smtp_pass)
        server.sendmail(smtp_user, recipient, msg.as_string())
        server.quit()
        print(f"[LIVE EMAIL] Successfully dispatched to {recipient}")
    except Exception as e:
        print(f"[EMAIL ERROR] Failed to send live email: {e}")
        raise e

def send_sms(recipient: str, message_body: str):
    print(f"[MOCK SMS] Successfully dispatched to {recipient}: {message_body}")

def send_whatsapp(recipient: str, message_body: str):
    print(f"[MOCK WHATSAPP] Successfully dispatched to {recipient}: {message_body}")

def send_push(recipients, title: str, message_body: str):
    if isinstance(recipients, str):
        recipients = [recipients]
        
    valid_tokens = [t for t in recipients if t and isinstance(t, str)]
    if not valid_tokens:
        print("[PUSH] No valid FCM tokens in this batch, skipping.")
        return

    fcm_message = messaging.MulticastMessage(
        notification=messaging.Notification(title=title, body=message_body),
        data={
            "click_action": "FLUTTER_NOTIFICATION_CLICK",
            "type": "inbox_update"
        },
        tokens=valid_tokens
    )

    try:
        response = messaging.send_each_for_multicast(fcm_message)
        print(f"[LIVE PUSH] Batch complete: {response.success_count} success, {response.failure_count} failed.")
    except Exception as e:
        print(f"[PUSH ERROR] Critical Firebase Error: {e}")
        raise e

# ==========================================
# --- QUEUE CONSUMER & ROUTING ---
# ==========================================
def callback(ch, method, properties, body):
    data = json.loads(body)
    job_id = data.get("job_id")
    task_id = data.get("task_id", "Unknown")
    recipient = data.get("recipient", "Unknown")
    message_content = data.get("message", "Default SmartHub Notification")
    title = data.get("title", "SmartHub Alert")
    
    queue_name = method.routing_key 
    if "email" in queue_name: channel_type = "Email"
    elif "sms" in queue_name: channel_type = "SMS"
    elif "push" in queue_name: channel_type = "Push"
    else: channel_type = "WhatsApp"

    headers = properties.headers or {}
    retry_count = headers.get('x-retry-count', 0)

    is_live_dispatch = (job_id == "single_send" or str(job_id).startswith("bulk_push_") or str(job_id).startswith("live_bulk_") or str(job_id).startswith("todo_reminder_"))

    try:
        if is_live_dispatch:
            print(f"[LIVE DISPATCH] Sending REAL {channel_type} task {task_id} (Attempt {retry_count + 1})...")
            if channel_type == 'Email': send_email(recipient, message_content)
            elif channel_type == 'SMS': send_sms(recipient, message_content)
            elif channel_type == 'Push': send_push(recipient, title, message_content)
            else: send_whatsapp(recipient, message_content)
        else:
            print(f"[SIMULATED BULK] {channel_type} task {task_id} for Job {job_id}...")
            if random.random() < 0.20:
                raise Exception("Random simulated network timeout!")
            time.sleep(0.1)
            update_job_success(job_id)

        ch.basic_ack(delivery_tag=method.delivery_tag)
        if is_live_dispatch:
            print(f"[job.success] Live dispatch complete for {task_id}")

    except Exception as e:
        print(f"[job.error] {channel_type} Task {task_id} Failed: {str(e)}")
        ch.basic_ack(delivery_tag=method.delivery_tag)

        delay_schedule = { 1: 60000, 2: 300000, 3: 1800000 }

        if retry_count < MAX_RETRIES:
            next_attempt = retry_count + 1
            delay_ms = delay_schedule[next_attempt]
            headers['x-retry-count'] = next_attempt
            
            ch.basic_publish(
                exchange='',
                routing_key=f"{channel_type.lower()}.retry", 
                properties=pika.BasicProperties(headers=headers, expiration=str(delay_ms)),
                body=body
            )
        else:
            ch.basic_publish(
                exchange='', routing_key='dlq.notifications',
                properties=pika.BasicProperties(headers=headers), body=body
            )
            update_job_failed(job_id)

def main():
    print("[*] Worker booting up...")
    connection = pika.BlockingConnection(pika.ConnectionParameters(host='localhost'))
    channel = connection.channel()
    
    channels = ['email', 'sms', 'push', 'whatsapp']
    for c in channels:
        channel.queue_declare(queue=f'{c}.process', durable=True)
        channel.queue_declare(queue=f'{c}.retry', durable=True, arguments={
            'x-dead-letter-exchange': '',
            'x-dead-letter-routing-key': f'{c}.process'
        })
        
    channel.queue_declare(queue='dlq.notifications', durable=True)

    print("[*] Waiting for messages across all channels. To exit press CTRL+C")
    channel.basic_qos(prefetch_count=1)
    
    for c in channels:
        channel.basic_consume(queue=f'{c}.process', on_message_callback=callback)
    
    try:
        channel.start_consuming()
    except KeyboardInterrupt:
        print("\n[SYSTEM] Shutting down worker...")
        connection.close()
        sys.exit(0)

if __name__ == '__main__':
    main()