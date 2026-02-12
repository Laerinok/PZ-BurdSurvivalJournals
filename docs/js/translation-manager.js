/**
 * Translation Manager
 * Coordinates translation loading, editing, and state management
 */

import { CATEGORIES, BASE_LANGUAGE } from './config.js';
import {
    fetchEnglishBaseline,
    fetchAllCategoriesForLanguage,
    fetchLanguageManifest,
    discoverRepoLanguages,
    calculateCompletionStats,
    getCompletionByCategory
} from './github-fetcher.js';
import {
    saveLanguageTranslations,
    saveLanguageTranslationsDebounced,
    getLanguageTranslations,
    getAllTranslations,
    getSavedLanguages,
    cacheEnglishBaseline,
    getCachedEnglishBaseline,
    hasEnglishCache,
    updateLastSync
} from './storage-manager.js';
import { categorizeTranslations } from './lua-parser.js';

// State
let englishBaseline = null;
let currentLanguage = null;
let currentTranslations = {};
let languageManifest = null;
let discoveredRepoLanguages = []; // Dynamically discovered from GitHub API
let isLoading = false;
let isOfflineMode = false;

// Track original repo translations to detect changes
// Structure: { langCode: { key: value, ... }, ... }
let originalRepoTranslations = {};

// Event callbacks
const eventHandlers = {
    onLoadingStart: [],
    onLoadingEnd: [],
    onLoadingProgress: [],
    onLanguageChanged: [],
    onTranslationChanged: [],
    onError: []
};

/**
 * Register event handler
 * @param {string} event - Event name
 * @param {Function} handler - Handler function
 */
export function on(event, handler) {
    if (eventHandlers[event]) {
        eventHandlers[event].push(handler);
    }
}

/**
 * Emit event
 * @param {string} event - Event name
 * @param {*} data - Event data
 */
function emit(event, data) {
    if (eventHandlers[event]) {
        for (const handler of eventHandlers[event]) {
            try {
                handler(data);
            } catch (e) {
                console.error(`Error in event handler for ${event}:`, e);
            }
        }
    }
}

/**
 * Initialize the translation manager
 * @param {Function} onProgress - Progress callback
 * @returns {Promise<boolean>} True if successful
 */
export async function initialize(onProgress = null) {
    isLoading = true;
    emit('onLoadingStart', { phase: 'init' });

    try {
        // Load language manifest (for display names)
        if (onProgress) onProgress('Loading language manifest...', 0, 4);
        languageManifest = await fetchLanguageManifest();

        if (!languageManifest) {
            // Use default manifest structure
            languageManifest = {
                zomboidLanguages: []
            };
        }

        // Dynamically discover which languages exist in the repo
        if (onProgress) onProgress('Discovering available languages...', 1, 4);
        const discovered = await discoverRepoLanguages();
        if (discovered && discovered.length > 0) {
            discoveredRepoLanguages = discovered;
            console.log('Languages in repo:', discoveredRepoLanguages);
        } else {
            // Fallback to EN only if discovery fails
            discoveredRepoLanguages = ['EN'];
            console.warn('Language discovery failed, defaulting to EN only');
        }

        // Load English baseline
        if (onProgress) onProgress('Loading English baseline...', 2, 4);

        // Check cache first
        const cached = getCachedEnglishBaseline();
        if (cached) {
            englishBaseline = cached;
            isOfflineMode = false;

            // Try to refresh in background
            refreshEnglishBaseline().catch(e => {
                console.warn('Background refresh failed:', e);
            });
        } else {
            // Must fetch from network
            const result = await fetchEnglishBaseline((category, index, total) => {
                if (onProgress) {
                    onProgress(`Loading ${category}...`, 2 + (index / total), 4);
                }
            });

            if (result.errors.length === CATEGORIES.length) {
                // All categories failed
                emit('onError', { message: 'Failed to load English translations. Check your internet connection.' });
                isOfflineMode = true;
                isLoading = false;
                emit('onLoadingEnd', { success: false });
                return false;
            }

            englishBaseline = result.translations;
            cacheEnglishBaseline(englishBaseline);
        }

        if (onProgress) onProgress('Ready!', 4, 4);

        isLoading = false;
        emit('onLoadingEnd', { success: true });
        return true;
    } catch (error) {
        console.error('Initialization failed:', error);
        emit('onError', { message: error.message });
        isLoading = false;
        emit('onLoadingEnd', { success: false });
        return false;
    }
}

