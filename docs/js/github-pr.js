/**
 * GitHub Pull Request Creation
 * Handles forking, branching, committing, and PR creation
 */

import { REPO_CONFIG, CATEGORIES } from './config.js';
import { getGitHubToken, isGitHubAuthenticated, getGitHubUser } from './github-auth.js';
import { generateCategoryFile } from './export-utils.js';
import { getEnglishBaseline, getOriginalRepoTranslations } from './translation-manager.js';
import { categorizeTranslations, escapeLuaString } from './lua-parser.js';

const GITHUB_API = 'https://api.github.com';

/**
 * Make authenticated GitHub API request
 * @param {string} endpoint - API endpoint (relative to base)
 * @param {Object} options - Fetch options
 * @returns {Promise<Object>} Response data
 */
async function githubRequest(endpoint, options = {}) {
    const token = getGitHubToken();
    if (!token) {
        throw new Error('Not authenticated with GitHub');
    }

    const url = endpoint.startsWith('http') ? endpoint : `${GITHUB_API}${endpoint}`;

    const response = await fetch(url, {
        ...options,
        headers: {
            'Authorization': `Bearer ${token}`,
            'Accept': 'application/vnd.github.v3+json',
            'Content-Type': 'application/json',
            ...options.headers
        }
    });

    if (!response.ok) {
        const error = await response.json().catch(() => ({}));
        throw new Error(error.message || `GitHub API error: ${response.status}`);
    }

    // Handle empty responses
    const text = await response.text();
    return text ? JSON.parse(text) : {};
}

/**
 * Check if user has a fork of the repo
 * @param {string} username - GitHub username
 * @returns {Promise<Object|null>} Fork info or null
 */
export async function getUserFork(username) {
    try {
        const repo = await githubRequest(`/repos/${username}/${REPO_CONFIG.repo}`);
        if (repo.fork && repo.parent?.full_name === `${REPO_CONFIG.owner}/${REPO_CONFIG.repo}`) {
            return repo;
        }
    } catch (e) {
        // Fork doesn't exist
    }
    return null;
}

/**
 * Create a fork of the main repo
 * @returns {Promise<Object>} Fork info
 */
export async function createFork() {
    const fork = await githubRequest(`/repos/${REPO_CONFIG.owner}/${REPO_CONFIG.repo}/forks`, {
        method: 'POST'
    });

    // Wait for fork to be ready (GitHub creates forks asynchronously)
    let attempts = 0;
    while (attempts < 10) {
        await new Promise(resolve => setTimeout(resolve, 2000));
        try {
            await githubRequest(`/repos/${fork.full_name}`);
            return fork;
        } catch (e) {
            attempts++;
        }
    }

    return fork;
}

/**
 * Get or create user's fork
 * @param {string} username - GitHub username
 * @returns {Promise<Object>} Fork info
 */
export async function getOrCreateFork(username) {
    const existing = await getUserFork(username);
    if (existing) {
        return existing;
    }
    return await createFork();
}

/**
 * Get the default branch's latest commit SHA
 * @param {string} owner - Repo owner
 * @param {string} repo - Repo name
 * @returns {Promise<string>} Commit SHA
 */
async function getLatestCommitSha(owner, repo) {
    const ref = await githubRequest(`/repos/${owner}/${repo}/git/ref/heads/${REPO_CONFIG.branch}`);
    return ref.object.sha;
}

/**
 * Create a new branch
 * @param {string} owner - Repo owner (user's fork)
 * @param {string} repo - Repo name
 * @param {string} branchName - New branch name
 * @param {string} baseSha - Base commit SHA
 * @returns {Promise<Object>} Branch ref
 */
async function createBranch(owner, repo, branchName, baseSha) {
    return await githubRequest(`/repos/${owner}/${repo}/git/refs`, {
        method: 'POST',
        body: JSON.stringify({
            ref: `refs/heads/${branchName}`,
            sha: baseSha
        })
    });
}

/**
 * Create or update a file in the repo
 * @param {string} owner - Repo owner
 * @param {string} repo - Repo name
 * @param {string} path - File path
 * @param {string} content - File content
 * @param {string} message - Commit message
 * @param {string} branch - Branch name
 * @param {string} existingSha - SHA of existing file (for updates)
 * @returns {Promise<Object>} Commit info
 */
