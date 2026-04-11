from django.contrib.auth import get_user_model
from django.db import models
from django.utils import timezone

User = get_user_model()


class BitChatIdentity(models.Model):
    """
    Maps a cryptographic keypair (pubkey) to a unique short ID.
    The user never creates a password — their private key is their identity.
    Server stores encrypted_backup but can never decrypt it.
    """
    user = models.OneToOneField(
        User,
        on_delete=models.CASCADE,
        related_name='bitchat_identity',
    )
    pubkey = models.CharField(max_length=128, unique=True, db_index=True)
    short_id = models.CharField(max_length=8, unique=True, db_index=True)
    display_name = models.CharField(max_length=100, blank=True)

    # Private key encrypted by user's backup password before sending.
    # Server stores ciphertext only — cannot decrypt without the user's password.
    encrypted_backup = models.TextField(blank=True)

    # Optional recovery code — not required for restore (short_id + backup password is enough).
    # Kept for future use if extra security layer is needed.
    # recovery_code = models.CharField(max_length=14, blank=True)

    # Push notification tokens
    push_token_fcm = models.CharField(max_length=512, blank=True)   # Android / FCM
    push_token_apns = models.CharField(max_length=512, blank=True)  # iOS / APNs

    # Profile picture URL — client uploads to cloud storage, stores URL here.
    # Published in Nostr kind:0, fetched by other clients.
    profile_picture_url = models.URLField(max_length=512, blank=True)

    # Contact list backup — NIP-44 encrypted JSON blob, server cannot read it.
    # Format (before encryption): [{"pubkey": "...", "name": "..."}, ...]
    contacts_backup = models.TextField(blank=True)

    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    def save(self, *args, **kwargs):
        super().save(*args, **kwargs)

    def __str__(self):
        name = self.display_name or f'#{self.short_id}'
        return f'{name} ({self.pubkey[:16]}...)'

    class Meta:
        verbose_name = 'BitChat Identity'
        verbose_name_plural = 'BitChat Identities'


class AuthChallenge(models.Model):
    """
    One-time random challenge issued by the server.
    App signs it with the user's private key to prove identity without a password.
    Expires after 5 minutes, single use only.
    """
    challenge = models.CharField(max_length=128, unique=True)
    created_at = models.DateTimeField(auto_now_add=True)
    used = models.BooleanField(default=False)

    @property
    def is_expired(self):
        return (timezone.now() - self.created_at).total_seconds() > 300

    def __str__(self):
        return f'Challenge {self.challenge[:16]}... (used={self.used})'

    class Meta:
        verbose_name = 'Auth Challenge'


class RestoreAttempt(models.Model):
    """
    Rate-limits restore attempts per short_id.
    Locks out for 1 hour after 5 failed attempts.
    """
    short_id = models.CharField(max_length=8, db_index=True)
    attempts = models.IntegerField(default=0)
    locked_until = models.DateTimeField(null=True, blank=True)
    last_attempt = models.DateTimeField(auto_now=True)

    @property
    def is_locked(self):
        return bool(self.locked_until and timezone.now() < self.locked_until)

    def __str__(self):
        return f'RestoreAttempt #{self.short_id} ({self.attempts} attempts)'

    class Meta:
        verbose_name = 'Restore Attempt'


class Message(models.Model):
    """
    Online WhatsApp-style message store.
    Server stores NIP-44 ciphertext only — cannot read content.
    Messages are kept for 30 days then auto-deleted.
    Indexed for fast per-user fetch ordered by timestamp.
    """
    STATUS_SENT      = 'sent'
    STATUS_DELIVERED = 'delivered'
    STATUS_READ      = 'read'
    STATUS_CHOICES   = [
        (STATUS_SENT,      'Sent'),
        (STATUS_DELIVERED, 'Delivered'),
        (STATUS_READ,      'Read'),
    ]

    message_id        = models.CharField(max_length=128, unique=True, db_index=True)
    sender_pubkey     = models.CharField(max_length=128, db_index=True)
    receiver_pubkey   = models.CharField(max_length=128, db_index=True)
    encrypted_content = models.TextField()          # NIP-44 ciphertext
    message_type      = models.CharField(max_length=32, default='dm')
    timestamp         = models.BigIntegerField()    # Unix seconds from sender
    status            = models.CharField(max_length=16, default=STATUS_SENT, choices=STATUS_CHOICES)
    sender_name       = models.CharField(max_length=100, blank=True)
    duration          = models.IntegerField(default=0)  # seconds; non-zero for voice notes
    created_at        = models.DateTimeField(auto_now_add=True)
    delivered_at      = models.DateTimeField(null=True, blank=True)
    read_at           = models.DateTimeField(null=True, blank=True)

    class Meta:
        indexes = [
            models.Index(fields=['receiver_pubkey', 'status', 'timestamp']),
            models.Index(fields=['sender_pubkey', 'receiver_pubkey', 'timestamp']),
        ]
        verbose_name = 'Message'
        verbose_name_plural = 'Messages'

    def __str__(self):
        return f'{self.message_id[:8]}... {self.sender_pubkey[:8]}→{self.receiver_pubkey[:8]} [{self.status}]'


class PendingMessage(models.Model):
    """
    Stores an encrypted mesh message relayed by an internet-connected device (C)
    on behalf of an offline sender (A) destined for B.

    Server never decrypts the content — it stores the NIP-44 ciphertext as-is.
    B fetches and decrypts on-device when they come online.
    Auto-deleted after 7 days if not delivered.
    """
    message_id = models.CharField(max_length=128, unique=True, db_index=True)
    sender_pubkey = models.CharField(max_length=128, db_index=True)
    receiver_pubkey = models.CharField(max_length=128, db_index=True)
    encrypted_content = models.TextField()   # NIP-44 ciphertext — server cannot read
    timestamp = models.BigIntegerField()     # original Unix timestamp from sender
    message_type = models.CharField(max_length=32, default='dm')
    delivered = models.BooleanField(default=False)
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        indexes = [
            models.Index(fields=['receiver_pubkey', 'delivered']),
        ]
        verbose_name = 'Pending Message'
        verbose_name_plural = 'Pending Messages'

    def __str__(self):
        return f'Msg {self.message_id[:8]}... → {self.receiver_pubkey[:8]}...'
