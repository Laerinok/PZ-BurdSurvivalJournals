/**
 * Export Utilities
 * Handles exporting translations in various formats
 */

import { CATEGORIES, EXPORT_PATHS, MOD_FOLDER_NAME, TOOL_VERSION } from './config.js';
import { generateLuaFile, categorizeTranslations, getCategoryFromKey, extractPlaceholders } from './lua-parser.js';
import { getEnglishBaseline, getCurrentLanguage, getCurrentTranslations } from './translation-manager.js';

/**
 * Generate Lua file content for a category
 * @param {string} category - Category name
 * @param {string} langCode - Language code
 * @param {Object} translations - All translations
 * @returns {string} Lua file content
 */
export function generateCategoryFile(category, langCode, translations) {
    const categorized = categorizeTranslations(translations);
    const categoryTranslations = categorized[category] || {};

    // Get English reference for ordering
    const englishBaseline = getEnglishBaseline();
    const englishCategorized = categorizeTranslations(englishBaseline);
    const englishReference = englishCategorized[category];

    return generateLuaFile(category, langCode, categoryTranslations, {
        includeComments: true,
        englishReference
    });
}

/**
 * Generate all category files for a language
 * @param {string} langCode - Language code
 * @param {Object} translations - All translations
 * @returns {Object} Object with category names as keys, file contents as values
 */
export function generateAllCategoryFiles(langCode, translations) {
    const files = {};

    for (const category of CATEGORIES) {
        const filename = `${category}_${langCode}.txt`;
        const content = generateCategoryFile(category, langCode, translations);
        files[filename] = content;
    }

    return files;
}

/**
 * Download a single file
 * @param {string} filename - File name
 * @param {string} content - File content
 * @param {string} mimeType - MIME type
 */
export function downloadFile(filename, content, mimeType = 'text/plain') {
    const blob = new Blob([content], { type: mimeType });
    const url = URL.createObjectURL(blob);

    const a = document.createElement('a');
    a.href = url;
    a.download = filename;
    document.body.appendChild(a);
    a.click();
    document.body.removeChild(a);

    URL.revokeObjectURL(url);
}

/**
 * Download a single category file
 * @param {string} category - Category name
 * @param {string} langCode - Language code (defaults to current)
 * @param {Object} translations - Translations (defaults to current)
 */
export function downloadCategoryFile(category, langCode = null, translations = null) {
    langCode = langCode || getCurrentLanguage();
    translations = translations || getCurrentTranslations();

    const content = generateCategoryFile(category, langCode, translations);
    const filename = `${category}_${langCode}.txt`;

    downloadFile(filename, content);
}

/**
 * Download selected category files
 * @param {string[]} categories - Array of category names
 * @param {string} langCode - Language code
 * @param {Object} translations - Translations
 */
export function downloadSelectedCategories(categories, langCode = null, translations = null) {
    langCode = langCode || getCurrentLanguage();
    translations = translations || getCurrentTranslations();

    for (const category of categories) {
        downloadCategoryFile(category, langCode, translations);
    }
}

/**
 * Generate mod-ready ZIP file with folder structure
 * @param {string} langCode - Language code
 * @param {Object} translations - Translations
 * @returns {Promise<Blob>} ZIP file blob
 */
export async function generateModReadyZip(langCode, translations = null) {
    translations = translations || getCurrentTranslations();

    // Check if JSZip is available
    if (typeof JSZip === 'undefined') {
        throw new Error('JSZip library not loaded');
    }

    const zip = new JSZip();
    const files = generateAllCategoryFiles(langCode, translations);

    // Add files for Build 42
    const build42Path = `${EXPORT_PATHS.build42}/${langCode}`;
    for (const [filename, content] of Object.entries(files)) {
        zip.file(`${build42Path}/${filename}`, content);
    }

    // Add files for Build 41 (common)
    const build41Path = `${EXPORT_PATHS.build41}/${langCode}`;
    for (const [filename, content] of Object.entries(files)) {
        zip.file(`${build41Path}/${filename}`, content);
    }

    // Add a README
    const readme = generateReadme(langCode);
    zip.file('README.txt', readme);

    return await zip.generateAsync({ type: 'blob' });
}

