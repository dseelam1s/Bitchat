from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('bitchat', '0008_pendingcalloffer_receiver_index'),
    ]

    operations = [
        # ── BitChatIdentity: bio + discovery flags ────────────────────────────
        migrations.AddField(
            model_name='bitchatidentity',
            name='bio',
            field=models.CharField(blank=True, max_length=150),
        ),
        migrations.AddField(
            model_name='bitchatidentity',
            name='is_public',
            field=models.BooleanField(default=True),
        ),
        migrations.AddField(
            model_name='bitchatidentity',
            name='is_discoverable_nearby',
            field=models.BooleanField(default=True),
        ),

        # ── ConnectionRequest model ───────────────────────────────────────────
        migrations.CreateModel(
            name='ConnectionRequest',
            fields=[
                ('id', models.AutoField(auto_created=True, primary_key=True, serialize=False)),
                ('from_pubkey', models.CharField(db_index=True, max_length=128)),
                ('to_pubkey', models.CharField(db_index=True, max_length=128)),
                ('status', models.CharField(
                    choices=[('pending', 'Pending'), ('accepted', 'Accepted'), ('declined', 'Declined')],
                    default='pending',
                    max_length=16,
                )),
                ('created_at', models.DateTimeField(auto_now_add=True)),
                ('updated_at', models.DateTimeField(auto_now=True)),
            ],
            options={
                'verbose_name': 'Connection Request',
                'verbose_name_plural': 'Connection Requests',
            },
        ),
        migrations.AlterUniqueTogether(
            name='connectionrequest',
            unique_together={('from_pubkey', 'to_pubkey')},
        ),
        migrations.AddIndex(
            model_name='connectionrequest',
            index=models.Index(fields=['to_pubkey', 'status'], name='conn_to_status_idx'),
        ),
        migrations.AddIndex(
            model_name='connectionrequest',
            index=models.Index(fields=['from_pubkey', 'status'], name='conn_from_status_idx'),
        ),
    ]
