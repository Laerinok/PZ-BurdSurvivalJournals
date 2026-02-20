/**
 * Burd's Survival Journals - GitHub OAuth Proxy
 * Cloudflare Worker for securely exchanging OAuth codes for tokens
 *
 * Environment Variables (set via wrangler secret):
 * - GITHUB_CLIENT_ID
 * - GITHUB_CLIENT_SECRET
 * - ALLOWED_ORIGINS (comma-separated exact origins)
 */

const GITHUB_OAUTH_URL = 'https://github.com/login/oauth/access_token';

function parseAllowedOrigins(env) {
    return (env?.ALLOWED_ORIGINS || 'https://theburd.github.io')
        .split(',')
        .map(o => o.trim())
        .filter(Boolean);
}

function isOriginAllowed(origin, env) {
    if (!origin) return false;
    const allowedOrigins = parseAllowedOrigins(env);
    return allowedOrigins.includes(origin);
}

function getCorsHeaders(origin, env, allowed) {
    const headers = {
        'Access-Control-Allow-Methods': 'POST, GET, OPTIONS',
        'Access-Control-Allow-Headers': 'Content-Type',
        'Access-Control-Max-Age': '86400',
        Vary: 'Origin'
    };

    if (allowed) {
        headers['Access-Control-Allow-Origin'] = origin;
    }

    return headers;
}

function jsonResponse(payload, status, origin, env, allowedOrigin) {
    return new Response(JSON.stringify(payload), {
        status,
        headers: {
            ...getCorsHeaders(origin, env, allowedOrigin),
            'Content-Type': 'application/json'
        }
    });
}

function errorResponse(code, message, status, origin, env, allowedOrigin) {
    return jsonResponse({
        error: {
            code,
            message
        }
    }, status, origin, env, allowedOrigin);
}

async function parseJsonBody(request) {
    try {
        const body = await request.json();
        if (!body || typeof body !== 'object' || Array.isArray(body)) {
            return { ok: false, error: 'Body must be a JSON object' };
        }
        return { ok: true, body };
    } catch (e) {
        return { ok: false, error: 'Invalid JSON body' };
    }
}

function validateTokenRequest(body, origin) {
    if (typeof body.code !== 'string' || !body.code.trim()) {
        return 'Missing code parameter';
    }

    if (typeof body.state !== 'string' || !/^[a-f0-9]{32}$/i.test(body.state)) {
        return 'Missing or invalid state parameter';
    }

    if (body.callbackOrigin !== undefined) {
        if (typeof body.callbackOrigin !== 'string' || !body.callbackOrigin.trim()) {
            return 'Invalid callbackOrigin parameter';
        }
        if (origin && body.callbackOrigin !== origin) {
            return 'callbackOrigin does not match request Origin';
        }
    }

    return null;
}

function validateRevokeRequest(body) {
    if (typeof body.token !== 'string' || body.token.trim().length < 10) {
        return 'Missing or invalid token parameter';
    }
    return null;
}

/**
 * Build GitHub app authorization headers
 * @param {Object} env - Worker environment
 * @returns {Object} Headers
 */
function getGitHubAppHeaders(env) {
    return {
        Accept: 'application/vnd.github+json',
        Authorization: 'Basic ' + btoa(`${env.GITHUB_CLIENT_ID}:${env.GITHUB_CLIENT_SECRET}`),
        'X-GitHub-Api-Version': '2022-11-28'
    };
}

/**
 * Revoke OAuth authorization on GitHub
 * @param {string} accessToken - OAuth access token
 * @param {Object} env - Worker environment
 * @returns {Promise<Object>} Revoke result
 */
async function revokeGitHubAuthorization(accessToken, env) {
    const headers = getGitHubAppHeaders(env);
    const baseUrl = `https://api.github.com/applications/${env.GITHUB_CLIENT_ID}`;
    const body = JSON.stringify({ access_token: accessToken });

    try {
        const grantResponse = await fetch(`${baseUrl}/grant`, {
            method: 'DELETE',
            headers,
            body
        });

        if (grantResponse.status === 204 || grantResponse.status === 404) {
            return { success: true, endpoint: 'grant', status: grantResponse.status };
        }
    } catch (e) {
        // Fall through to token revoke attempt.
    }

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

function assertOriginAllowed(origin, env) {
    const allowed = isOriginAllowed(origin, env);
    if (!allowed) {
        return {
            ok: false,
            response: errorResponse(
                'forbidden_origin',
                'Origin is not allowed',
                403,
                origin,
                env,
                false
            )
        };
    }
    return { ok: true };
}

export default {
    async fetch(request, env) {
        const url = new URL(request.url);
        const origin = request.headers.get('Origin');

        if (request.method === 'OPTIONS') {
            const originResult = assertOriginAllowed(origin, env);
            if (!originResult.ok) {
                return originResult.response;
            }
            return new Response(null, {
                status: 204,
                headers: getCorsHeaders(origin, env, true)
            });
        }

        if (url.pathname === '/health') {
            return jsonResponse({
                status: 'ok',
                timestamp: new Date().toISOString()
            }, 200, origin, env, isOriginAllowed(origin, env));
        }

        if (url.pathname === '/token' && request.method === 'POST') {
            const originResult = assertOriginAllowed(origin, env);
            if (!originResult.ok) return originResult.response;

            const parsed = await parseJsonBody(request);
            if (!parsed.ok) {
                return errorResponse('invalid_request', parsed.error, 400, origin, env, true);
            }

            const tokenRequestError = validateTokenRequest(parsed.body, origin);
            if (tokenRequestError) {
                return errorResponse('invalid_request', tokenRequestError, 400, origin, env, true);
            }

            try {
                const tokenResponse = await fetch(GITHUB_OAUTH_URL, {
                    method: 'POST',
                    headers: {
                        Accept: 'application/json',
                        'Content-Type': 'application/json'
                    },
                    body: JSON.stringify({
                        client_id: env.GITHUB_CLIENT_ID,
                        client_secret: env.GITHUB_CLIENT_SECRET,
                        code: parsed.body.code
                    })
                });

                const tokenData = await tokenResponse.json();
                return jsonResponse(
                    tokenData,
                    tokenResponse.ok ? 200 : 400,
                    origin,
                    env,
                    true
                );
            } catch (error) {
                return errorResponse('upstream_error', error.message, 500, origin, env, true);
            }
        }

        if (url.pathname === '/revoke' && request.method === 'POST') {
            const originResult = assertOriginAllowed(origin, env);
            if (!originResult.ok) return originResult.response;

            const parsed = await parseJsonBody(request);
            if (!parsed.ok) {
                return errorResponse('invalid_request', parsed.error, 400, origin, env, true);
            }

            const revokeRequestError = validateRevokeRequest(parsed.body);
            if (revokeRequestError) {
                return errorResponse('invalid_request', revokeRequestError, 400, origin, env, true);
            }

            try {
                const revokeResult = await revokeGitHubAuthorization(parsed.body.token, env);
                if (revokeResult.success) {
                    return jsonResponse({ success: true }, 200, origin, env, true);
                }
                return errorResponse(
                    'revoke_failed',
                    `Failed to revoke authorization (status: ${revokeResult.status || 'unknown'})`,
                    revokeResult.status || 500,
                    origin,
                    env,
                    true
                );
            } catch (error) {
                return errorResponse('internal_error', error.message, 500, origin, env, true);
            }
        }

        return errorResponse('not_found', 'Not found', 404, origin, env, isOriginAllowed(origin, env));
    }
};