/**
 * Refresh English baseline from GitHub
 */
async function refreshEnglishBaseline() {
    const result = await fetchEnglishBaseline();
    if (result.errors.length < CATEGORIES.length) {
        englishBaseline = result.translations;
        cacheEnglishBaseline(englishBaseline);
        updateLastSync();
    }
}

/**
 * Get the English baseline translations
 * @returns {Object} English translations
 */
export function getEnglishBaseline() {
    return englishBaseline || {};
}

/**
 * Get current language code
 * @returns {string|null} Current language code
 */
export function getCurrentLanguage() {
    return currentLanguage;
}

/**
 * Get current translations
 * @returns {Object} Current translations
 */
export function getCurrentTranslations() {
    return { ...currentTranslations };
}

/**
 * Switch to a different language
 * @param {string} langCode - Language code
 * @param {boolean} loadFromRepo - Whether to load from GitHub
 * @param {Function} onProgress - Progress callback
 * @returns {Promise<boolean>} True if successful
 */
export async function switchLanguage(langCode, loadFromRepo = true, onProgress = null) {
    if (langCode === currentLanguage) {
        return true;
    }

    isLoading = true;
    emit('onLoadingStart', { phase: 'switch', langCode });

    try {
        // Save current language if exists
        if (currentLanguage && Object.keys(currentTranslations).length > 0) {
            saveLanguageTranslations(currentLanguage, currentTranslations);
        }

        currentLanguage = langCode;
        currentTranslations = {};

        // Check for saved local translations first
        const saved = getLanguageTranslations(langCode);
        if (saved) {
            currentTranslations = { ...saved };
        }

        // If loading from repo and language is in repo
        if (loadFromRepo && isLanguageInRepo(langCode)) {
            if (onProgress) onProgress(`Loading ${langCode} translations...`, 0, 1);

            const result = await fetchAllCategoriesForLanguage(langCode, (category, index, total) => {
                if (onProgress) {
                    onProgress(`Loading ${category}...`, index / total, 1);
                }
            });

            // Store the original repo translations for this language (for change detection)
            originalRepoTranslations[langCode] = { ...result.translations };

            // Merge repo translations (repo takes precedence for existing keys)
            // But preserve local additions
            for (const [key, value] of Object.entries(result.translations)) {
                if (!(key in currentTranslations) || !currentTranslations[key]) {
                    currentTranslations[key] = value;
                }
            }
        } else if (!isLanguageInRepo(langCode)) {
            // For new languages not in repo, there are no original translations
            originalRepoTranslations[langCode] = {};
        }

        emit('onLanguageChanged', { langCode, translations: currentTranslations });
        isLoading = false;
        emit('onLoadingEnd', { success: true });
        return true;
    } catch (error) {
        console.error('Failed to switch language:', error);
        emit('onError', { message: error.message });
        isLoading = false;
        emit('onLoadingEnd', { success: false });
        return false;
    }
}

/**
 * Update a single translation
 * @param {string} key - Translation key
 * @param {string} value - Translation value
 */
export function updateTranslation(key, value) {
    currentTranslations[key] = value;
    saveLanguageTranslationsDebounced(currentLanguage, currentTranslations);
    emit('onTranslationChanged', { key, value, langCode: currentLanguage });
}

/**
 * Update multiple translations
 * @param {Object} translations - Object with key-value pairs
 */
export function updateTranslations(translations) {
    Object.assign(currentTranslations, translations);
    saveLanguageTranslations(currentLanguage, currentTranslations);
    emit('onTranslationChanged', { bulk: true, langCode: currentLanguage });
}

/**
 * Clear all translations for current language
 */
export function clearCurrentTranslations() {
    currentTranslations = {};
    if (currentLanguage) {
        saveLanguageTranslations(currentLanguage, currentTranslations);
    }
    emit('onTranslationChanged', { cleared: true, langCode: currentLanguage });
}

/**
 * Get translation for a key
 * @param {string} key - Translation key
 * @returns {string} Translation value or empty string
 */
export function getTranslation(key) {
    return currentTranslations[key] || '';
}

/**
 * Get English value for a key
 * @param {string} key - Translation key
 * @returns {string} English value or empty string
 */
