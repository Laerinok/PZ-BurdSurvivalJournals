# Burd's Survival Journals - OAuth Proxy

This Cloudflare Worker handles GitHub OAuth token exchange for the translation tool.

## Setup Instructions

### 1. Create a GitHub OAuth App

1. Go to [GitHub Developer Settings](https://github.com/settings/developers)
2. Click "New OAuth App"
3. Fill in:
   - **Application name**: `PZ Burd's Survival Journals`
   - **Homepage URL**: `https://theburd.github.io/PZ-BurdSurvivalJournals/`
   - **Authorization callback URL**: `https://theburd.github.io/PZ-BurdSurvivalJournals/docs/`
4. Click "Register application"
5. Note the **Client ID**
6. Click "Generate a new client secret" and note the **Client Secret**

> **Note**: The callback URL points directly to your app. GitHub redirects users there with the OAuth code, then your app sends the code to this worker to exchange for a token.

### 2. Deploy the Cloudflare Worker

1. Install Wrangler CLI:
   ```bash
   npm install -g wrangler
   ```

2. Login to Cloudflare:
   ```bash
   wrangler login
   ```

3. Navigate to this directory:
   ```bash
   cd docs/cloudflare-worker
   ```

4. Set your secrets:
   ```bash
   wrangler secret put GITHUB_CLIENT_ID
   # Enter your Client ID when prompted

   wrangler secret put GITHUB_CLIENT_SECRET
   # Enter your Client Secret when prompted
   ```

5. Deploy:
   ```bash
   wrangler deploy
   ```

6. Note the worker URL (e.g., `https://bsj-oauth.YOUR_SUBDOMAIN.workers.dev`)

### 3. Update the Translation Tool

1. Open `docs/js/config.js`
2. Update `OAUTH_CONFIG`:
   ```javascript
   export const OAUTH_CONFIG = {
       clientId: 'YOUR_GITHUB_CLIENT_ID',
       workerUrl: 'https://bsj-oauth.YOUR_SUBDOMAIN.workers.dev',
       scopes: ['public_repo']
   };
   ```

### 4. Update GitHub OAuth App Callback URL

1. Go back to your GitHub OAuth App settings
2. Ensure the **Authorization callback URL** points to your translation tool page (not the worker):
   `https://theburd.github.io/PZ-BurdSurvivalJournals/docs/`

> The app receives `code/state` at the docs URL, then exchanges the code with the worker via `POST /token`.

## Testing

### Health Check
```bash
curl https://bsj-oauth.YOUR_SUBDOMAIN.workers.dev/health
```

### Local Development
```bash
wrangler dev
```
This starts a local server at `http://localhost:8787` for testing.

## Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/token` | POST | Exchange OAuth code for access token |
| `/revoke` | POST | Revoke OAuth authorization/token |
| `/health` | GET | Health check |

## Security Notes

- The `GITHUB_CLIENT_SECRET` is stored securely in Cloudflare's environment
- CORS is configured with exact-origin allowlisting from `ALLOWED_ORIGINS`
- `/token` and `/revoke` validate JSON request shape and reject malformed bodies
- OAuth callback `state` is required and validated for format before token exchange
- The worker never logs or exposes the client secret
