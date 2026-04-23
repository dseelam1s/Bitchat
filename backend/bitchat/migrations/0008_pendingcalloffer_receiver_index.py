from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('bitchat', '0007_pendingcalloffer'),
    ]

    operations = [
        migrations.AlterField(
            model_name='pendingcalloffer',
            name='receiver_pubkey',
            field=models.CharField(db_index=True, max_length=128),
        ),
    ]
