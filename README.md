# BitChat

Offline-first encrypted messaging using Nostr + BLE mesh, with an optional server comfort layer.

## Monorepo Structure

```
bitchat/
  mobile/     Flutter app (Android + iOS)
  backend/    Django REST API + WebSocket server
```

## Mobile

```bash
cd mobile
flutter pub get
flutter run
```

## Backend

```bash
cd backend
python -m venv venv
source venv/bin/activate      # Windows: venv\Scripts\activate
pip install -r requirements.txt
cp .env.example .env          # fill in secrets
python manage.py migrate
python manage.py runserver
```

## Architecture

- **Transport layer**: BLE mesh (offline) + Nostr relays (online)
- **Server**: comfort layer only — short IDs, push notifications, key backup
- **Encryption**: NIP-44 end-to-end, server never sees plaintext
