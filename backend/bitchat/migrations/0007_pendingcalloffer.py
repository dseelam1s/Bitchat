from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('bitchat', '0006_message_duration'),
    ]

    operations = [
        migrations.CreateModel(
            name='PendingCallOffer',
            fields=[
                ('id', models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name='ID')),
                ('call_id', models.CharField(db_index=True, max_length=128, unique=True)),
                ('caller_pubkey', models.CharField(max_length=128)),
                ('receiver_pubkey', models.CharField(max_length=128)),
                ('payload', models.TextField()),
                ('expires_at', models.DateTimeField()),
                ('created_at', models.DateTimeField(auto_now_add=True)),
            ],
            options={
                'verbose_name': 'Pending Call Offer',
            },
        ),
        migrations.AddIndex(
            model_name='pendingcalloffer',
            index=models.Index(fields=['receiver_pubkey', 'expires_at'], name='bitchat_pen_receive_idx'),
        ),
    ]
