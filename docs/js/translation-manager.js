/**
 * Translation Manager
 * Coordinates translation loading, editing, validation, and submission preflight state
 */

import { CATEGORIES, BASE_LANGUAGE, REPO_CONFIG, GITHUB_RAW_BASE } from './config.js';
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
    updateLastSync,
    cacheRepoLanguages,
    getCachedRepoLanguages
} from './storage-manager.js';
import { categorizeTranslations, getCategoryFromKey } from './lua-parser.js';

const STATIC_REPO_LANGUAGE_FALLBACK = [
    'EN', 'CN', 'ES', 'FR', 'ID', 'KO', 'PL', 'PTBR', 'RU', 'TR', 'UA'
];

// State
let englishBaseline = null;
let currentLanguage = null;
let currentTranslations = {};
let languageManifest = null;
let discoveredRepoLanguages = [];
let isLoading = false;
let isOfflineMode = false;

// Track original repo translations to detect changes
// Structure: { langCode: { key: value, ... }, ... }
let originalRepoTranslations = {};

// Cached payload built by submission preflight
let lastSubmissionPreflight = null;

// Cached diagnostics report
let lastDiagnosticsReport = {
    duplicateKeys: [],
    parseErrors: [],
    legacyItemsPresent: [],
    missingCategoriesByLang: {}
};

// Event callbacks
const eventHandlers = {
    onLoadingStart: [],
    onLoadingEnd: [],
    onLoadingProgress: [],
    onLanguageChanged: [],
    onTranslationChanged: [],
    onError: []
};

function normalizeLangCode(code) {
    if (!code || typeof code !== 'string') return null;
    return code.trim().toUpperCase();
}

function decodeWithCorrectEncoding(buffer) {
    const bytes = new Uint8Array(buffer);
    let decoded;

    if (bytes.length >= 2 && bytes[0] === 0xFF && bytes[1] === 0xFE) {
        decoded = new TextDecoder('utf-16le').decode(buffer);
    } else if (bytes.length >= 2 && bytes[0] === 0xFE && bytes[1] === 0xFF) {
        decoded = new TextDecoder('utf-16be').decode(buffer);
    } else if (bytes.length >= 3 && bytes[0] === 0xEF && bytes[1] === 0xBB && bytes[2] === 0xBF) {
        decoded = new TextDecoder('utf-8').decode(buffer);
    } else {
        decoded = new TextDecoder('utf-8').decode(buffer);
    }

    if (decoded.charCodeAt(0) === 0xFEFF) {
        decoded = decoded.substring(1);
    }

    return decoded;
}

async function detectDuplicateKeysInFile(url, langCode, category, path) {
    try {
        const response = await fetch(url);
        if (!response.ok) return [];

        const buffer = await response.arrayBuffer();
        const content = decodeWithCorrectEncoding(buffer);
        const lines = content.split('\n');
        const firstSeen = new Map();
        const duplicates = [];

        for (let i = 0; i < lines.length; i++) {
            const match = lines[i].trim().match(/^([\w.]+)\s*=/);
            if (!match) continue;

            const key = match[1];
            const line = i + 1;
            if (firstSeen.has(key)) {
                duplicates.push({
                    langCode,
                    category,
                    key,
                    lines: [firstSeen.get(key), line],
                    path
                });
            } else {
                firstSeen.set(key, line);
            }
        }

        return duplicates;
    } catch (e) {
        return [];
    }
}

function normalizeLanguageList(codes) {
    if (!Array.isArray(codes)) return [];
    return [...new Set(
        codes
            .map(normalizeLangCode)
            .filter(code => !!code && /^[A-Z]{2,4}$/.test(code))
    )].sort();
}

function ensureBaseLanguage(codes) {
    const normalized = normalizeLanguageList(codes);
    if (!normalized.includes(BASE_LANGUAGE)) {
        normalized.unshift(BASE_LANGUAGE);
    }
    return normalized;
}

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

