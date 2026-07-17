from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('bitchat', '0011_messages_backup_userstatus'),
    ]

    operations = [
        migrations.AddField(
            model_name='group',
            name='members_can_message',
            field=models.BooleanField(default=True),
        ),
    ]
