from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('bitchat', '0005_contacts_backup'),
    ]

    operations = [
        migrations.AddField(
            model_name='message',
            name='duration',
            field=models.IntegerField(default=0),
        ),
    ]