async function createOrUpdateFile(owner, repo, path, content, message, branch, existingSha = null) {
    const body = {
        message,
        content: btoa(unescape(encodeURIComponent(content))), // Base64 encode with UTF-8 support
        branch
    };

    if (existingSha) {
        body.sha = existingSha;
    }

    return await githubRequest(`/repos/${owner}/${repo}/contents/${path}`, {
        method: 'PUT',
        body: JSON.stringify(body)
    });
}

/**
 * Get file info (to get SHA for updates)
 * @param {string} owner - Repo owner
 * @param {string} repo - Repo name
 * @param {string} path - File path
 * @param {string} branch - Branch name
 * @returns {Promise<Object|null>} File info or null
 */
async function getFileInfo(owner, repo, path, branch) {
    try {
        return await githubRequest(`/repos/${owner}/${repo}/contents/${path}?ref=${branch}`);
    } catch (e) {
        return null;
    }
}

/**
 * Decode file content from GitHub Contents API response
 * @param {Object} fileInfo - File info from contents API
 * @returns {string} Decoded UTF-8 content
 */
function decodeGitHubFileContent(fileInfo) {
    if (!fileInfo?.content || fileInfo.encoding !== 'base64') {
        return '';
    }

    try {
        // GitHub inserts line breaks in base64 payloads
        const normalized = fileInfo.content.replace(/\n/g, '');
        return decodeURIComponent(escape(atob(normalized)));
    } catch (e) {
        console.warn('Failed to decode GitHub file content:', e);
        return '';
    }
}

/**
 * Apply translation updates to an existing Lua file while preserving untouched lines
 * @param {string} existingContent - Existing Lua file content
 * @param {Object} updates - Changed translations to apply
 * @returns {Object} Result with updated content, changed flag, and applied keys
 */
function applyUpdatesToExistingLuaFile(existingContent, updates) {
    if (!existingContent || !updates || Object.keys(updates).length === 0) {
        return {
            content: existingContent || '',
            changed: false,
            appliedKeys: new Set()
        };
    }

    const lines = existingContent.replace(/\r\n/g, '\n').split('\n');
    const appliedKeys = new Set();
    let changed = false;

    // Conservative single-line key matcher:
    //   key = "value",
    //   key = "value", -- comment
    const kvRegex = /^(\s*)([\w.]+)(\s*=\s*)"((?:[^"\\]|\\.)*)"(,?\s*(?:--.*)?)$/;

    for (let i = 0; i < lines.length; i++) {
        const line = lines[i];
        const match = line.match(kvRegex);
        if (!match) continue;

        const key = match[2];
        if (!(key in updates)) continue;

        const nextValue = updates[key];
        if (!nextValue || !nextValue.trim()) continue;

        const escaped = escapeLuaString(nextValue);
        const rebuilt = `${match[1]}${key}${match[3]}"${escaped}"${match[5]}`;

        if (rebuilt !== line) {
            lines[i] = rebuilt;
            changed = true;
        }

        appliedKeys.add(key);
    }

    return {
        content: lines.join('\n'),
        changed,
        appliedKeys
    };
}

/**
 * Create a pull request
 * @param {Object} options - PR options
 * @returns {Promise<Object>} PR info
 */
async function createPullRequest({ title, body, head, base }) {
    return await githubRequest(`/repos/${REPO_CONFIG.owner}/${REPO_CONFIG.repo}/pulls`, {
        method: 'POST',
        body: JSON.stringify({
            title,
            body,
            head,
            base,
            maintainer_can_modify: true
        })
    });
}

/**
 * Submit translations as a pull request
 * @param {Object} translationsByLang - Object with langCode keys and translations values
 * @param {Object} options - Options object
 * @param {Function} options.onProgress - Progress callback
 * @param {string} options.customTitle - Custom PR title (optional)
 * @param {string} options.customBody - Custom PR body (optional)
 * @param {Object} options.langNames - Map of langCode to display name
 * @param {Object} options.fullTranslationsByLang - Full merged translations (optional, for complete files)
 * @returns {Promise<Object>} Result with PR URL
 */
