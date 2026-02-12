/**
 * GitHub OAuth Authentication
 * Handles GitHub OAuth flow via Cloudflare Worker proxy
 */

import { OAUTH_CONFIG } from './config.js';
import { saveGitHubToken, getGitHubToken, clearGitHubToken, isGitHubAuthenticated } from './storage-manager.js';

// State for OAuth flow
let oauthState = null;

/**
 * Generate random state for OAuth security
 * @returns {string} Random state string
 */
function generateState() {
    const array = new Uint8Array(16);
    crypto.getRandomValues(array);
    return Array.from(array, b => b.toString(16).padStart(2, '0')).join('');
}

/**
 * Start GitHub OAuth flow
 * Redirects user to GitHub for authorization
 * @param {Object} options - OAuth flow options
 * @param {boolean} options.forceAccountPicker - Force GitHub account picker
 * @param {string|null} options.loginHint - Optional GitHub username hint
 */
export function startOAuthFlow(options = {}) {
    const { forceAccountPicker = true, loginHint = null } = options;

    // Generate and store state for CSRF protection
    oauthState = generateState();
    sessionStorage.setItem('oauth_state', oauthState);

    // The callback URL is the current page (GitHub redirects back here with code)
    const callbackUrl = window.location.origin + window.location.pathname;

    // Build GitHub authorization URL
    const params = new URLSearchParams({
        client_id: OAUTH_CONFIG.clientId,
        redirect_uri: callbackUrl,
        scope: OAUTH_CONFIG.scopes.join(' '),
        state: oauthState
    });

    // Force account selection so users can switch GitHub accounts
    // without requiring incognito/private browsing.
    if (forceAccountPicker) {
        params.set('prompt', 'select_account');
    }

    if (loginHint && typeof loginHint === 'string' && loginHint.trim()) {
        params.set('login', loginHint.trim());
    }

    const authUrl = `https://github.com/login/oauth/authorize?${params}`;

    // Redirect to GitHub
    window.location.href = authUrl;
}

/**
 * Handle OAuth callback
 * Called when user returns from GitHub authorization
 * @returns {Promise<Object>} Result with success status
 */
export async function handleOAuthCallback() {
    const urlParams = new URLSearchParams(window.location.search);
    const code = urlParams.get('code');
    const state = urlParams.get('state');
    const error = urlParams.get('error');
    const errorDescription = urlParams.get('error_description');

    // Check for errors from GitHub
    if (error) {
        return {
            success: false,
            error: error,
            description: errorDescription || 'Authorization failed'
        };
    }

    // Verify we have a code
    if (!code) {
        return {
            success: false,
            error: 'no_code',
            description: 'No authorization code received'
        };
    }

    // Verify state matches (CSRF protection)
    const savedState = sessionStorage.getItem('oauth_state');
    if (state !== savedState) {
        return {
            success: false,
            error: 'state_mismatch',
            description: 'Security check failed. Please try again.'
        };
    }

    // Exchange code for token via our Cloudflare Worker
    try {
        const response = await fetch(`${OAUTH_CONFIG.workerUrl}/token`, {
            method: 'POST',
            headers: {
                'Content-Type': 'application/json'
            },
            body: JSON.stringify({ code, state })
        });

        if (!response.ok) {
            const errorData = await response.json().catch(() => ({}));
            return {
                success: false,
                error: 'token_exchange_failed',
                description: errorData.error || `HTTP ${response.status}`
            };
        }

        const data = await response.json();

        if (data.access_token) {
            // Save token
            saveGitHubToken(data.access_token);

            // Clean up URL - remove OAuth params
            const cleanUrl = window.location.origin + window.location.pathname;
            window.history.replaceState({}, document.title, cleanUrl);

            // Clean up session storage
            sessionStorage.removeItem('oauth_state');

            return {
                success: true,
                token: data.access_token
            };
        } else {
            return {
                success: false,
                error: 'no_token',
                description: data.error_description || 'No access token in response'
            };
        }
    } catch (error) {
        return {
            success: false,
            error: 'network_error',
            description: error.message
        };
    }
}

/**
 * Check if we're in an OAuth callback
 * @returns {boolean} True if URL has OAuth callback params
 */
export function isOAuthCallback() {
    const urlParams = new URLSearchParams(window.location.search);
    return urlParams.has('code') || urlParams.has('error');
}

/**
 * Get current GitHub authentication status
 * @returns {Object} Auth status
 */
export function getAuthStatus() {
    const token = getGitHubToken();
    return {
        isAuthenticated: !!token,
        hasToken: !!token
    };
}

/**
 * Logout from GitHub
 * Revokes the token on GitHub's side and clears local storage
 * @returns {Promise<boolean>} True if logout was successful
 */
export async function logout() {
    const token = getGitHubToken();

    // Clear local token first
    clearGitHubToken();
    sessionStorage.removeItem('oauth_state');

    // If we had a token, try to revoke it on GitHub's side
    if (token) {
        try {
            await fetch(`${OAUTH_CONFIG.workerUrl}/revoke`, {
                method: 'POST',
                headers: {
                    'Content-Type': 'application/json'
                },
                body: JSON.stringify({ token })
            });
            // We don't really care if this fails - token is already cleared locally
        } catch (e) {
            console.warn('Failed to revoke token on GitHub:', e);
        }
    }

    return true;
}

/**
 * Get GitHub user info
 * @returns {Promise<Object>} User info or null
 */
export async function getGitHubUser() {
    const token = getGitHubToken();
    if (!token) return null;

    try {
        const response = await fetch('https://api.github.com/user', {
            headers: {
                'Authorization': `Bearer ${token}`,
                'Accept': 'application/vnd.github.v3+json'
            }
        });

        if (!response.ok) {
            if (response.status === 401) {
                // Token is invalid, clear it
                clearGitHubToken();
            }
            return null;
        }

        return await response.json();
    } catch (error) {
        console.error('Failed to get GitHub user:', error);
        return null;
    }
}

/**
 * Validate current token
 * @returns {Promise<boolean>} True if token is valid
 */
export async function validateToken() {
    const token = getGitHubToken();
    if (!token) return false;

    try {
        const response = await fetch('https://api.github.com/user', {
            headers: {
                'Authorization': `Bearer ${token}`,
                'Accept': 'application/vnd.github.v3+json'
            }
        });

        if (!response.ok) {
            if (response.status === 401) {
                clearGitHubToken();
            }
            return false;
        }

        return true;
    } catch (error) {
        return false;
    }
}

/**
 * Re-export for convenience
 */
export { isGitHubAuthenticated, getGitHubToken };
