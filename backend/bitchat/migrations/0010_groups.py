from django.db import migrations, models
import django.db.models.deletion


class Migration(migrations.Migration):

    dependencies = [
        ('bitchat', '0009_bio_discoverable_connectionrequest'),
    ]

    operations = [
        migrations.CreateModel(
            name='Group',
            fields=[
                ('id', models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name='ID')),
                ('group_id', models.CharField(db_index=True, max_length=64, unique=True)),
                ('name', models.CharField(max_length=100)),
                ('admin_pubkey', models.CharField(db_index=True, max_length=128)),
                ('members_visible', models.BooleanField(default=True)),
                ('created_at', models.DateTimeField(auto_now_add=True)),
            ],
        ),
        migrations.CreateModel(
            name='GroupMember',
            fields=[
                ('id', models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name='ID')),
                ('pubkey', models.CharField(db_index=True, max_length=128)),
                ('alias_n', models.IntegerField()),
                ('added_at', models.DateTimeField(auto_now_add=True)),
                ('group', models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name='members', to='bitchat.group')),
            ],
            options={
                'unique_together': {('group', 'pubkey')},
            },
        ),
    ]
