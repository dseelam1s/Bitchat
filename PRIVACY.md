# Reach — Privacy Policy

_Last updated: July 14, 2026_

Reach is a private messenger. This policy explains what we collect, what we
don't, and the permissions the app uses.

## What we DON'T collect
- **No phone number, no email, no name required.** Your identity is a
  cryptographic key generated on your device.
- **No message content.** Messages are end-to-end encrypted (NIP-44).
  Our server relays and temporarily stores only ciphertext it cannot read.
- **No location tracking.** The app never reads GPS position. The location
  permission exists only because Android requires it for Bluetooth scanning;
  no location data is ever collected or transmitted.
- No ads, no trackers, no analytics SDKs, no sale of data.

## What the server stores
- Your public key and 8-digit short ID, and a display name **if you choose
  to set one**.
- Encrypted (unreadable) messages awaiting delivery — deleted after delivery
  or 7 days.
- A push-notification token (Firebase Cloud Messaging) so your phone rings.
- If you upload a profile photo, it is stored with our media provider
  (Cloudinary) and is visible to people you talk to.
- Optional encrypted backups (keys, contacts) — encrypted on your device
  with your password before upload; we cannot read them.

## Permissions the app requests
- **Bluetooth / Nearby devices** — finding people around you and offline
  messaging. Radio only; works with zero internet.
- **Location** — required by Android for Bluetooth scanning; never used
  for location.
- **Camera / Photos** — profile pictures and photo messages you choose to send.
- **Microphone** — voice and video calls.
- **Notifications** — incoming messages and calls.

## Calls
Voice/video calls are peer-to-peer (WebRTC) and encrypted. When a direct
connection isn't possible, encrypted call traffic is relayed through a TURN
server (Metered) that cannot decrypt it.

## Visibility
The "Visible to others" switch controls whether people can find you by
search or see you on their radar. Turn it off and only your existing
contacts can reach you.

## Data deletion
Uninstalling the app deletes your keys and local data. Server-side data
(short ID, pending ciphertext, push token) becomes orphaned and is removed
in routine cleanup. For explicit deletion requests contact us.

## Contact
durgareddyseelam09@gmail.com
