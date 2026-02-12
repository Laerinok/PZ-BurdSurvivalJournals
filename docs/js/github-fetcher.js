/**
 * GitHub Raw Content Fetcher
 * Fetches translation files from GitHub repository
 */

import { REPO_CONFIG, CATEGORIES, getRawUrl, GITHUB_RAW_BASE } from './config.js';
import { parseLuaFile } from './lua-parser.js';

/**
 * Detect encoding from byte array and decode appropriately
 * @param {ArrayBuffer} buffer - Raw file data
 * @returns {string} Decoded text content
 */
function decodeWithCorrectEncoding(buffer) {
    const bytes = new Uint8Array(buffer);
    let decoded;

    // Check for UTF-16 LE BOM (FF FE)
    if (bytes.length >= 2 && bytes[0] === 0xFF && bytes[1] === 0xFE) {
        const decoder = new TextDecoder('utf-16le');
        decoded = decoder.decode(buffer);
    }
    // Check for UTF-16 BE BOM (FE FF)
    else if (bytes.length >= 2 && bytes[0] === 0xFE && bytes[1] === 0xFF) {
        const decoder = new TextDecoder('utf-16be');
        decoded = decoder.decode(buffer);
    }
    // Check for UTF-8 BOM (EF BB BF)
    else if (bytes.length >= 3 && bytes[0] === 0xEF && bytes[1] === 0xBB && bytes[2] === 0xBF) {
        const decoder = new TextDecoder('utf-8');
        decoded = decoder.decode(buffer);
    }
    // Default to UTF-8
    else {
        const decoder = new TextDecoder('utf-8');
        decoded = decoder.decode(buffer);
    }

    // Strip BOM character if present in decoded string (U+FEFF)
    if (decoded.charCodeAt(0) === 0xFEFF) {
        decoded = decoded.substring(1);
    }

    return decoded;
}

/**
 * Fetch a single translation file from GitHub
 * @param {string} langCode - Language code (e.g., 'EN', 'FR')
 * @param {string} category - Category name (e.g., 'UI', 'Sandbox')
 * @param {string} build - Build target ('build42' or 'build41')
 * @returns {Promise<Object>} Parsed translations or error object
 */
export async function fetchTranslationFile(langCode, category, build = 'build42') {
    const url = getRawUrl(langCode, category, build);

    try {
        const response = await fetch(url);

        if (!response.ok) {
            if (response.status === 404) {
                return {
                    success: false,
                    error: 'File not found',
                    code: 404,
                    langCode,
                    category
                };
            }
            throw new Error(`HTTP ${response.status}: ${response.statusText}`);
        }

        // Get as ArrayBuffer to detect encoding
        const buffer = await response.arrayBuffer();
        const content = decodeWithCorrectEncoding(buffer);

        const parsed = parseLuaFile(content, category);

        if (parsed.errors.length > 0) {
            console.warn(`Parse warnings for ${category}_${langCode}:`, parsed.errors);
        }

        return {
            success: true,
            langCode,
            category,
            translations: parsed.translations,
            keyCount: Object.keys(parsed.translations).length
        };
    } catch (error) {
        console.error(`Failed to fetch ${category}_${langCode}:`, error);
        return {
            success: false,
            error: error.message,
            langCode,
            category
        };
    }
}

/**
 * Fetch all translation files for a language
 * @param {string} langCode - Language code
 * @param {Function} onProgress - Progress callback (category, index, total)
 * @returns {Promise<Object>} Object with all translations by category
 */
export async function fetchAllCategoriesForLanguage(langCode, onProgress = null) {
    const results = {
        langCode,
        translations: {},
        categories: {},
        errors: [],
        totalKeys: 0
    };

    for (let i = 0; i < CATEGORIES.length; i++) {
        const category = CATEGORIES[i];

        if (onProgress) {
            onProgress(category, i, CATEGORIES.length);
        }

        const result = await fetchTranslationFile(langCode, category);

        if (result.success) {
            results.categories[category] = {
                keyCount: result.keyCount,
                status: 'loaded'
            };

            // Merge translations
            Object.assign(results.translations, result.translations);
            results.totalKeys += result.keyCount;
        } else {
            results.categories[category] = {
                keyCount: 0,
                status: 'error',
                error: result.error
            };
            results.errors.push(`${category}: ${result.error}`);
        }
    }

    return results;
}

/**
 * Fetch English baseline translations
 * @param {Function} onProgress - Progress callback
 * @returns {Promise<Object>} English translations
 */
export async function fetchEnglishBaseline(onProgress = null) {
    return await fetchAllCategoriesForLanguage('EN', onProgress);
}

/**
 * Check if a language exists in the repository
 * @param {string} langCode - Language code to check
 * @returns {Promise<boolean>} True if the language exists
 */
export async function checkLanguageExists(langCode) {
    // Try to fetch the UI file as a quick check
    const result = await fetchTranslationFile(langCode, 'UI');
    return result.success;
}

