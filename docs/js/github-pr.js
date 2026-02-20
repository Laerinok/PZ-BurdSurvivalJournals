/**
 * GitHub Pull Request Creation
 * Handles forking, branching, committing, and PR creation
 */

import { REPO_CONFIG, CATEGORIES } from './config.js';
import { getGitHubToken, isGitHubAuthenticated, getGitHubUser } from './github-auth.js';
import { generateCategoryFile } from './export-utils.js';
import { getEnglishBaseline, getOriginalRepoTranslations } from './translation-manager.js';
import { categorizeTranslations } from './lua-parser.js';

const GITHUB_API = 'https://api.github.com';

function encodeBase64Utf8(content) {
    return btoa(unescape(encodeURIComponent(content)));
}

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
            Authorization: `Bearer ${token}`,
            Accept: 'application/vnd.github.v3+json',
            'Content-Type': 'application/json',
            ...options.headers
        }
    });

    if (!response.ok) {
        const error = await response.json().catch(() => ({}));
        throw new Error(error.message || `GitHub API error: ${response.status}`);
    }

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

    // Wait for fork readiness
    let attempts = 0;
    while (attempts < 12) {
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
    if (existing) return existing;
    return await createFork();
}

/**
 * Get the default branch latest commit SHA
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
 * @param {string} owner - Repo owner
 * @param {string} repo - Repo name
 * @param {string} branchName - Branch name
 * @param {string} baseSha - Base SHA
 * @returns {Promise<Object>} Created ref
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
 * @param {string|null} existingSha - Existing file SHA (for updates)
 * @returns {Promise<Object>} Commit result
 */
