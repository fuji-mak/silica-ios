## Silica API

Cloudflare Worker backend for Silica. The checked-in configuration uses local placeholders. Configure your own Worker route, D1 database, and Notion integration before deployment. All API paths below are relative to `/api/silica`.

The Worker keeps Notion OAuth client credentials, encrypted installation secrets, encrypted Notion access tokens, and the Discord webhook URL on the server. They must never be shipped in the iOS app or the portfolio frontend.

### Endpoints

| Method | Path | Purpose |
| --- | --- | --- |
| POST | `/session/bootstrap` | Issue a per-installation signing identity |
| POST | `/notion/authorize` | Create a short-lived Notion OAuth URL |
| GET | `/notion/callback` | Exchange the OAuth code and stage an encrypted, inactive connection |
| POST | `/notion/complete` | Activate the connection with the returning app's one-time proof |
| GET | `/notion/status` | Return connection metadata, never the token |
| POST | `/notion/search` | List pages/data sources granted to the connection |
| POST | `/notion/sync` | Create a Markdown page or replace an existing page |
| DELETE | `/notion/disconnect` | Delete the stored Notion connection |
| POST | `/feedback` | Send a validated bug/feature/question report to Discord |
| GET | `/health` | Health check; does not touch D1 or third parties |

### Request signing

The app first calls `POST /session/bootstrap` over HTTPS and stores the returned secret in the iOS Keychain. Every later request uses:

```text
X-Silica-Installation: si_...
X-Silica-Timestamp: unix seconds
X-Silica-Nonce: random base64url value
X-Silica-Signature: base64url(HMAC-SHA256(secret, timestamp + "\n" + nonce + "\n" + method + "\n" + path + "\n" + body))
```

Requests older than five minutes and reused nonces are rejected. The signing secret is encrypted at rest in D1. The API does not use a shared secret embedded in the app.

### Notion flow

1. The app requests an authorization URL from `POST /notion/authorize` with `completionMode: "app"` and its allowed callback URL.
2. The app opens that URL in the browser.
3. Notion redirects to `/notion/callback`.
4. The Worker consumes the OAuth state exactly once, exchanges the code server-side, and stages the encrypted access token in D1. It is not usable yet, and any existing connection stays unchanged.
5. The browser returns to the app with `notion=pending` and a random `completionToken`. Only its hash is stored; it expires after ten minutes and is not exposed by status or other API responses.
6. The app posts that token to `/notion/complete`, signed with the same installation identity that started the flow. The Worker atomically activates the connection and consumes the proof. A different installation, an expired proof, or a reused proof is rejected.
7. The app uses `/notion/search` to let the user choose a parent page or data source, then calls `/notion/sync` with the destination and the selected date.

Forwarding an authorization URL to another user must not grant the sender access to that user's Notion pages: the sender has the installation secret but not the returned proof, while the recipient has the proof but not the sender's secret. Do not restore immediate activation in the callback or expose pending proofs through a polling API.

### Updating an existing deployment

Apply migration `0002_notion_pending_connections.sql` before deploying this Worker, and release the matching iOS completion handler. The server rejects new authorization requests from old apps with `426 notion_app_update_required`; this is intentional and must not fall back to the old flow. Existing connections continue to work. During rollout, old app versions cannot create or reconnect a Notion connection until updated. No existing connections are deleted by the migration.

Local tests require Node.js 24 and use an in-memory SQLite database with synthetic Notion responses; they never access production.

The sync title is the selected date in `YYYY-MM-DD` format. Under a page, the Worker searches direct child pages with that title; under a data source, it queries the title property. The first sync creates the dated page and later syncs replace its Markdown content, so repeating a sync for the same day updates the existing Notion page instead of creating a duplicate.

The sync implementation uses Notion API version `2026-03-11` and the enhanced Markdown endpoints. Updates use `replace_content` with `allow_deleting_content: false`, so child pages/databases are protected by default.

For an existing page, the Worker sends this shape to `PATCH /v1/pages/{page_id}/markdown`:

```json
{
  "type": "replace_content",
  "replace_content": {
    "new_str": "# Today",
    "allow_deleting_content": false
  }
}
```

The frontmatter used by the Markdown file exporter is removed for Notion because Notion renders `---` as a divider and does not treat this frontmatter as page properties. The selected date is written to the Notion page title instead.

### Discord safety

`POST /feedback` only accepts the three supported categories and bounded text fields. It does not accept arbitrary JSON or location history. It rate-limits both installation and source IP, neutralizes `@` mentions, and sends `allowed_mentions: { parse: [] }`. The webhook URL is validated to be a Discord webhook host and remains a Worker secret.

### Local setup

1. Create a D1 database and replace `database_id` in `wrangler.jsonc`:

   ```sh
   npx wrangler d1 create silica-api
   ```

2. Copy `.dev.vars.example` to `.dev.vars` and fill in the secrets. Generate `TOKEN_ENCRYPTION_KEY` as a 32-byte base64url value. Do not commit `.dev.vars`.

   `ALLOWED_ORIGINS` should contain the local portfolio origins used during development. Production uses the `ALLOWED_ORIGINS` value in `wrangler.jsonc`.

3. Apply the local schema and run tests:

   ```sh
   npm install
   npm run db:local
   npm test
   ```

4. Configure the Notion public connection with this exact redirect URI:

   `http://localhost:8787/api/silica/notion/callback` for local development, or your deployed HTTPS origin followed by `/api/silica/notion/callback`.

5. Add production secrets and migrate the remote D1 database:

   ```sh
   npx wrangler secret put NOTION_CLIENT_SECRET
   npx wrangler secret put TOKEN_ENCRYPTION_KEY
   npx wrangler secret put DISCORD_WEBHOOK_URL
   npm run db:remote
   npm run deploy
   ```

Replace the placeholder D1 ID and configure your own Worker route before deployment. Never commit real secrets.
