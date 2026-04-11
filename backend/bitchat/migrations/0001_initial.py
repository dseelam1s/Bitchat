from django.conf import settings
from django.db import migrations, models
import django.db.models.deletion


class Migration(migrations.Migration):

    initial = True

    dependencies = [
        migrations.swappable_dependency(settings.AUTH_USER_MODEL),
    ]

    operations = [
        migrations.CreateModel(
            name='AuthChallenge',
            fields=[
                ('id', models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name='ID')),
                ('challenge', models.CharField(max_length=128, unique=True)),
                ('created_at', models.DateTimeField(auto_now_add=True)),
                ('used', models.BooleanField(default=False)),
            ],
            options={
                'verbose_name': 'Auth Challenge',
            },
        ),
        migrations.CreateModel(
            name='RestoreAttempt',
            fields=[
                ('id', models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name='ID')),
                ('short_id', models.CharField(db_index=True, max_length=6)),
                ('attempts', models.IntegerField(default=0)),
                ('locked_until', models.DateTimeField(blank=True, null=True)),
                ('last_attempt', models.DateTimeField(auto_now=True)),
            ],
            options={
                'verbose_name': 'Restore Attempt',
            },
        ),
        migrations.CreateModel(
            name='BitChatIdentity',
            fields=[
                ('id', models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name='ID')),
                ('pubkey', models.CharField(db_index=True, max_length=128, unique=True)),
                ('short_id', models.CharField(db_index=True, max_length=6, unique=True)),
                ('display_name', models.CharField(blank=True, max_length=100)),
                ('encrypted_backup', models.TextField(blank=True)),
                # recovery_code removed — restore uses short_id + backup password only
                ('push_token_fcm', models.CharField(blank=True, max_length=512)),
                ('push_token_apns', models.CharField(blank=True, max_length=512)),
                ('profile_picture_url', models.URLField(blank=True, max_length=512)),
                ('created_at', models.DateTimeField(auto_now_add=True)),
                ('updated_at', models.DateTimeField(auto_now=True)),
                ('user', models.OneToOneField(
                    on_delete=django.db.models.deletion.CASCADE,
                    related_name='bitchat_identity',
                    to=settings.AUTH_USER_MODEL,
                )),
            ],
            options={
                'verbose_name': 'BitChat Identity',
                'verbose_name_plural': 'BitChat Identities',
            },
        ),
    ]