async function createOrUpdateFile(owner, repo, path, content, message, branch, existingSha = null) {
    const body = {
        message,
        content: encodeBase64Utf8(content),
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
 * Get file info from GitHub Contents API
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
 * @param {Object} fileInfo - File info
 * @returns {string} Decoded content
 */
function decodeGitHubFileContent(fileInfo) {
    if (!fileInfo?.content || fileInfo.encoding !== 'base64') {
        return '';
    }

    try {
        const normalized = fileInfo.content.replace(/\n/g, '');
        return decodeURIComponent(escape(atob(normalized)));
    } catch (e) {
        console.warn('Failed to decode GitHub file content:', e);
        return '';
    }
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

function buildMergedTranslations(changedTranslations, fullTranslationsByLang, langCode) {
    if (fullTranslationsByLang?.[langCode]) {
        return fullTranslationsByLang[langCode];
    }

    const original = getOriginalRepoTranslations(langCode);
    return { ...original, ...changedTranslations };
}

/**
 * Submit translations as a pull request
 * @param {Object} translationsByLang - Changed translations keyed by language
 * @param {Object} options - Submission options
 * @returns {Promise<Object>} Submission result
 */
export async function submitTranslationsPR(translationsByLang, options = {}) {
    const {
        onProgress = null,
        customTitle = null,
        customBody = null,
        langNames = {},
        fullTranslationsByLang = null
    } = options;

    if (!isGitHubAuthenticated()) {
        throw new Error('Not authenticated with GitHub');
    }

    const languages = Object.keys(translationsByLang);
    if (languages.length === 0) {
        throw new Error('No translations to submit');
    }

    if (onProgress) onProgress('Getting user info...', 0);
    const user = await getGitHubUser();
    if (!user) {
        throw new Error('Failed to get GitHub user info');
    }

    if (onProgress) onProgress('Checking for fork...', 10);
    await getOrCreateFork(user.login);

    if (onProgress) onProgress('Getting latest commit...', 20);
    const baseSha = await getLatestCommitSha(REPO_CONFIG.owner, REPO_CONFIG.repo);

    const branchName = `translation/${languages.join('-')}-${Date.now()}`;

    if (onProgress) onProgress('Creating branch...', 30);
    await createBranch(user.login, REPO_CONFIG.repo, branchName, baseSha);

    const totalTargets = languages.length * CATEGORIES.length * 2;
    let processedTargets = 0;
    let filesCommitted = 0;
    const filesPlanned = [];
    const filesCommittedList = [];

    for (const langCode of languages) {
        const changedTranslations = translationsByLang[langCode];
        const mergedTranslations = buildMergedTranslations(changedTranslations, fullTranslationsByLang, langCode);
        const categorizedMerged = categorizeTranslations(mergedTranslations);

        for (const category of CATEGORIES) {
            const categoryTranslations = categorizedMerged[category] || {};
            if (Object.keys(categoryTranslations).length === 0) {
                processedTargets += 2;
                continue;
            }

            const filename = `${category}_${langCode}.txt`;
            const outputContent = generateCategoryFile(category, langCode, mergedTranslations);

            // Build 42
            const build42Path = `${REPO_CONFIG.translationPaths.build42}/${langCode}/${filename}`;
            if (onProgress) {
                onProgress(
                    `Processing ${filename} (Build 42)...`,
                    30 + (processedTargets / totalTargets) * 60
                );
            }

            const existing42 = await getFileInfo(user.login, REPO_CONFIG.repo, build42Path, branchName);
            const existingContent42 = decodeGitHubFileContent(existing42);
            const shouldCommit42 = !existing42 || existingContent42 !== outputContent;
            filesPlanned.push(build42Path);

            if (shouldCommit42) {
                await createOrUpdateFile(
                    user.login,
                    REPO_CONFIG.repo,
                    build42Path,
                    outputContent,
                    `Add/Update ${langCode} ${category} translation`,
                    branchName,
                    existing42?.sha || null
                );
                filesCommitted++;
                filesCommittedList.push(build42Path);
            }
            processedTargets++;

            // Build 41
            const build41Path = `${REPO_CONFIG.translationPaths.build41}/${langCode}/${filename}`;
            if (onProgress) {
                onProgress(
                    `Processing ${filename} (Build 41)...`,
                    30 + (processedTargets / totalTargets) * 60
                );
            }

            const existing41 = await getFileInfo(user.login, REPO_CONFIG.repo, build41Path, branchName);
            const existingContent41 = decodeGitHubFileContent(existing41);
            const shouldCommit41 = !existing41 || existingContent41 !== outputContent;
            filesPlanned.push(build41Path);

            if (shouldCommit41) {
                await createOrUpdateFile(
                    user.login,
                    REPO_CONFIG.repo,
                    build41Path,
                    outputContent,
                    `Add/Update ${langCode} ${category} translation`,
                    branchName,
                    existing41?.sha || null
                );
                filesCommitted++;
                filesCommittedList.push(build41Path);
            }
            processedTargets++;
        }
    }

    if (filesCommitted === 0) {
        throw new Error('No file changes detected to commit (all generated files already match the repository).');
    }

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
        languages,
        filesPlanned,
        filesCommitted: filesCommittedList
    };
}

/**
 * Generate PR title
 * @param {string[]} languages - Language codes
 * @param {Object} langNames - Optional display-name map
 * @returns {string} PR title
 */
export function generatePRTitle(languages, langNames = {}) {
    const getDisplayName = code => langNames[code] || code;

    if (languages.length === 1) {
        return `Add/Update ${getDisplayName(languages[0])} translation`;
    }
    if (languages.length <= 3) {
        return `Add/Update ${languages.map(getDisplayName).join(', ')} translations`;
    }
    return `Add/Update translations for ${languages.length} languages`;
}

/**
 * Generate PR body
 * @param {string[]} languages - Language codes
 * @param {Object} translationsByLang - Changed translations
 * @param {Object} langNames - Optional display-name map
 * @returns {string} PR body
 */
export function generatePRBody(languages, translationsByLang, langNames = {}) {
    const english = getEnglishBaseline();
    const englishKeyCount = Math.max(Object.keys(english).length, 1);
    const getDisplayName = code => langNames[code] || code;

    let body = '## Translation Submission\n\n';
    body += 'This PR adds/updates translations for the following languages:\n\n';

    for (const langCode of languages) {
        const changedTranslations = translationsByLang[langCode] || {};
        const changedCount = Object.keys(changedTranslations).length;

        const originalTranslations = getOriginalRepoTranslations(langCode);
        const mergedTranslations = { ...originalTranslations, ...changedTranslations };
        const totalCount = Object.keys(mergedTranslations).length;
        const percentage = Math.round((totalCount / englishKeyCount) * 100);

        body += `- **${getDisplayName(langCode)}** (${langCode}): ${changedCount} changed/new keys (${percentage}% total coverage)\n`;
    }

    body += '\n### Changes by Category\n\n';
    for (const langCode of languages) {
        const categorized = categorizeTranslations(translationsByLang[langCode] || {});
        body += `**${getDisplayName(langCode)}:**\n`;
        for (const category of CATEGORIES) {
            const count = Object.keys(categorized[category] || {}).length;
            if (count > 0) {
                body += `- ${category}: ${count} changed/new keys\n`;
            }
        }
        body += '\n';
    }

    body += '> **Note:** Complete category files are regenerated and submitted for both Build 42 and Build 41.\n\n';
    body += '---\n';
    body += '*Submitted via [Burd\'s Survival Journals Translation Tool](https://theburd.github.io/PZ-BurdSurvivalJournals/)*\n';

    return body;
}

/**
 * Check if user can submit PR
 * @param {Object} translationsByLang - Translations to submit
 * @returns {Object} Status info
 */
export function canSubmitPR(translationsByLang) {
    const isAuthenticated = isGitHubAuthenticated();
    const hasTranslations = translationsByLang && Object.keys(translationsByLang).length > 0;
    const hasContent = hasTranslations && Object.values(translationsByLang).some(
        t => Object.keys(t || {}).length > 0
    );

    return {
        canSubmit: isAuthenticated && hasContent,
        isAuthenticated,
        hasTranslations: hasContent,
        reason: !isAuthenticated
            ? 'Not connected to GitHub'
            : !hasContent
                ? 'No translations to submit'
                : null
    };
}
