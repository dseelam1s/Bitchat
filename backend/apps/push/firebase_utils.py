"""
Firebase Admin SDK utilities for push notifications.

Setup required:
1. Go to Firebase Console → Project Settings → Service Accounts
2. Click "Generate new private key" → download JSON
3. Set FIREBASE_CREDENTIALS_PATH=/path/to/key.json in your .env

If not configured, push notifications are silently disabled.
"""
import os

import firebase_admin
from firebase_admin import credentials, messaging
from decouple import config

_initialized = False


def _init():
    global _initialized
    if _initialized or firebase_admin._apps:
        _initialized = True
        return
    cred_path = config('FIREBASE_CREDENTIALS_PATH', default='')
    if not cred_path or not os.path.exists(cred_path):
        return
    try:
        cred = credentials.Certificate(cred_path)
        firebase_admin.initialize_app(cred)
        _initialized = True
    except Exception:
        pass


def send_push(token: str, title: str, body: str, data: dict = None,
              data_only: bool = False) -> bool:
    """Send an FCM push notification. Returns True on success.

    data: optional key/value strings included as FCM data payload.
          Flutter reads this via message.data to navigate to the right screen.
    data_only: omit the notification block so Android does NOT auto-display a
          banner — instead the app's background handler runs and can draw its
          own UI (used for incoming calls → full-screen ringing screen).
    """
    _init()
    if not firebase_admin._apps:
        return False
    try:
        # FCM data values must be strings
        str_data = {k: str(v) for k, v in (data or {}).items()}
        message = messaging.Message(
            notification=None if data_only else messaging.Notification(title=title, body=body),
            data=str_data if str_data else None,
            android=messaging.AndroidConfig(priority='high'),
            apns=messaging.APNSConfig(
                payload=messaging.APNSPayload(
                    aps=messaging.Aps(sound='default')
                )
            ),
            token=token,
        )
        messaging.send(message)
        return True
    except Exception:
        return False