export function getEnglishValue(key) {
    return englishBaseline?.[key] || '';
}

/**
 * Get all English keys
 * @returns {string[]} Array of keys
 */
export function getEnglishKeys() {
    return Object.keys(englishBaseline || {});
}

/**
 * Get completion statistics for current language
 * @returns {Object} Completion stats
 */
export function getCompletionStats() {
    if (!englishBaseline) {
        return { total: 0, translated: 0, percentage: 0 };
    }
    return calculateCompletionStats(currentTranslations, englishBaseline);
}

/**
 * Get completion by category for current language
 * @returns {Object} Stats by category
 */
export function getCategoryStats() {
    if (!englishBaseline) {
        return {};
    }
    return getCompletionByCategory(currentTranslations, englishBaseline);
}

/**
 * Get categorized translations
 * @returns {Object} Translations by category
 */
export function getCategorizedTranslations() {
    return categorizeTranslations(currentTranslations);
}

/**
 * Get categorized English baseline
 * @returns {Object} English by category
 */
export function getCategorizedEnglish() {
    return categorizeTranslations(englishBaseline || {});
}

/**
 * Check if a language is in the repository
 * @param {string} langCode - Language code
 * @returns {boolean} True if in repo
 */
export function isLanguageInRepo(langCode) {
    return discoveredRepoLanguages.includes(langCode);
}

/**
 * Get available languages (dynamically discovered from repo)
 * @returns {Array} Array of language objects
 */
export function getAvailableLanguages() {
    // Build from discovered languages + display names from manifest
    const allKnownLanguages = getAllKnownLanguages();

    return discoveredRepoLanguages.map(code => {
        const known = allKnownLanguages.find(l => l.code === code);
        return {
            code,
            name: known?.name || code,
            inRepo: true
        };
    });
}

/**
 * Get all known languages (for display names)
 * Combines zomboidLanguages from manifest with common language names
 */
function getAllKnownLanguages() {
    const builtIn = [
        { code: 'EN', name: 'English' },
        { code: 'CN', name: 'Chinese (Simplified)' },
        { code: 'FR', name: 'French' },
        { code: 'DE', name: 'German' },
        { code: 'ES', name: 'Spanish' },
        { code: 'IT', name: 'Italian' },
        { code: 'JP', name: 'Japanese' },
        { code: 'KO', name: 'Korean' },
        { code: 'PL', name: 'Polish' },
        { code: 'PTBR', name: 'Portuguese (Brazil)' },
        { code: 'RU', name: 'Russian' },
        { code: 'TR', name: 'Turkish' },
        { code: 'UA', name: 'Ukrainian' },
        { code: 'TH', name: 'Thai' },
        { code: 'AR', name: 'Arabic' },
        { code: 'CA', name: 'Catalan' },
        { code: 'CH', name: 'Traditional Chinese' },
        { code: 'CS', name: 'Czech' },
        { code: 'DA', name: 'Danish' },
        { code: 'EE', name: 'Estonian' },
        { code: 'FI', name: 'Finnish' },
        { code: 'HU', name: 'Hungarian' },
        { code: 'ID', name: 'Indonesian' },
        { code: 'NL', name: 'Dutch' },
        { code: 'NO', name: 'Norwegian' },
        { code: 'PH', name: 'Tagalog' },
        { code: 'PT', name: 'Portuguese' },
        { code: 'RO', name: 'Romanian' },
        { code: 'VI', name: 'Vietnamese' }
    ];

    // Merge with manifest's zomboidLanguages
    const fromManifest = languageManifest?.zomboidLanguages || [];
    const combined = [...builtIn];

    for (const lang of fromManifest) {
        if (!combined.find(l => l.code === lang.code)) {
            combined.push(lang);
        }
    }

    return combined;
}

/**
 * Get all Zomboid languages not yet in repo (for new translations)
 * @returns {Array} Array of language objects
 */
export function getZomboidLanguages() {
    const allKnown = getAllKnownLanguages();
    // Filter out languages already in the repo
    return allKnown.filter(lang => !discoveredRepoLanguages.includes(lang.code));
}

/**
 * Get all languages (available + zomboid)
 * @returns {Array} Combined array
 */
export function getAllLanguages() {
    const available = getAvailableLanguages();
    const zomboid = getZomboidLanguages();
    const availableCodes = available.map(l => l.code);

    // Combine, excluding duplicates
    return [
        ...available,
        ...zomboid.filter(l => !availableCodes.includes(l.code))
    ];
}