export async function submitTranslationsPR(translationsByLang, options = {}) {
    const { onProgress = null, customTitle = null, customBody = null, langNames = {}, fullTranslationsByLang = null } = options;
    if (!isGitHubAuthenticated()) {
        throw new Error('Not authenticated with GitHub');
    }

    const languages = Object.keys(translationsByLang);
    if (languages.length === 0) {
        throw new Error('No translations to submit');
    }

    // Get user info
    if (onProgress) onProgress('Getting user info...', 0);
    const user = await getGitHubUser();
    if (!user) {
        throw new Error('Failed to get GitHub user info');
    }

    // Get or create fork
    if (onProgress) onProgress('Checking for fork...', 10);
    const fork = await getOrCreateFork(user.login);

    // Get latest commit from upstream
    if (onProgress) onProgress('Getting latest commit...', 20);
    const baseSha = await getLatestCommitSha(REPO_CONFIG.owner, REPO_CONFIG.repo);

    // Create branch name
    const timestamp = Date.now();
    const langCodes = languages.join('-');
    const branchName = `translation/${langCodes}-${timestamp}`;

    // Create branch in fork
    if (onProgress) onProgress('Creating branch...', 30);
    await createBranch(user.login, REPO_CONFIG.repo, branchName, baseSha);

    // Commit translation files
    const totalFileTargets = languages.length * CATEGORIES.length * 2; // build42 + build41
    let fileTargetsProcessed = 0;
    let filesCommitted = 0;

    for (const langCode of languages) {
        const changedTranslations = translationsByLang[langCode];

        // IMPORTANT: Use full merged translations if provided, otherwise merge with original
        // This ensures we submit COMPLETE files, not just the changed keys
        // The PR should contain the full translation file with changes applied
        let mergedTranslations;
        if (fullTranslationsByLang && fullTranslationsByLang[langCode]) {
            // Use the full translations provided by the caller (includes all repo + edits)
            mergedTranslations = fullTranslationsByLang[langCode];
        } else {
            // Fallback: merge changes with original repo translations
            const originalTranslations = getOriginalRepoTranslations(langCode);
            mergedTranslations = { ...originalTranslations, ...changedTranslations };
        }

        const categorizedMerged = categorizeTranslations(mergedTranslations);

        for (const category of CATEGORIES) {
            const filename = `${category}_${langCode}.txt`;

            // Build 42 path
            const build42Path = `${REPO_CONFIG.translationPaths.build42}/${langCode}/${filename}`;
            if (onProgress) onProgress(`Processing ${filename} (Build 42)...`, 30 + (fileTargetsProcessed / totalFileTargets) * 60);

            // Check if file exists to get SHA
            const existingFile42 = await getFileInfo(user.login, REPO_CONFIG.repo, build42Path, branchName);
            const existingContent42 = decodeGitHubFileContent(existingFile42);

            let outputContent42 = existingContent42;
            let shouldCommit42 = false;

            if (existingFile42 && existingContent42) {
                // Existing file: update only changed keys, preserve untouched entries/comments/formatting.
                const patched = applyUpdatesToExistingLuaFile(existingContent42, changedTranslations);
                outputContent42 = patched.content;
                shouldCommit42 = patched.changed;
            } else {
                // New file: generate full category content from merged translations.
                const categoryTranslations = categorizedMerged[category] || {};
                if (Object.keys(categoryTranslations).length > 0) {
                    outputContent42 = generateCategoryFile(category, langCode, mergedTranslations);
                    shouldCommit42 = true;
                }
            }

            if (shouldCommit42) {
                await createOrUpdateFile(
                    user.login,
                    REPO_CONFIG.repo,
                    build42Path,
                    outputContent42,
                    `Add/Update ${langCode} ${category} translation`,
                    branchName,
                    existingFile42?.sha
                );
                filesCommitted++;
            }
            fileTargetsProcessed++;

            // Build 41 path
            const build41Path = `${REPO_CONFIG.translationPaths.build41}/${langCode}/${filename}`;
            if (onProgress) onProgress(`Processing ${filename} (Build 41)...`, 30 + (fileTargetsProcessed / totalFileTargets) * 60);

            const existingFile41 = await getFileInfo(user.login, REPO_CONFIG.repo, build41Path, branchName);
            const existingContent41 = decodeGitHubFileContent(existingFile41);

            let outputContent41 = existingContent41;
            let shouldCommit41 = false;

            if (existingFile41 && existingContent41) {
                const patched = applyUpdatesToExistingLuaFile(existingContent41, changedTranslations);
                outputContent41 = patched.content;
                shouldCommit41 = patched.changed;
            } else {
                const categoryTranslations = categorizedMerged[category] || {};
                if (Object.keys(categoryTranslations).length > 0) {
                    outputContent41 = generateCategoryFile(category, langCode, mergedTranslations);
                    shouldCommit41 = true;
                }
            }

            if (shouldCommit41) {
                await createOrUpdateFile(
                    user.login,
                    REPO_CONFIG.repo,
                    build41Path,
                    outputContent41,
                    `Add/Update ${langCode} ${category} translation`,
                    branchName,
                    existingFile41?.sha
                );
                filesCommitted++;
            }
            fileTargetsProcessed++;
        }
    }

    if (filesCommitted === 0) {
        throw new Error('No file changes detected to commit (all selected keys already matched repository values).');
    }

    // Create PR
    if (onProgress) onProgress('Creating pull request...', 95);

    const prTitle = customTitle || generatePRTitle(languages, langNames);
    const prBody = customBody || generatePRBody(languages, translationsByLang, langNames);

    const pr = await createPullRequest({
        title: prTitle,
        body: prBody,
        head: `${user.login}:${branchName}`,
        base: REPO_CONFIG.branch
    });

    if (onProgress) onProgress('Done!', 100);

    return {
        success: true,
        prUrl: pr.html_url,
        prNumber: pr.number,
        branchName,
        languages
    };
}

