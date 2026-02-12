/**
 * Burd's Survival Journals - GitHub OAuth Proxy
 * Cloudflare Worker for securely exchanging OAuth codes for tokens
 *
 * Environment Variables (set via wrangler secret):
 * - GITHUB_CLIENT_ID: Your GitHub OAuth App Client ID
 * - GITHUB_CLIENT_SECRET: Your GitHub OAuth App Client Secret
 * - ALLOWED_ORIGINS: Comma-separated list of allowed origins (e.g., "https://theburd.github.io")
 */

const GITHUB_OAUTH_URL = 'https://github.com/login/oauth/access_token';

/**
 * Build GitHub app authorization headers
 * @param {Object} env - Worker environment
 * @returns {Object} Headers
 */
function getGitHubAppHeaders(env) {
    return {
        'Accept': 'application/vnd.github+json',
        'Authorization': 'Basic ' + btoa(`${env.GITHUB_CLIENT_ID}:${env.GITHUB_CLIENT_SECRET}`),
        'X-GitHub-Api-Version': '2022-11-28'
    };
}

/**
 * Revoke OAuth authorization on GitHub.
 * First tries to delete the app grant (all tokens for this app+user),
 * then falls back to deleting the specific token.
 * @param {string} accessToken - OAuth access token
 * @param {Object} env - Worker environment
 * @returns {Promise<Object>} Revoke result
 */
async function revokeGitHubAuthorization(accessToken, env) {
    const headers = getGitHubAppHeaders(env);
    const baseUrl = `https://api.github.com/applications/${env.GITHUB_CLIENT_ID}`;
    const body = JSON.stringify({ access_token: accessToken });

    // 1) Revoke full grant (preferred)
    try {
        const grantResponse = await fetch(`${baseUrl}/grant`, {
            method: 'DELETE',
            headers,
            body
        });

        // 204 = revoked, 404 = already gone
        if (grantResponse.status === 204 || grantResponse.status === 404) {
            return { success: true, endpoint: 'grant', status: grantResponse.status };
        }
    } catch (e) {
        // Fall through to token revoke attempt
    }

    // 2) Fallback: revoke only the provided token
    const tokenResponse = await fetch(`${baseUrl}/token`, {
        method: 'DELETE',
        headers,
        body
    });

    if (tokenResponse.status === 204 || tokenResponse.status === 404) {
        return { success: true, endpoint: 'token', status: tokenResponse.status };
    }

    return {
        success: false,
        endpoint: 'token',
        status: tokenResponse.status
    };
}

// CORS headers
function getCorsHeaders(origin, env) {
    const allowedOrigins = (env?.ALLOWED_ORIGINS || 'https://theburd.github.io').split(',').map(o => o.trim());

    // Check if origin is allowed
    const isAllowed = allowedOrigins.includes(origin) ||
                      allowedOrigins.includes('*') ||
                      origin?.includes('localhost');

    return {
        'Access-Control-Allow-Origin': isAllowed ? origin : allowedOrigins[0],
        'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
        'Access-Control-Allow-Headers': 'Content-Type',
        'Access-Control-Max-Age': '86400',
    };
}

// Handle CORS preflight
function handleOptions(request, env) {
    const origin = request.headers.get('Origin');
    return new Response(null, {
        status: 204,
        headers: getCorsHeaders(origin, env)
    });
}

// Main handler
export default {
    async fetch(request, env) {
        const url = new URL(request.url);
        const origin = request.headers.get('Origin');
        const corsHeaders = getCorsHeaders(origin, env);

        // Handle CORS preflight
        if (request.method === 'OPTIONS') {
            return handleOptions(request, env);
        }

        // Route: POST /token - Exchange code for access token
        if (url.pathname === '/token' && request.method === 'POST') {
            try {
                const body = await request.json();
                const { code, state } = body;

                if (!code) {
                    return new Response(JSON.stringify({ error: 'Missing code parameter' }), {
                        status: 400,
                        headers: { ...corsHeaders, 'Content-Type': 'application/json' }
                    });
                }

                // Exchange code for token with GitHub
                const tokenResponse = await fetch(GITHUB_OAUTH_URL, {
                    method: 'POST',
                    headers: {
                        'Accept': 'application/json',
                        'Content-Type': 'application/json'
                    },
                    body: JSON.stringify({
                        client_id: env.GITHUB_CLIENT_ID,
                        client_secret: env.GITHUB_CLIENT_SECRET,
                        code: code
                    })
                });

                const tokenData = await tokenResponse.json();

                // Return token to client
                return new Response(JSON.stringify(tokenData), {
                    status: tokenResponse.ok ? 200 : 400,
                    headers: { ...corsHeaders, 'Content-Type': 'application/json' }
                });
            } catch (error) {
                return new Response(JSON.stringify({ error: error.message }), {
                    status: 500,
                    headers: { ...corsHeaders, 'Content-Type': 'application/json' }
                });
            }
        }

        // Route: POST /revoke - Revoke an access token
        if (url.pathname === '/revoke' && request.method === 'POST') {
            try {
                const body = await request.json();
                const { token } = body;

                if (!token) {
                    return new Response(JSON.stringify({ error: 'Missing token parameter' }), {
                        status: 400,
                        headers: { ...corsHeaders, 'Content-Type': 'application/json' }
                    });
                }

                const revokeResult = await revokeGitHubAuthorization(token, env);

                if (revokeResult.success) {
                    return new Response(JSON.stringify({ success: true }), {
                        status: 200,
                        headers: { ...corsHeaders, 'Content-Type': 'application/json' }
                    });
                }

                return new Response(JSON.stringify({
                    error: 'Failed to revoke authorization',
                    status: revokeResult.status,
                    endpoint: revokeResult.endpoint
                }), {
                    status: revokeResult.status || 500,
                    headers: { ...corsHeaders, 'Content-Type': 'application/json' }
                });
            } catch (error) {
                return new Response(JSON.stringify({ error: error.message }), {
                    status: 500,
                    headers: { ...corsHeaders, 'Content-Type': 'application/json' }
                });
            }
        }

        // Route: GET /health - Health check
        if (url.pathname === '/health') {
            return new Response(JSON.stringify({
                status: 'ok',
                timestamp: new Date().toISOString()
            }), {
                headers: { ...corsHeaders, 'Content-Type': 'application/json' }
            });
        }

        // 404 for unknown routes
        return new Response(JSON.stringify({ error: 'Not found' }), {
            status: 404,
            headers: { ...corsHeaders, 'Content-Type': 'application/json' }
        });
    }
};
