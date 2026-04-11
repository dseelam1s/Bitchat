from django.contrib import admin
from .models import AuthChallenge, BitChatIdentity, RestoreAttempt


@admin.register(BitChatIdentity)
class BitChatIdentityAdmin(admin.ModelAdmin):
    list_display = ['short_id', 'display_name', 'pubkey_short', 'has_backup', 'has_push_token', 'created_at']
    search_fields = ['short_id', 'pubkey', 'display_name']
    readonly_fields = ['pubkey', 'short_id', 'created_at', 'updated_at']
    list_filter = ['created_at']

    def pubkey_short(self, obj):
        return f'{obj.pubkey[:16]}...'
    pubkey_short.short_description = 'Pubkey'

    def has_backup(self, obj):
        return bool(obj.encrypted_backup)
    has_backup.boolean = True
    has_backup.short_description = 'Backup'

    def has_push_token(self, obj):
        return bool(obj.push_token_fcm or obj.push_token_apns)
    has_push_token.boolean = True
    has_push_token.short_description = 'Push'


@admin.register(AuthChallenge)
class AuthChallengeAdmin(admin.ModelAdmin):
    list_display = ['challenge_short', 'used', 'created_at']
    list_filter = ['used']
    readonly_fields = ['challenge', 'created_at']

    def challenge_short(self, obj):
        return f'{obj.challenge[:16]}...'
    challenge_short.short_description = 'Challenge'


@admin.register(RestoreAttempt)
class RestoreAttemptAdmin(admin.ModelAdmin):
    list_display = ['short_id', 'attempts', 'is_locked_display', 'locked_until', 'last_attempt']
    readonly_fields = ['last_attempt']

    def is_locked_display(self, obj):
        return obj.is_locked
    is_locked_display.boolean = True
    is_locked_display.short_description = 'Locked'