/**
 * Generate PR title
 * @param {string[]} languages - Array of language codes
 * @param {Object} langNames - Optional map of langCode to display name
 * @returns {string} PR title
 */
export function generatePRTitle(languages, langNames = {}) {
    const getDisplayName = (code) => langNames[code] || code;

    if (languages.length === 1) {
        return `Add/Update ${getDisplayName(languages[0])} translation`;
    } else if (languages.length <= 3) {
        return `Add/Update ${languages.map(getDisplayName).join(', ')} translations`;
    } else {
        return `Add/Update translations for ${languages.length} languages`;
    }
}

/**
 * Generate PR body
 * @param {string[]} languages - Array of language codes
 * @param {Object} translationsByLang - Changed translations by language
 * @param {Object} langNames - Optional map of langCode to display name
 * @returns {string} PR body
 */
export function generatePRBody(languages, translationsByLang, langNames = {}) {
    const english = getEnglishBaseline();
    const englishKeyCount = Object.keys(english).length;
    const getDisplayName = (code) => langNames[code] || code;

    let body = `## Translation Submission\n\n`;
    body += `This PR adds/updates translations for the following languages:\n\n`;

    for (const langCode of languages) {
        const changedTranslations = translationsByLang[langCode];
        const changedCount = Object.keys(changedTranslations).length;

        // Get merged count to show total coverage
        const originalTranslations = getOriginalRepoTranslations(langCode);
        const mergedTranslations = { ...originalTranslations, ...changedTranslations };
        const totalCount = Object.keys(mergedTranslations).length;
        const percentage = Math.round((totalCount / englishKeyCount) * 100);

        body += `- **${getDisplayName(langCode)}** (${langCode}): ${changedCount} changed/new keys (${percentage}% total coverage)\n`;
    }

    body += `\n### Changes by Category\n\n`;

    for (const langCode of languages) {
        const changedTranslations = translationsByLang[langCode];
        const categorized = categorizeTranslations(changedTranslations);

        body += `**${getDisplayName(langCode)}:**\n`;
        for (const category of CATEGORIES) {
            const count = Object.keys(categorized[category] || {}).length;
            if (count > 0) {
                body += `- ${category}: ${count} changed/new keys\n`;
            }
        }
        body += `\n`;
    }

    body += `> **Note:** Complete translation files are submitted (existing translations preserved, changes merged in).\n\n`;

    body += `---\n`;
    body += `*Submitted via [Burd's Survival Journals Translation Tool](https://theburd.github.io/PZ-BurdSurvivalJournals/)*\n`;

    return body;
}

/**
 * Check if user can submit PR (has authentication and translations)
 * @param {Object} translationsByLang - Translations to submit
 * @returns {Object} Status info
 */
export function canSubmitPR(translationsByLang) {
    const isAuthenticated = isGitHubAuthenticated();
    const hasTranslations = translationsByLang && Object.keys(translationsByLang).length > 0;
    const hasContent = hasTranslations && Object.values(translationsByLang).some(
        t => Object.keys(t).length > 0
    );

    return {
        canSubmit: isAuthenticated && hasContent,
        isAuthenticated,
        hasTranslations: hasContent,
        reason: !isAuthenticated ? 'Not connected to GitHub' :
            !hasContent ? 'No translations to submit' : null
    };
}
