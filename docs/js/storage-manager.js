/**
 * Storage Manager
 * Handles localStorage caching for translations and user data
 */

import { STORAGE_KEYS, TOOL_VERSION, AUTOSAVE_DELAY } from './config.js';

// Debounce timer for auto-save
let saveTimer = null;

/**
 * Save translations for a specific language
 * @param {string} langCode - Language code
 * @param {Object} translations - Translations object
 */
export function saveLanguageTranslations(langCode, translations) {
    if (!langCode || typeof langCode !== 'string') {
        console.warn('Skipping saveLanguageTranslations: invalid language code');
        return;
    }

    const allTranslations = getAllTranslations();
    allTranslations[langCode] = {
        translations,
        lastModified: new Date().toISOString()
    };
    localStorage.setItem(STORAGE_KEYS.translations, JSON.stringify(allTranslations));
}

/**
 * Save translations with debounce (for auto-save on edit)
 * @param {string} langCode - Language code
 * @param {Object} translations - Translations object
 */
export function saveLanguageTranslationsDebounced(langCode, translations) {
    if (!langCode || typeof langCode !== 'string') {
        return;
    }

    if (saveTimer) {
        clearTimeout(saveTimer);
    }

    saveTimer = setTimeout(() => {
        saveLanguageTranslations(langCode, translations);
        saveTimer = null;
    }, AUTOSAVE_DELAY);
}

/**
 * Get all saved translations
 * @returns {Object} All translations by language code
 */
export function getAllTranslations() {
    try {
        const stored = localStorage.getItem(STORAGE_KEYS.translations);
        if (stored) {
            return JSON.parse(stored);
        }
    } catch (e) {
        console.error('Failed to parse stored translations:', e);
    }
    return {};
}

/**
 * Get translations for a specific language
 * @param {string} langCode - Language code
 * @returns {Object|null} Translations or null if not found
 */
export function getLanguageTranslations(langCode) {
    const all = getAllTranslations();
    return all[langCode]?.translations || null;
}

/**
 * Get metadata for a saved language
 * @param {string} langCode - Language code
 * @returns {Object|null} Metadata or null
 */
export function getLanguageMetadata(langCode) {
    const all = getAllTranslations();
    if (all[langCode]) {
        return {
            lastModified: all[langCode].lastModified,
            keyCount: Object.keys(all[langCode].translations || {}).length
        };
    }
    return null;
}

/**
 * Get list of languages with saved translations
 * @returns {string[]} Array of language codes
 */
export function getSavedLanguages() {
    const all = getAllTranslations();
    return Object.keys(all);
}

/**
 * Delete translations for a language
 * @param {string} langCode - Language code
 */
export function deleteLanguageTranslations(langCode) {
    const all = getAllTranslations();
    delete all[langCode];
    localStorage.setItem(STORAGE_KEYS.translations, JSON.stringify(all));
}

/**
 * Clear all saved translations
 */
export function clearAllTranslations() {
    localStorage.removeItem(STORAGE_KEYS.translations);
}

/**
 * Save English baseline to cache
 * @param {Object} translations - English translations
 */
export function cacheEnglishBaseline(translations) {
    try {
        localStorage.setItem(STORAGE_KEYS.cachedEnglish, JSON.stringify(translations));
        localStorage.setItem(STORAGE_KEYS.cachedEnglishVersion, JSON.stringify({
            version: TOOL_VERSION,
            timestamp: new Date().toISOString()
        }));
    } catch (e) {
        console.error('Failed to cache English baseline:', e);
        // Storage might be full, try to clear old data
        try {
            localStorage.removeItem(STORAGE_KEYS.cachedEnglish);
        } catch (e2) {
            // Ignore
        }
    }
}

/**
 * Get cached English baseline
 * @returns {Object|null} Cached translations or null
 */
export function getCachedEnglishBaseline() {
    try {
        const versionData = localStorage.getItem(STORAGE_KEYS.cachedEnglishVersion);
        if (versionData) {
            const { version } = JSON.parse(versionData);
            // Only use cache if version matches
            if (version === TOOL_VERSION) {
                const cached = localStorage.getItem(STORAGE_KEYS.cachedEnglish);
                if (cached) {
                    return JSON.parse(cached);
                }
            }
        }
    } catch (e) {
        console.error('Failed to retrieve cached English baseline:', e);
    }
    return null;
}

/**
 * Check if English baseline is cached
 * @returns {boolean} True if cached
 */
export function hasEnglishCache() {
    return getCachedEnglishBaseline() !== null;
}

/**
 * Clear English baseline cache
 */
export function clearEnglishCache() {
    localStorage.removeItem(STORAGE_KEYS.cachedEnglish);
    localStorage.removeItem(STORAGE_KEYS.cachedEnglishVersion);
}

/**
 * Cache discovered repository languages for resilient startup fallback
 * @param {string[]} languages - Language codes discovered from GitHub
 */
