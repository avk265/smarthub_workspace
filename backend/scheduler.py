import uuid
import json
import datetime
import pika
from apscheduler.schedulers.background import BackgroundScheduler

# Absolute imports targeting your FastAPI app directory
from app.database import SessionLocal
from app import models

def publish_to_rabbitmq(queue_name: str, messages: list):
    """Drops the formulated JSON payloads into the worker's queue"""
    connection = pika.BlockingConnection(pika.ConnectionParameters(host='localhost'))
    channel = connection.channel()
    channel.queue_declare(queue=queue_name, durable=True)
    
    for message in messages:
        channel.basic_publish(
            exchange='',
            routing_key=queue_name,
            body=json.dumps(message),
            properties=pika.BasicProperties(delivery_mode=pika.spec.PERSISTENT_DELIVERY_MODE)
        )
    connection.close()

def run_daily_reminders():
    print("\n[SCHEDULER] --- Checking for Due Tasks ---")
    db = SessionLocal()
    
    try:
        today = datetime.datetime.now().date()
        print(f"[DEBUG] Today's local date is: {today}")
        
        active_todos = db.query(models.Todo).filter(
            models.Todo.completed == False, 
            models.Todo.due_date != None
        ).all()

        print(f"[DEBUG] Found {len(active_todos)} active tasks with a due date.")

        email_jobs = []
        notifications_created = 0

        for todo in active_todos:
            print(f"\n[DEBUG] Analyzing Task: '{todo.title}'")
            print(f"        Raw DB due_date string: {todo.due_date}")
            
            try:
                # Safely parse Flutter's ISO string (handling the 'Z' timezone edge case)
                if isinstance(todo.due_date, str):
                    clean_date_str = todo.due_date.replace('Z', '+00:00')
                    due_date_obj = datetime.datetime.fromisoformat(clean_date_str).date()
                else:
                    due_date_obj = todo.due_date.date()
                    
                days_until_due = (due_date_obj - today).days
                print(f"        Parsed due date: {due_date_obj} | Days Remaining: {days_until_due}")

                # Trigger condition: Exactly 1 day remaining
                if days_until_due == 1:
                    print("        >>> MATCH! Triggering inbox alert... <<<")
                    
                    user = db.query(models.User).filter(models.User.id == todo.user_id).first()
                    if not user: 
                        print("        [!] Error: Could not find user associated with task.")
                        continue

                    # 1. Write to the SmartHub App Inbox
                    inbox_msg = models.AppNotification(
                        id=str(uuid.uuid4()), 
                        user_id=user.id,
                        title="Task Due Soon ⏰",
                        message=f"Your task '{todo.title}' is due tomorrow. Don't forget to complete it!"
                    )
                    db.add(inbox_msg)
                    notifications_created += 1

                    # 2. Package the JSON payload for the RabbitMQ Worker
                    email_jobs.append({
                        "job_id": f"todo_reminder_{todo.id}",
                        "task_id": str(uuid.uuid4()),
                        "channel": "email",
                        "recipient": user.email,
                        "message": (
                            f"Hello {user.full_name},\n\n"
                            f"This is a friendly reminder that your task:\n"
                            f"'{todo.title}'\n\n"
                            f"is due on {due_date_obj.strftime('%B %d, %Y')}.\n\n"
                            f"Log in to SmartHub to view your pending tasks!"
                        )
                    })
            except Exception as parse_error:
                print(f"        [!] Date parsing failed for task '{todo.title}': {parse_error}")

        # Save inbox alerts to the DB
        if notifications_created > 0:
            db.commit()
            
        # Push email payloads to the worker
        if email_jobs:
            publish_to_rabbitmq("email.process", email_jobs)
            
        print(f"\n[SCHEDULER] Generated {notifications_created} inbox alerts and {len(email_jobs)} email jobs.")

    except Exception as e:
        print(f"[SCHEDULER ERROR]: {e}")
    finally:
        db.close()
# Make sure to update your import at the top of the file to:
# from apscheduler.schedulers.background import BackgroundScheduler
import time

import uuid
import json
import datetime
import pika
from apscheduler.schedulers.background import BackgroundScheduler

# Absolute imports targeting your FastAPI app directory
from app.database import SessionLocal
from app import models