/**
 * Discover available languages by querying GitHub API
 * This dynamically finds which language folders exist in the repo
 * @returns {Promise<string[]>} Array of language codes found in repo
 */
export async function discoverRepoLanguages() {
    const apiUrl = `https://api.github.com/repos/${REPO_CONFIG.owner}/${REPO_CONFIG.repo}/contents/${REPO_CONFIG.translationPaths.build42}`;

    try {
        const response = await fetch(apiUrl, {
            headers: {
                'Accept': 'application/vnd.github.v3+json'
            }
        });

        if (!response.ok) {
            console.warn('Failed to discover languages from GitHub API:', response.status);
            return null;
        }

        const contents = await response.json();

        // Filter for directories only (language folders)
        const languageFolders = contents
            .filter(item => item.type === 'dir')
            .map(item => item.name)
            .filter(name => /^[A-Z]{2,4}$/.test(name)); // Valid language codes: 2-4 uppercase letters

        console.log('Discovered languages in repo:', languageFolders);
        return languageFolders;
    } catch (error) {
        console.error('Error discovering languages:', error);
        return null;
    }
}

/**
 * Fetch the languages.json manifest
 * @returns {Promise<Object>} Parsed manifest or null on error
 */
export async function fetchLanguageManifest() {
    try {
        // First try to fetch from local (for development)
        const localResponse = await fetch('languages.json');
        if (localResponse.ok) {
            return await localResponse.json();
        }
    } catch (e) {
        // Local fetch failed, try from GitHub
    }

    try {
        const url = `${GITHUB_RAW_BASE}/docs/languages.json`;
        const response = await fetch(url);
        if (response.ok) {
            return await response.json();
        }
    } catch (e) {
        console.error('Failed to fetch language manifest:', e);
    }

    return null;
}

/**
 * Fetch multiple languages in parallel
 * @param {string[]} langCodes - Array of language codes
 * @param {Function} onProgress - Progress callback (langCode, completed, total)
 * @returns {Promise<Object>} Object with translations by language code
 */
export async function fetchMultipleLanguages(langCodes, onProgress = null) {
    const results = {};
    let completed = 0;

    const promises = langCodes.map(async (langCode) => {
        const result = await fetchAllCategoriesForLanguage(langCode);
        completed++;

        if (onProgress) {
            onProgress(langCode, completed, langCodes.length);
        }

        results[langCode] = result;
        return result;
    });

    await Promise.all(promises);
    return results;
}

/**
 * Calculate completion percentage for a language
 * @param {Object} languageTranslations - Translations for the language
 * @param {Object} englishTranslations - English baseline translations
 * @returns {Object} Completion stats
 */
export function calculateCompletionStats(languageTranslations, englishTranslations) {
    const englishKeys = Object.keys(englishTranslations);
    const translatedKeys = Object.keys(languageTranslations);

    let translated = 0;
    let empty = 0;
    let missing = 0;

    for (const key of englishKeys) {
        if (key in languageTranslations) {
            const value = languageTranslations[key];
            if (value && value.trim()) {
                translated++;
            } else {
                empty++;
            }
        } else {
            missing++;
        }
    }

    const total = englishKeys.length;
    const percentage = total > 0 ? Math.round((translated / total) * 100) : 0;

    return {
        total,
        translated,
        empty,
        missing,
        percentage
    };
}

/**
 * Get completion stats by category
 * @param {Object} languageTranslations - All translations for the language
 * @param {Object} englishTranslations - English baseline translations
 * @returns {Object} Stats by category
 */
export function getCompletionByCategory(languageTranslations, englishTranslations) {
    const stats = {};

    for (const category of CATEGORIES) {
        const prefix = category + '_';
        const altPrefix = category === 'Recipes' ? 'Recipe_' : null;
        const recipePrefixes = category === 'Recipes' ? ['Bind_', 'RestoreJournal_'] : null;
        const recipeSingleKeys = category === 'Recipes' ? ['EraseFilledJournal'] : null;
        const itemNamePrefix = category === 'ItemName' ? 'ItemName_' : null;

        const englishCategoryKeys = Object.keys(englishTranslations).filter(k => {
            if (k.startsWith(prefix)) return true;
            if (altPrefix && k.startsWith(altPrefix)) return true;
            if (recipePrefixes && recipePrefixes.some(p => k.startsWith(p))) return true;
            if (recipeSingleKeys && recipeSingleKeys.includes(k)) return true;
            if (itemNamePrefix && k.startsWith(itemNamePrefix)) return true;
            return false;
        });

        const languageCategoryTranslations = {};
        for (const key of englishCategoryKeys) {
            if (key in languageTranslations) {
                languageCategoryTranslations[key] = languageTranslations[key];
            }
        }

        const englishCategoryObj = {};
        for (const key of englishCategoryKeys) {
            englishCategoryObj[key] = englishTranslations[key];
        }

        stats[category] = calculateCompletionStats(languageCategoryTranslations, englishCategoryObj);
    }

    return stats;
}
