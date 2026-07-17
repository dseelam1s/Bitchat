from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('bitchat', '0010_groups'),
    ]

    operations = [
        migrations.AddField(
            model_name='bitchatidentity',
            name='messages_backup',
            field=models.TextField(blank=True),
        ),
        migrations.CreateModel(
            name='UserStatus',
            fields=[
                ('id', models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name='ID')),
                ('pubkey', models.CharField(db_index=True, max_length=128, unique=True)),
                ('emoji', models.CharField(blank=True, max_length=16)),
                ('text', models.CharField(blank=True, max_length=140)),
                ('updated_at', models.DateTimeField(auto_now=True)),
            ],
            options={
                'verbose_name': 'User Status',
                'verbose_name_plural': 'User Statuses',
            },
        ),
    ]