/**
 * Get languages with local work (saved translations)
 * @returns {Array} Array of language codes
 */
export function getLanguagesWithLocalWork() {
    return getSavedLanguages();
}

/**
 * Check if currently loading
 * @returns {boolean} True if loading
 */
export function isCurrentlyLoading() {
    return isLoading;
}

/**
 * Check if in offline mode
 * @returns {boolean} True if offline
 */
export function isOffline() {
    return isOfflineMode;
}

/**
 * Force save current translations
 */
export function forceSave() {
    if (currentLanguage) {
        saveLanguageTranslations(currentLanguage, currentTranslations);
    }
}

/**
 * Get all saved translation data for PR submission
 * Only includes translations that are NEW or CHANGED compared to the repo
 * IMPORTANT: Only includes languages that have been loaded this session
 * (so we have a baseline to compare against)
 * @returns {Object} Changed/new translations by language
 */
export function getAllSavedTranslationsForSubmission() {
    const result = {};

    // First, save current work to ensure we have the latest
    if (currentLanguage && Object.keys(currentTranslations).length > 0) {
        saveLanguageTranslations(currentLanguage, currentTranslations);
    }

    const saved = getAllTranslations();

    for (const [langCode, data] of Object.entries(saved)) {
        if (!data.translations || Object.keys(data.translations).length === 0) {
            continue;
        }

        // CRITICAL: Only include languages that have been loaded this session
        // If we haven't loaded the language, we don't have a baseline to compare against
        // and we'd incorrectly mark all saved translations as "new"
        if (!(langCode in originalRepoTranslations)) {
            console.log(`Skipping ${langCode} - not loaded this session (no baseline for comparison)`);
            continue;
        }

        // Get the original repo translations for this language
        const originalRepo = originalRepoTranslations[langCode];

        // Find only changed or new translations
        const changedTranslations = {};
        for (const [key, value] of Object.entries(data.translations)) {
            // Skip empty values
            if (!value || !value.trim()) continue;

            const originalValue = originalRepo[key];

            // Include if: new key (not in repo) OR value has changed
            if (originalValue === undefined || originalValue !== value) {
                changedTranslations[key] = value;
            }
        }

        // Only include language if there are actual changes
        if (Object.keys(changedTranslations).length > 0) {
            result[langCode] = changedTranslations;
        }
    }

    return result;
}

/**
 * Get original repo translations for a language
 * @param {string} langCode - Language code
 * @returns {Object} Original translations from repo
 */
export function getOriginalRepoTranslations(langCode) {
    return originalRepoTranslations[langCode] || {};
}

/**
 * Get full merged translations for PR submission
 * This returns complete translation files (repo + user edits merged)
 * @returns {Object} Full merged translations by language code
 */
export function getFullMergedTranslationsForSubmission() {
    const result = {};

    // First, save current work to ensure we have the latest
    if (currentLanguage && Object.keys(currentTranslations).length > 0) {
        saveLanguageTranslations(currentLanguage, currentTranslations);
    }

    const saved = getAllTranslations();

    for (const [langCode, data] of Object.entries(saved)) {
        if (!data.translations || Object.keys(data.translations).length === 0) {
            continue;
        }

        // CRITICAL: Only include languages that have been loaded this session
        if (!(langCode in originalRepoTranslations)) {
            console.log(`Skipping ${langCode} for full merge - not loaded this session`);
            continue;
        }

        // Merge: start with original repo translations, overlay user edits
        const originalRepo = originalRepoTranslations[langCode];
        const userEdits = data.translations;

        // Create full merged translations
        const mergedTranslations = { ...originalRepo };

        // Apply user edits (only non-empty values)
        for (const [key, value] of Object.entries(userEdits)) {
            if (value && value.trim()) {
                mergedTranslations[key] = value;
            }
        }

        result[langCode] = mergedTranslations;
    }

    return result;
}

/**
 * Get the language manifest
 * @returns {Object} Language manifest
 */
export function getLanguageManifest() {
    return languageManifest;
}

/**
 * Get the raw list of discovered repo languages
 * @returns {string[]} Array of language codes in the repo
 */
export function getDiscoveredRepoLanguages() {
    return [...discoveredRepoLanguages];
}