export function cacheRepoLanguages(languages) {
    if (!Array.isArray(languages) || languages.length === 0) {
        return;
    }

    const normalized = languages
        .filter(code => typeof code === 'string')
        .map(code => code.trim().toUpperCase())
        .filter(code => /^[A-Z]{2,4}$/.test(code));

    if (normalized.length === 0) {
        return;
    }

    localStorage.setItem(STORAGE_KEYS.cachedRepoLanguages, JSON.stringify(normalized));
    localStorage.setItem(STORAGE_KEYS.cachedRepoLanguagesVersion, JSON.stringify({
        version: TOOL_VERSION,
        timestamp: new Date().toISOString()
    }));
}

/**
 * Get cached repository languages
 * @returns {string[]|null} Cached language codes or null
 */
export function getCachedRepoLanguages() {
    try {
        const versionData = localStorage.getItem(STORAGE_KEYS.cachedRepoLanguagesVersion);
        if (versionData) {
            const { version } = JSON.parse(versionData);
            if (version === TOOL_VERSION) {
                const cached = localStorage.getItem(STORAGE_KEYS.cachedRepoLanguages);
                if (cached) {
                    const parsed = JSON.parse(cached);
                    if (Array.isArray(parsed) && parsed.length > 0) {
                        return parsed;
                    }
                }
            }
        }
    } catch (e) {
        console.error('Failed to retrieve cached repo languages:', e);
    }

    return null;
}

/**
 * Save GitHub token
 * @param {string} token - GitHub access token
 */
export function saveGitHubToken(token) {
    sessionStorage.setItem(STORAGE_KEYS.githubToken, token);
}

/**
 * Get GitHub token
 * @returns {string|null} Token or null
 */
export function getGitHubToken() {
    return sessionStorage.getItem(STORAGE_KEYS.githubToken);
}

/**
 * Clear GitHub token
 */
export function clearGitHubToken() {
    sessionStorage.removeItem(STORAGE_KEYS.githubToken);
}

/**
 * Check if user is authenticated with GitHub
 * @returns {boolean} True if authenticated
 */
export function isGitHubAuthenticated() {
    return !!getGitHubToken();
}

/**
 * Save last sync timestamp
 */
export function updateLastSync() {
    localStorage.setItem(STORAGE_KEYS.lastSync, new Date().toISOString());
}

/**
 * Get last sync timestamp
 * @returns {string|null} ISO timestamp or null
 */
export function getLastSync() {
    return localStorage.getItem(STORAGE_KEYS.lastSync);
}

/**
 * Export all user data for backup
 * @returns {Object} All stored data
 */
export function exportUserData() {
    return {
        version: TOOL_VERSION,
        exportedAt: new Date().toISOString(),
        translations: getAllTranslations(),
        lastSync: getLastSync()
    };
}

/**
 * Import user data from backup
 * @param {Object} data - Exported data object
 * @returns {boolean} True if successful
 */
export function importUserData(data) {
    try {
        if (data.translations) {
            localStorage.setItem(STORAGE_KEYS.translations, JSON.stringify(data.translations));
        }
        if (data.lastSync) {
            localStorage.setItem(STORAGE_KEYS.lastSync, data.lastSync);
        }
        return true;
    } catch (e) {
        console.error('Failed to import user data:', e);
        return false;
    }
}

/**
 * Get storage usage info
 * @returns {Object} Storage stats
 */
export function getStorageStats() {
    const stats = {
        translations: 0,
        englishCache: 0,
        total: 0
    };

    try {
        const translations = localStorage.getItem(STORAGE_KEYS.translations);
        if (translations) {
            stats.translations = new Blob([translations]).size;
        }

        const englishCache = localStorage.getItem(STORAGE_KEYS.cachedEnglish);
        if (englishCache) {
            stats.englishCache = new Blob([englishCache]).size;
        }

        stats.total = stats.translations + stats.englishCache;
    } catch (e) {
        console.error('Failed to calculate storage stats:', e);
    }

    return stats;
}

/**
 * Check if there are unsaved changes for a language
 * @param {string} langCode - Language code
 * @param {Object} currentTranslations - Current translations in memory
 * @returns {boolean} True if there are unsaved changes
 */
export function hasUnsavedChanges(langCode, currentTranslations) {
    const saved = getLanguageTranslations(langCode);
    if (!saved) {
        // If nothing saved, check if current has any translations
        return Object.keys(currentTranslations || {}).length > 0;
    }

    // Compare keys and values
    const currentKeys = Object.keys(currentTranslations || {});
    const savedKeys = Object.keys(saved);

    if (currentKeys.length !== savedKeys.length) {
        return true;
    }

    for (const key of currentKeys) {
        if (currentTranslations[key] !== saved[key]) {
            return true;
        }
    }

    return false;
}
