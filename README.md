# Reach

Talk to the world around you. Reach is a private messenger with a superpower:
it works even without internet — phones find each other over Bluetooth and
talk directly. No phone number, no account; your identity is a key that
lives on your device.

- **Radar** — see people around you, even in airplane mode
- **Chats** — end-to-end encrypted messages, images, voice & video calls
- **Your key** — an 8-digit ID you share; no phone number ever

## Monorepo

```
mobile/     Flutter app (Android, iOS planned)
backend/    Django REST + WebSocket signaling (Render)
```

## Run

```bash
# app
cd mobile && flutter pub get && flutter run

# backend
cd backend && python -m venv venv && venv\Scripts\activate
pip install -r requirements.txt && cp .env.example .env
python manage.py migrate && python manage.py runserver
```

## Release build (Android)

Signing expects `mobile/android/key.properties` + `upload-keystore.jks`
(never committed — see `.gitignore`). Then:

```bash
cd mobile && flutter build appbundle --release
```

## Architecture

- **Nearby**: BLE + Nearby Connections — discovery, messages, images, no infrastructure
- **Apart**: server relays E2E-encrypted payloads (NIP-44), WebRTC calls with TURN fallback
- **Server sees**: ciphertext, short IDs, push tokens. Never plaintext.