async function resolveRepoLanguages() {
    const discovered = await discoverRepoLanguages();
    const normalizedDiscovered = normalizeLanguageList(discovered);
    if (normalizedDiscovered.length > 0) {
        cacheRepoLanguages(normalizedDiscovered);
        return {
            source: 'github',
            languages: ensureBaseLanguage(normalizedDiscovered)
        };
    }

    const cached = normalizeLanguageList(getCachedRepoLanguages());
    if (cached.length > 0) {
        return {
            source: 'cache',
            languages: ensureBaseLanguage(cached)
        };
    }

    return {
        source: 'static',
        languages: ensureBaseLanguage(STATIC_REPO_LANGUAGE_FALLBACK)
    };
}

async function ensureRepoBaseline(langCode, onProgress = null) {
    const normalized = normalizeLangCode(langCode);
    if (!normalized) {
        return {};
    }

    if (originalRepoTranslations[normalized]) {
        return originalRepoTranslations[normalized];
    }

    if (!isLanguageInRepo(normalized)) {
        originalRepoTranslations[normalized] = {};
        return {};
    }

    const result = await fetchAllCategoriesForLanguage(normalized, onProgress);
    if (result.errors.length === CATEGORIES.length) {
        throw new Error(`Failed to load repository baseline for ${normalized}`);
    }

    originalRepoTranslations[normalized] = { ...result.translations };
    return originalRepoTranslations[normalized];
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
            languageManifest = { zomboidLanguages: [] };
        }

        // Discover repo languages with resilient fallback
        if (onProgress) onProgress('Discovering available languages...', 1, 4);
        const resolved = await resolveRepoLanguages();
        discoveredRepoLanguages = resolved.languages;
        if (resolved.source !== 'github') {
            console.warn(`Language discovery fallback in use: ${resolved.source}`);
        }

        // Load English baseline
        if (onProgress) onProgress('Loading English baseline...', 2, 4);
        const cached = getCachedEnglishBaseline();
        if (cached) {
            englishBaseline = cached;
            isOfflineMode = false;

            // Refresh in background
            refreshEnglishBaseline().catch(e => {
                console.warn('Background refresh failed:', e);
            });
        } else {
            const result = await fetchEnglishBaseline((category, index, total) => {
                if (onProgress) {
                    onProgress(`Loading ${category}...`, 2 + (index / total), 4);
                }
            });

            if (result.errors.length === CATEGORIES.length) {
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
    const normalized = normalizeLangCode(langCode);
    if (!normalized) {
        return false;
    }

    if (normalized === currentLanguage) {
        return true;
    }

    isLoading = true;
    emit('onLoadingStart', { phase: 'switch', langCode: normalized });

    try {
        if (currentLanguage && Object.keys(currentTranslations).length > 0) {
            saveLanguageTranslations(currentLanguage, currentTranslations);
        }

        currentLanguage = normalized;
        currentTranslations = {};

        // Load local saved translations first
        const saved = getLanguageTranslations(normalized);
        if (saved) {
            currentTranslations = { ...saved };
        }

        if (loadFromRepo && isLanguageInRepo(normalized)) {
            if (onProgress) onProgress(`Loading ${normalized} translations...`, 0, 1);
            const repoTranslations = await ensureRepoBaseline(normalized, (category, index, total) => {
                if (onProgress) {
                    onProgress(`Loading ${category}...`, index / total, 1);
                }
            });

            for (const [key, value] of Object.entries(repoTranslations)) {
                if (!(key in currentTranslations) || !currentTranslations[key]) {
                    currentTranslations[key] = value;
                }
            }
        } else if (!isLanguageInRepo(normalized)) {
            originalRepoTranslations[normalized] = {};
        }

        emit('onLanguageChanged', { langCode: normalized, translations: currentTranslations });
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
    if (!currentLanguage) {
        console.warn('Skipping updateTranslation: no language selected');
        return;
    }

    currentTranslations[key] = value;
    saveLanguageTranslationsDebounced(currentLanguage, currentTranslations);
    emit('onTranslationChanged', { key, value, langCode: currentLanguage });
}

/**
 * Update multiple translations
 * @param {Object} translations - Object with key-value pairs
 */
export function updateTranslations(translations) {
    if (!currentLanguage) {
        console.warn('Skipping updateTranslations: no language selected');
        return;
    }

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
    const normalized = normalizeLangCode(langCode);
    if (!normalized) return false;
    return discoveredRepoLanguages.includes(normalized);
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

    const fromManifest = languageManifest?.zomboidLanguages || [];
    const combined = [...builtIn];

    for (const lang of fromManifest) {
        const code = normalizeLangCode(lang.code);
        if (!code) continue;

        if (!combined.find(l => l.code === code)) {
            combined.push({
                ...lang,
                code,
                name: lang.name || code
            });
        }
    }

    return combined;
}

/**
 * Get available languages (from repo)
 * @returns {Array} Array of language objects
 */
export function getAvailableLanguages() {
    const allKnown = getAllKnownLanguages();
    const localWork = new Set(getLanguagesWithLocalWork());

    return discoveredRepoLanguages.map(code => {
        const known = allKnown.find(l => l.code === code);
        return {
            code,
            name: known?.name || code,
            inRepo: true,
            hasLocalDraft: localWork.has(code)
        };
    });
}

/**
 * Get local draft languages not currently in repo
 * @returns {Array} Local draft language objects
 */
export function getLocalDraftLanguages() {
    const allKnown = getAllKnownLanguages();
    return getLanguagesWithLocalWork()
        .filter(code => !isLanguageInRepo(code))
        .map(code => {
            const known = allKnown.find(l => l.code === code);
            return {
                code,
                name: known?.name || code,
                inRepo: false,
                hasLocalDraft: true
            };
        })
        .sort((a, b) => a.code.localeCompare(b.code));
}

/**
 * Get all Zomboid languages not yet in repo and without local draft
 * @returns {Array} Array of language objects
 */
export function getZomboidLanguages() {
    const allKnown = getAllKnownLanguages();
    const localWork = new Set(getLanguagesWithLocalWork());

    return allKnown
        .filter(lang => !discoveredRepoLanguages.includes(lang.code))
        .filter(lang => !localWork.has(lang.code));
}

/**
 * Get all languages (available + local drafts + new)
 * @returns {Array} Combined array
 */
export function getAllLanguages() {
    const available = getAvailableLanguages();
    const localDrafts = getLocalDraftLanguages();
    const zomboid = getZomboidLanguages();
    const taken = new Set([...available, ...localDrafts].map(l => l.code));

    return [
        ...available,
        ...localDrafts,
        ...zomboid.filter(l => !taken.has(l.code))
    ];
}

/**
 * Get languages with local work (saved translations)
 * @returns {Array} Array of language codes
 */
export function getLanguagesWithLocalWork() {
    return normalizeLanguageList(getSavedLanguages());
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

function getSavedSnapshots() {
    if (currentLanguage && Object.keys(currentTranslations).length > 0) {
        saveLanguageTranslations(currentLanguage, currentTranslations);
    }
    return getAllTranslations();
}

function getNonEmptyTranslations(translations) {
    const cleaned = {};
    for (const [key, value] of Object.entries(translations || {})) {
        if (typeof value === 'string' && value.trim()) {
            cleaned[key] = value;
        }
    }
    return cleaned;
}

function buildChangedTranslations(userTranslations, repoBaseline) {
    const changed = {};
    for (const [key, value] of Object.entries(userTranslations)) {
        if (repoBaseline[key] === undefined || repoBaseline[key] !== value) {
            changed[key] = value;
        }
    }
    return changed;
}

/**
 * Build deterministic submission payload by fetching repo baselines as needed.
 * @param {Object} options - Options
 * @param {string[]} options.includeLanguages - Optional language allowlist
 * @returns {Promise<Object>} Preflight payload
 */
export async function buildSubmissionPreflight(options = {}) {
    const includeLanguages = Array.isArray(options.includeLanguages)
        ? new Set(normalizeLanguageList(options.includeLanguages))
        : null;

    const saved = getSavedSnapshots();
    const result = {
        changedByLang: {},
        fullTranslationsByLang: {},
        filesPlanned: [],
        languagesIncluded: [],
        blockingIssues: [],
        warnings: []
    };

    for (const [rawCode, data] of Object.entries(saved)) {
        const langCode = normalizeLangCode(rawCode);
        if (!langCode || langCode === BASE_LANGUAGE) continue;
        if (includeLanguages && !includeLanguages.has(langCode)) continue;

        const userTranslations = getNonEmptyTranslations(data?.translations || {});
        if (Object.keys(userTranslations).length === 0) continue;

        let repoBaseline = {};
        try {
            repoBaseline = await ensureRepoBaseline(langCode);
        } catch (e) {
            result.blockingIssues.push(`Failed to load repository baseline for ${langCode}: ${e.message}`);
            continue;
        }

        const changed = buildChangedTranslations(userTranslations, repoBaseline);
        if (Object.keys(changed).length === 0) continue;

        const merged = { ...repoBaseline, ...userTranslations };
        result.changedByLang[langCode] = changed;
        result.fullTranslationsByLang[langCode] = merged;
        result.languagesIncluded.push(langCode);

        const categorized = categorizeTranslations(merged);
        for (const category of CATEGORIES) {
            const keyCount = Object.keys(categorized[category] || {}).length;
            if (keyCount === 0) continue;

            const filename = `${category}_${langCode}.txt`;
            result.filesPlanned.push({
                langCode,
                category,
                keyCount,
                filename,
                paths: {
                    build42: `${REPO_CONFIG.translationPaths.build42}/${langCode}/${filename}`,
                    build41: `${REPO_CONFIG.translationPaths.build41}/${langCode}/${filename}`
                }
            });
        }
    }

    result.languagesIncluded.sort((a, b) => a.localeCompare(b));

    if (result.languagesIncluded.length === 0) {
        result.blockingIssues.push('No changed translations found to submit.');
    }

    lastSubmissionPreflight = result;
    return result;
}

/**
 * Get last computed submission preflight payload
 * @returns {Object|null} Last payload
 */
export function getLastSubmissionPreflight() {
    return lastSubmissionPreflight;
}

/**
 * Backward-compatible helper for existing call sites
 * @returns {Object} Changed/new translations by language
 */
export function getAllSavedTranslationsForSubmission() {
    if (lastSubmissionPreflight?.changedByLang) {
        return { ...lastSubmissionPreflight.changedByLang };
    }

    const result = {};
    const saved = getSavedSnapshots();

    for (const [rawCode, data] of Object.entries(saved)) {
        const langCode = normalizeLangCode(rawCode);
        if (!langCode || langCode === BASE_LANGUAGE) continue;
        const userTranslations = getNonEmptyTranslations(data?.translations || {});
        if (Object.keys(userTranslations).length === 0) continue;

        const baseline = originalRepoTranslations[langCode] || {};
        const changed = buildChangedTranslations(userTranslations, baseline);
        if (Object.keys(changed).length > 0) {
            result[langCode] = changed;
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
    const normalized = normalizeLangCode(langCode);
    if (!normalized) return {};
    return originalRepoTranslations[normalized] || {};
}

/**
 * Backward-compatible helper for existing call sites
 * @returns {Object} Full merged translations by language code
 */
export function getFullMergedTranslationsForSubmission() {
    if (lastSubmissionPreflight?.fullTranslationsByLang) {
        return { ...lastSubmissionPreflight.fullTranslationsByLang };
    }

    const result = {};
    const saved = getSavedSnapshots();

    for (const [rawCode, data] of Object.entries(saved)) {
        const langCode = normalizeLangCode(rawCode);
        if (!langCode || langCode === BASE_LANGUAGE) continue;
        const userTranslations = getNonEmptyTranslations(data?.translations || {});
        if (Object.keys(userTranslations).length === 0) continue;

        const baseline = originalRepoTranslations[langCode] || {};
        result[langCode] = { ...baseline, ...userTranslations };
    }

    return result;
}

/**
 * Build diagnostics report for maintainer tooling and translation health UI
 * @param {Object} options - Options
 * @param {string[]} options.langCodes - Optional language subset
 * @returns {Promise<Object>} Diagnostics report
 */
export async function buildDiagnosticsReport(options = {}) {
    const langCodes = Array.isArray(options.langCodes) && options.langCodes.length > 0
        ? normalizeLanguageList(options.langCodes)
        : [...discoveredRepoLanguages];

    const report = {
        duplicateKeys: [...(lastDiagnosticsReport.duplicateKeys || [])],
        parseErrors: [...(lastDiagnosticsReport.parseErrors || [])],
        legacyItemsPresent: [...(lastDiagnosticsReport.legacyItemsPresent || [])],
        missingCategoriesByLang: { ...(lastDiagnosticsReport.missingCategoriesByLang || {}) }
    };

    // Remove old parse/missing data for refreshed languages.
    report.parseErrors = report.parseErrors.filter(entry => !langCodes.includes(entry.langCode));
    report.duplicateKeys = report.duplicateKeys.filter(entry => !langCodes.includes(entry.langCode));
    for (const langCode of langCodes) {
        delete report.missingCategoriesByLang[langCode];
    }

    for (const langCode of langCodes) {
        const result = await fetchAllCategoriesForLanguage(langCode);

        const missing = [];
        for (const category of CATEGORIES) {
            const catResult = result.categories?.[category];
            if (!catResult || catResult.status !== 'loaded') {
                missing.push(category);
            }
        }
        if (missing.length > 0) {
            report.missingCategoriesByLang[langCode] = missing;
        }

        for (const err of result.errors || []) {
            report.parseErrors.push({
                langCode,
                error: err
            });
        }

        for (const category of CATEGORIES) {
            const filename = `${category}_${langCode}.txt`;
            const path = `${REPO_CONFIG.translationPaths.build42}/${langCode}/${filename}`;
            const url = `${GITHUB_RAW_BASE}/${path}`;
            const duplicates = await detectDuplicateKeysInFile(url, langCode, category, path);
            report.duplicateKeys.push(...duplicates);
        }
    }

    // Legacy Items_XX.txt detection (read-only warning surface)
    for (const langCode of langCodes) {
        report.legacyItemsPresent = report.legacyItemsPresent.filter(item => item.langCode !== langCode);
        const legacyPath = `${REPO_CONFIG.translationPaths.build42}/${langCode}/Items_${langCode}.txt`;
        const legacyUrl = `${GITHUB_RAW_BASE}/${legacyPath}`;

        try {
            const response = await fetch(legacyUrl, { method: 'HEAD' });
            if (response.ok) {
                report.legacyItemsPresent.push({
                    langCode,
                    path: legacyPath
                });
            }
        } catch (e) {
            // Non-blocking diagnostic check
        }
    }

    lastDiagnosticsReport = report;
    return report;
}

/**
 * Get the last diagnostics report
 * @returns {Object} Diagnostics report
 */
export function getDiagnosticsReport() {
    return lastDiagnosticsReport;
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

/**
 * Get translation health for current language
 * @returns {Object} Basic local translation health metrics
 */
export function getTranslationHealth() {
    const english = englishBaseline || {};
    const current = currentTranslations || {};
    const stats = calculateCompletionStats(current, english);

    const emptyKeys = [];
    for (const key of Object.keys(english)) {
        if (!current[key] || !current[key].trim()) {
            emptyKeys.push(key);
        }
    }

    return {
        langCode: currentLanguage,
        coverage: stats,
        emptyKeyCount: emptyKeys.length
    };
}

/**
 * Validate key category distribution for arbitrary translations
 * @param {Object} translations - Flat translation key/value map
 * @returns {Object} Categorized key counts and uncategorized keys
 */
export function getTranslationCategoryDiagnostics(translations) {
    const byCategory = {};
    const uncategorized = [];

    for (const category of CATEGORIES) {
        byCategory[category] = 0;
    }

    for (const key of Object.keys(translations || {})) {
        const category = getCategoryFromKey(key);
        if (category && byCategory[category] !== undefined) {
            byCategory[category]++;
        } else {
            uncategorized.push(key);
        }
    }

    return {
        byCategory,
        uncategorized
    };
}
