/**
 * Configuration constants for Burd's Survival Journals Translation Tool
 */

// GitHub Repository Configuration
export const REPO_CONFIG = {
    owner: 'TheBurd',
    repo: 'PZ-BurdSurvivalJournals',
    branch: 'master',
    translationPaths: {
        build42: 'Contents/mods/BurdSurvivalJournals/42/media/lua/shared/Translate',
        build41: 'Contents/mods/BurdSurvivalJournals/common/media/lua/shared/Translate'
    }
};

// GitHub OAuth Configuration
export const OAUTH_CONFIG = {
    clientId: 'Ov23liUhJDO8dqrWN0rs',
    workerUrl: 'https://bsj-oauth.burdsurvivaljournals.workers.dev',
    scopes: ['public_repo'] // Scope for creating PRs on public repos
};

// Translation file categories
export const CATEGORIES = [
    'ContextMenu',
    'IG_UI',
    'ItemName',
    'Recipes',
    'Sandbox',
    'Tooltip',
    'UI'
];

// Base language (English is the source of truth)
export const BASE_LANGUAGE = 'EN';

// localStorage keys
export const STORAGE_KEYS = {
    translations: 'bsj_translations',
    githubToken: 'bsj_github_token',
    lastSync: 'bsj_last_sync',
    cachedEnglish: 'bsj_cached_english',
    cachedEnglishVersion: 'bsj_cached_english_version',
    cachedRepoLanguages: 'bsj_cached_repo_languages',
    cachedRepoLanguagesVersion: 'bsj_cached_repo_languages_version'
};

// GitHub raw content base URL
export const GITHUB_RAW_BASE = `https://raw.githubusercontent.com/${REPO_CONFIG.owner}/${REPO_CONFIG.repo}/${REPO_CONFIG.branch}`;

// Build a raw URL for a translation file
export function getRawUrl(langCode, category, build = 'build42') {
    const path = REPO_CONFIG.translationPaths[build];
    return `${GITHUB_RAW_BASE}/${path}/${langCode}/${category}_${langCode}.txt`;
}

// Mod folder name for exports
export const MOD_FOLDER_NAME = 'BurdSurvivalJournals';

// Export ZIP structure paths
export const EXPORT_PATHS = {
    build42: `Contents/mods/${MOD_FOLDER_NAME}/42/media/lua/shared/Translate`,
    build41: `Contents/mods/${MOD_FOLDER_NAME}/common/media/lua/shared/Translate`
};

// Debounce delay for auto-save (ms)
export const AUTOSAVE_DELAY = 500;

// Version for cache invalidation
export const TOOL_VERSION = '3.1.0';
