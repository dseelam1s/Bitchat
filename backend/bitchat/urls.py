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
    path('profile/upload-picture/',         views.profile_picture_upload,   name='profile_picture_upload'),
    path('profile/me/',                       views.profile_me,               name='profile_me'),
    path('profile/<str:pubkey>/',           views.profile_get,              name='profile_get'),
    path('profiles/search/',                views.profile_search,           name='profile_search'),

    # ── Authenticated ─────────────────────────────────────────────
    path('register/',               views.register,       name='register'),
    path('backup/',                 views.backup,                   name='backup'),
    path('contacts/backup/',        views.contacts_backup_save,     name='contacts_backup_save'),
    path('contacts/backup/fetch/',  views.contacts_backup_fetch,    name='contacts_backup_fetch'),
    path('push-token/',             views.push_token,     name='push_token'),
    path('profile/',                        views.profile_update,           name='profile_update'),
    path('messages/image/upload/',          views.message_image_upload,     name='message_image_upload'),
    path('messages/audio/upload/',          views.message_audio_upload,     name='message_audio_upload'),
    path('notify/',                         views.notify,                   name='notify'),
    path('relay/',                          views.relay_message,            name='relay_message'),
    path('messages/pending/',               views.pending_messages,         name='pending_messages'),

    # ── Connections (mutual follow / people discovery) ────────────────────
    path('connections/',                    views.connections_list,             name='connections_list'),
    path('connections/pending/',            views.connection_requests_pending,  name='connection_requests_pending'),
    path('connections/request/',            views.connection_request_send,      name='connection_request_send'),
    path('connections/<int:pk>/accept/',    views.connection_request_accept,    name='connection_request_accept'),
    path('connections/<int:pk>/decline/',   views.connection_request_decline,   name='connection_request_decline'),

    # ── Online messaging (WhatsApp-style) ─────────────────────────────────
    path('messages/send/',                  views.message_send,             name='message_send'),
    path('messages/',                       views.message_fetch,            name='message_fetch'),
    path('messages/receipt/',               views.message_receipt,          name='message_receipt'),
    path('messages/status/',                views.message_status,           name='message_status'),
]