/**
 * Download mod-ready ZIP file
 * @param {string} langCode - Language code
 * @param {Object} translations - Translations
 */
export async function downloadModReadyZip(langCode = null, translations = null) {
    langCode = langCode || getCurrentLanguage();

    try {
        const blob = await generateModReadyZip(langCode, translations);
        const filename = `BurdSurvivalJournals_Translation_${langCode}.zip`;
        downloadFile(filename, blob, 'application/zip');
    } catch (error) {
        console.error('Failed to generate ZIP:', error);
        throw error;
    }
}

/**
 * Generate README for ZIP
 * @param {string} langCode - Language code
 * @returns {string} README content
 */
function generateReadme(langCode) {
    return `Burd's Survival Journals - ${langCode} Translation
================================================

Generated by Translation Tool v${TOOL_VERSION}
Date: ${new Date().toISOString()}

INSTALLATION:
-------------
1. Extract this ZIP file
2. Copy the "Contents" folder to your Project Zomboid mods directory
3. The files will be automatically merged with the mod

LOCATION OPTIONS:
-----------------
Option A - Workshop Mod (Recommended):
  Steam/steamapps/workshop/content/108600/[mod-id]/

Option B - Local Mod:
  %UserProfile%/Zomboid/mods/BurdSurvivalJournals42/

FOLDER STRUCTURE:
-----------------
This ZIP contains translations for both:
- Build 42+ (42/ folder)
- Build 41 (common/ folder)

CONTRIBUTING:
-------------
To contribute your translation to the official mod, visit:
https://github.com/TheBurd/PZ-BurdSurvivalJournals

Thank you for helping translate Burd's Survival Journals!
`;
}

/**
 * Export translations as JSON backup
 * @param {string} langCode - Language code
 * @param {Object} translations - Translations
 * @returns {string} JSON string
 */
export function exportAsJson(langCode = null, translations = null) {
    langCode = langCode || getCurrentLanguage();
    translations = translations || getCurrentTranslations();

    const exportData = {
        _meta: {
            name: "Burd's Survival Journals Translation",
            version: TOOL_VERSION,
            langCode,
            exportedAt: new Date().toISOString(),
            keyCount: Object.keys(translations).length
        },
        translations
    };

    return JSON.stringify(exportData, null, 2);
}

/**
 * Download JSON backup
 * @param {string} langCode - Language code
 * @param {Object} translations - Translations
 */
export function downloadJsonBackup(langCode = null, translations = null) {
    langCode = langCode || getCurrentLanguage();
    const json = exportAsJson(langCode, translations);
    const filename = `BSJ_Translation_${langCode}_${Date.now()}.json`;
    downloadFile(filename, json, 'application/json');
}

/**
 * Export template format for manual/local/LLM workflows
 * Schema: bsj-template-v1
 * @param {string} langCode - Language code
 * @param {Object} translations - Current translations
 * @returns {string} JSON string
 */
export function exportTemplate(langCode = null, translations = null) {
    langCode = langCode || getCurrentLanguage();
    translations = translations || getCurrentTranslations();
    const english = getEnglishBaseline();

    const entries = {};
    for (const [key, englishValue] of Object.entries(english)) {
        entries[key] = {
            english: englishValue,
            translation: translations[key] || '',
            category: getCategoryFromKey(key),
            placeholders: extractPlaceholders(englishValue)
        };
    }

    const data = {
        _meta: {
            schema: 'bsj-template-v1',
            name: "Burd's Survival Journals Translation Template",
            version: TOOL_VERSION,
            langCode,
            exportedAt: new Date().toISOString(),
            keyCount: Object.keys(entries).length
        },
        entries
    };

    return JSON.stringify(data, null, 2);
}

/**
 * Download bsj-template-v1 template
 * @param {string} langCode - Language code
 * @param {Object} translations - Current translations
 */
export function downloadTemplate(langCode = null, translations = null) {
    langCode = langCode || getCurrentLanguage();
    const json = exportTemplate(langCode, translations);
    const filename = `BSJ_Template_${langCode}.json`;
    downloadFile(filename, json, 'application/json');
}

/**
 * Export LLM translation pack with strict rules and context metadata
 * @param {string} langCode - Language code
 * @param {Object} translations - Current translations
 * @returns {string} JSON string
 */
