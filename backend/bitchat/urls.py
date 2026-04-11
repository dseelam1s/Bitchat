from django.urls import path
from . import views

app_name = 'bitchat'

urlpatterns = [
    # ── Public (no auth needed) ───────────────────────────────────
    path('health/',                 views.health,         name='health'),
    path('challenge/',              views.challenge,      name='challenge'),
    path('auth/',                   views.auth,           name='auth'),
    path('lookup/',                 views.lookup,         name='lookup'),
    path('restore/',                views.restore,        name='restore'),
    path('profile/<str:pubkey>/',   views.profile_get,    name='profile_get'),

    # ── Authenticated ─────────────────────────────────────────────
    path('register/',               views.register,       name='register'),
    path('backup/',                 views.backup,                   name='backup'),
    path('contacts/backup/',        views.contacts_backup_save,     name='contacts_backup_save'),
    path('contacts/backup/fetch/',  views.contacts_backup_fetch,    name='contacts_backup_fetch'),
    path('push-token/',             views.push_token,     name='push_token'),
    path('profile/',                        views.profile_update,           name='profile_update'),
    path('profile/upload-picture/',         views.profile_picture_upload,   name='profile_picture_upload'),
    path('messages/image/upload/',          views.message_image_upload,     name='message_image_upload'),
    path('messages/audio/upload/',          views.message_audio_upload,     name='message_audio_upload'),
    path('notify/',                         views.notify,                   name='notify'),
    path('relay/',                          views.relay_message,            name='relay_message'),
    path('messages/pending/',               views.pending_messages,         name='pending_messages'),

    # ── Online messaging (WhatsApp-style) ─────────────────────────────────
    path('messages/send/',                  views.message_send,             name='message_send'),
    path('messages/',                       views.message_fetch,            name='message_fetch'),
    path('messages/receipt/',               views.message_receipt,          name='message_receipt'),
    path('messages/status/',                views.message_status,           name='message_status'),
]