def publish_to_rabbitmq(queue_name: str, messages: list):
    """Drops the formulated JSON payloads into the worker's queue"""
    connection = pika.BlockingConnection(pika.ConnectionParameters(host='localhost'))
    channel = connection.channel()
    channel.queue_declare(queue=queue_name, durable=True)
    
    for message in messages:
        channel.basic_publish(
            exchange='',
            routing_key=queue_name,
            body=json.dumps(message),
            properties=pika.BasicProperties(delivery_mode=pika.spec.PERSISTENT_DELIVERY_MODE)
        )
    connection.close()

def run_daily_reminders():
    print("\n[SCHEDULER] --- Checking for Due Tasks ---")
    db = SessionLocal()
    
    try:
        today = datetime.datetime.now().date()
        print(f"[DEBUG] Today's local date is: {today}")
        
        active_todos = db.query(models.Todo).filter(
            models.Todo.completed == False, 
            models.Todo.due_date != None
        ).all()

        print(f"[DEBUG] Found {len(active_todos)} active tasks with a due date.")

        email_jobs = []
        notifications_created = 0

        for todo in active_todos:
            print(f"\n[DEBUG] Analyzing Task: '{todo.title}'")
            print(f"        Raw DB due_date string: {todo.due_date}")
            
            try:
                # Safely parse Flutter's ISO string (handling the 'Z' timezone edge case)
                if isinstance(todo.due_date, str):
                    clean_date_str = todo.due_date.replace('Z', '+00:00')
                    due_date_obj = datetime.datetime.fromisoformat(clean_date_str).date()
                else:
                    due_date_obj = todo.due_date.date()
                    
                days_until_due = (due_date_obj - today).days
                print(f"        Parsed due date: {due_date_obj} | Days Remaining: {days_until_due}")

                # Trigger condition: Exactly 1 day remaining
                if days_until_due == 1:
                    print("        >>> MATCH! Triggering inbox alert... <<<")
                    
                    user = db.query(models.User).filter(models.User.id == todo.user_id).first()
                    if not user: 
                        print("        [!] Error: Could not find user associated with task.")
                        continue

                    # 1. Write to the SmartHub App Inbox
                    inbox_msg = models.AppNotification(
                        id=str(uuid.uuid4()), 
                        user_id=user.id,
                        title="Task Due Soon ⏰",
                        message=f"Your task '{todo.title}' is due tomorrow. Don't forget to complete it!"
                    )
                    db.add(inbox_msg)
                    notifications_created += 1

                    # 2. Package the JSON payload for the RabbitMQ Worker
                    email_jobs.append({
                        "job_id": f"todo_reminder_{todo.id}",
                        "task_id": str(uuid.uuid4()),
                        "channel": "email",
                        "recipient": user.email,
                        "message": (
                            f"Hello {user.full_name},\n\n"
                            f"This is a friendly reminder that your task:\n"
                            f"'{todo.title}'\n\n"
                            f"is due on {due_date_obj.strftime('%B %d, %Y')}.\n\n"
                            f"Log in to SmartHub to view your pending tasks!"
                        )
                    })
            except Exception as parse_error:
                print(f"        [!] Date parsing failed for task '{todo.title}': {parse_error}")

        # Save inbox alerts to the DB
        if notifications_created > 0:
            db.commit()
            
        # Push email payloads to the worker
        if email_jobs:
            publish_to_rabbitmq("email.process", email_jobs)
            
        print(f"\n[SCHEDULER] Generated {notifications_created} inbox alerts and {len(email_jobs)} email jobs.")

    except Exception as e:
        print(f"[SCHEDULER ERROR]: {e}")
    finally:
        db.close()
# Make sure to update your import at the top of the file to:
# from apscheduler.schedulers.background import BackgroundScheduler
import time

if __name__ == '__main__':
    print("[*] Starting Master Scheduler Service...")
    
    # Use BackgroundScheduler instead of BlockingScheduler
    scheduler = BackgroundScheduler()
    
    # Run every morning at 8:00 AM
    scheduler.add_job(run_daily_reminders, 'cron', hour=8, minute=0)
    
    scheduler.start()
    
    try:
        # This keeps the main thread alive but is highly responsive to Ctrl+C
        while True:
            time.sleep(1)
    except KeyboardInterrupt:
        print("\n[*] Ctrl+C detected! Scheduler shutting down cleanly...")
        scheduler.shutdown()