# Generating `identify_token`

`identify_token` is how a **logged-in** visitor's real identity gets attached
to a chat, instead of an anonymous guest. It's a JWT that proves to the
Connectly backend "this really is user X" - and the only thing that can make
that proof trustworthy is that **your backend**, which already knows who's
logged in, signs it with a secret only your backend and Connectly know.

**It must be generated server-side, never on-device.** If you could mint this
token from the Flutter app itself, so could anyone else - the entire point is
that the app can't vouch for a user's identity, only your backend can.

## The flow

1. User logs into your app as normal (your own auth, unrelated to Connectly).
2. Your app calls **your own backend** (e.g. `GET /api/chat-token`), authenticated
   the same way the rest of your API is (session cookie, bearer token, whatever
   you already use).
3. Your backend mints a short-lived JWT and returns it.
4. Your app passes that JWT to the widget:

   ```dart
   ConnectlyChatWidget(identifyToken: tokenFromYourBackend)
   ```

Fetch a fresh token each time you open the chat - don't cache it long-term,
since it's meant to be short-lived (see below).

## Payload

| Claim | Required | Purpose |
|---|---|---|
| `user_id` | **Yes** | Becomes `Chat Visitor.external_user_id` on the Connectly side |
| `exp` | **Yes** | Unix timestamp expiry. The server rejects tokens without one - keep it short, e.g. 5 minutes |
| `name` | No | Populates the visitor's display name (shown to the human agent) |
| `email` | No | Populates the visitor's email |
| `phone` | No | Populates the visitor's phone |

Signed with **HS256**, using the `Chatting App`'s `secret_key` (from the
Connectly Desk - ask whoever administers your Connectly workspace for it; it
should never be shared over anything other than a secure channel, and never
committed to a repo or shipped in the Flutter app itself).

## Server-side examples

### Node.js (`jsonwebtoken`)

```js
const jwt = require("jsonwebtoken");

app.get("/api/chat-token", requireLogin, (req, res) => {
  const token = jwt.sign(
    {
      user_id: req.user.id,
      name: req.user.name,
      email: req.user.email,
    },
    process.env.CONNECTLY_SECRET_KEY,
    { algorithm: "HS256", expiresIn: "5m" }
  );
  res.json({ identify_token: token });
});
```

### Python (`PyJWT`)

```python
import time, jwt

@app.get("/api/chat-token")
def chat_token(current_user=Depends(require_login)):
    payload = {
        "user_id": current_user.id,
        "name": current_user.name,
        "email": current_user.email,
        "exp": int(time.time()) + 300,
    }
    token = jwt.encode(payload, CONNECTLY_SECRET_KEY, algorithm="HS256")
    return {"identify_token": token}
```

### PHP (`firebase/php-jwt`)

```php
use Firebase\JWT\JWT;

$payload = [
    "user_id" => $user->id,
    "name" => $user->name,
    "email" => $user->email,
    "exp" => time() + 300,
];
echo json_encode(["identify_token" => JWT::encode($payload, $_ENV["CONNECTLY_SECRET_KEY"], "HS256")]);
```

## Fetching it from the Flutter app

```dart
Future<String> fetchIdentifyToken() async {
  final response = await http.get(
    Uri.parse('https://your-backend.com/api/chat-token'),
    headers: {'Authorization': 'Bearer $yourAppAuthToken'},
  );
  final body = jsonDecode(response.body) as Map<String, dynamic>;
  return body['identify_token'] as String;
}

// then:
final token = await fetchIdentifyToken();
ConnectlyChatWidget(identifyToken: token);
```

## Common mistakes

- **Generating the token on-device** (or hardcoding one) - defeats the entire
  point; it must come from a call to your own authenticated backend.
- **Omitting `exp`** - the server now rejects tokens without one. A token with
  no expiry, if ever leaked/logged, would be replayable forever.
- **Reusing one token indefinitely** - fetch a fresh one each time the chat
  opens rather than caching it for the app's lifetime.
- **Confusing this with `public_key`** - `public_key` identifies *which app/
  business* is chatting (safe to embed, baked in at build time via
  `ConnectlyChatConfig`); `identify_token` identifies *which user*, is
  per-session, and must never be embedded or hardcoded.
