"""
Re-export all views from domain apps.

urls.py stays unchanged — it still does `from . import views` and
references views.health, views.auth, etc. All logic lives in apps/.
"""
# ruff: noqa: F401
from apps.identity.views import (
    health,
    challenge,
    auth,
    register,
    lookup,
    backup,
    restore,
    contacts_backup_save,
    contacts_backup_fetch,
)
from apps.push.views import push_token, notify
from apps.profile.views import profile_get, profile_update, profile_picture_upload
from apps.messaging.views import (
    message_send,
    message_fetch,
    message_receipt,
    message_status,
    message_image_upload,
    message_audio_upload,
)
from apps.relay.views import relay_message, pending_messages