export function exportLLMPack(langCode = null, translations = null) {
    langCode = langCode || getCurrentLanguage();
    translations = translations || getCurrentTranslations();
    const english = getEnglishBaseline();

    const entries = {};
    for (const [key, englishValue] of Object.entries(english)) {
        entries[key] = {
            english: englishValue,
            translation: translations[key] || '',
            category: getCategoryFromKey(key),
            placeholders: extractPlaceholders(englishValue),
            constraints: {
                preservePlaceholders: true,
                preserveEscapes: true,
                keepKeyUnchanged: true
            }
        };
    }

    const data = {
        _meta: {
            schema: 'bsj-template-v1',
            packType: 'llm-translation-pack',
            name: "Burd's Survival Journals LLM Translation Pack",
            version: TOOL_VERSION,
            langCode,
            exportedAt: new Date().toISOString(),
            instructions: [
                'Translate only the "translation" field values.',
                'Do not modify keys.',
                'Preserve placeholders exactly (%s, %d, %1, etc.).',
                'Preserve escaped sequences such as \\n.',
                'Keep translation semantically aligned to game UI context.'
            ]
        },
        entries
    };

    return JSON.stringify(data, null, 2);
}

/**
 * Download LLM translation pack
 * @param {string} langCode - Language code
 * @param {Object} translations - Current translations
 */
export function downloadLLMPack(langCode = null, translations = null) {
    langCode = langCode || getCurrentLanguage();
    const json = exportLLMPack(langCode, translations);
    const filename = `BSJ_LLM_Pack_${langCode}.json`;
    downloadFile(filename, json, 'application/json');
}

/**
 * Export multiple languages as a single JSON backup
 * @param {Object} translationsByLang - Object with langCode keys and translations values
 * @returns {string} JSON string
 */
export function exportMultipleLanguagesAsJson(translationsByLang) {
    const exportData = {
        _meta: {
            name: "Burd's Survival Journals Multi-Language Translation",
            version: TOOL_VERSION,
            exportedAt: new Date().toISOString(),
            languages: Object.keys(translationsByLang)
        },
        languages: translationsByLang
    };

    return JSON.stringify(exportData, null, 2);
}

/**
 * Download multi-language JSON backup
 * @param {Object} translationsByLang - Translations by language
 */
export function downloadMultiLanguageBackup(translationsByLang) {
    const json = exportMultipleLanguagesAsJson(translationsByLang);
    const filename = `BSJ_Translations_Multi_${Date.now()}.json`;
    downloadFile(filename, json, 'application/json');
}

/**
 * Copy content to clipboard
 * @param {string} content - Content to copy
 * @returns {Promise<boolean>} True if successful
 */
export async function copyToClipboard(content) {
    try {
        await navigator.clipboard.writeText(content);
        return true;
    } catch (error) {
        console.error('Failed to copy to clipboard:', error);

        // Fallback for older browsers
        try {
            const textarea = document.createElement('textarea');
            textarea.value = content;
            textarea.style.position = 'fixed';
            textarea.style.opacity = '0';
            document.body.appendChild(textarea);
            textarea.select();
            document.execCommand('copy');
            document.body.removeChild(textarea);
            return true;
        } catch (e) {
            return false;
        }
    }
}

/**
 * Copy category file content to clipboard
 * @param {string} category - Category name
 * @param {string} langCode - Language code
 * @param {Object} translations - Translations
 * @returns {Promise<boolean>} True if successful
 */
export async function copyCategoryToClipboard(category, langCode = null, translations = null) {
    langCode = langCode || getCurrentLanguage();
    translations = translations || getCurrentTranslations();

    const content = generateCategoryFile(category, langCode, translations);
    return await copyToClipboard(content);
}

/**
 * Get export statistics
 * @param {Object} translations - Translations
 * @returns {Object} Export stats
 */
export function getExportStats(translations = null) {
    translations = translations || getCurrentTranslations();
    const categorized = categorizeTranslations(translations);

    const stats = {
        total: Object.keys(translations).length,
        byCategory: {}
    };

    for (const category of CATEGORIES) {
        stats.byCategory[category] = Object.keys(categorized[category] || {}).length;
    }

    return stats;
}
