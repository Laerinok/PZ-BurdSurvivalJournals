/**
 * Import Utilities
 * Handles importing translations from JSON, Lua, and ZIP formats.
 */

import { parseLuaFile, validateTranslation, getCategoryFromKey } from './lua-parser.js';
import { getEnglishBaseline } from './translation-manager.js';

const TEMPLATE_SCHEMA = 'bsj-template-v1';

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

function listCategoriesForTranslations(translations) {
    const categories = new Set();
    for (const key of Object.keys(translations || {})) {
        const category = getCategoryFromKey(key);
        if (category) {
            categories.add(category);
        }
    }
    return [...categories].sort();
}

function normalizeTranslationMap(value) {
    if (!value || typeof value !== 'object' || Array.isArray(value)) {
        return {};
    }

    const normalized = {};
    for (const [key, entryValue] of Object.entries(value)) {
        if (typeof entryValue === 'string') {
            normalized[key] = entryValue;
        }
    }
    return normalized;
}

function buildLanguageMaps(input) {
    const maps = {};
    for (const [langCodeRaw, translationsRaw] of Object.entries(input || {})) {
        const langCode = normalizeLangCode(langCodeRaw);
        if (!langCode) continue;
        const normalized = normalizeTranslationMap(translationsRaw);
        if (Object.keys(normalized).length > 0) {
            maps[langCode] = normalized;
        }
    }
    return maps;
}

/**
 * Detect file type from content or filename
 * @param {string} content - File content
 * @param {string} filename - File name
 * @returns {string} File type: 'json', 'lua', 'zip', or 'unknown'
 */
export function detectFileType(content, filename = '') {
    const lowerName = filename.toLowerCase();

    if (lowerName.endsWith('.json')) return 'json';
    if (lowerName.endsWith('.txt') || lowerName.endsWith('.lua')) return 'lua';
    if (lowerName.endsWith('.zip')) return 'zip';

    const trimmed = (content || '').trim();
    if (trimmed.startsWith('{') || trimmed.startsWith('[')) {
        try {
            JSON.parse(content);
            return 'json';
        } catch (e) {
            // Not valid JSON
        }
    }

    if (/^\w+\s*=\s*\{/m.test(trimmed)) {
        return 'lua';
    }

    return 'unknown';
}

/**
 * Parse JSON translation file (legacy + template + multi-language formats)
 * @param {string} content - JSON content
 * @returns {Object} Parse result
 */
export function parseJsonTranslations(content) {
    const result = {
        success: false,
        translations: {},
        translationsByLanguage: {},
        metadata: {},
        errors: [],
        warnings: [],
        langCode: null,
        detectedLanguages: [],
        detectedCategories: []
    };

    try {
        const data = JSON.parse(content);
        const meta = data?._meta || {};
        result.metadata = meta;

        // New structured template format: bsj-template-v1
        if (meta.schema === TEMPLATE_SCHEMA && data.entries && typeof data.entries === 'object') {
            const langCode = normalizeLangCode(meta.langCode);
            const entries = data.entries;
            const translations = {};

            for (const [key, payload] of Object.entries(entries)) {
                if (payload && typeof payload.translation === 'string') {
                    translations[key] = payload.translation;
                }
            }

            if (!langCode) {
                result.errors.push('Template is missing _meta.langCode');
                return result;
            }

            result.langCode = langCode;
            result.translations = translations;
            result.translationsByLanguage = { [langCode]: translations };
            result.detectedLanguages = [langCode];
            result.detectedCategories = listCategoriesForTranslations(translations);
            result.success = true;
            return result;
        }

        // Single-language structure: { _meta, translations: { key: value } }
        if (data.translations && typeof data.translations === 'object' && !Array.isArray(data.translations)) {
            const translations = normalizeTranslationMap(data.translations);
            const langCode = normalizeLangCode(meta.langCode || data.langCode);

            if (!langCode) {
                result.errors.push('Single-language JSON is missing langCode');
                return result;
            }

            result.langCode = langCode;
            result.translations = translations;
            result.translationsByLanguage = { [langCode]: translations };
            result.detectedLanguages = [langCode];
            result.detectedCategories = listCategoriesForTranslations(translations);
            result.success = true;
            return result;
        }

        // Multi-language structure: { _meta, languages: { EN: {...}, FR: {...} } }
        if (data.languages && typeof data.languages === 'object') {
            const translationsByLanguage = buildLanguageMaps(data.languages);
            result.translationsByLanguage = translationsByLanguage;
            result.detectedLanguages = Object.keys(translationsByLanguage);
            result.detectedCategories = [...new Set(
                Object.values(translationsByLanguage)
                    .flatMap(listCategoriesForTranslations)
            )].sort();

            if (result.detectedLanguages.length === 0) {
                result.errors.push('No valid language entries found in "languages" object');
                return result;
            }

            if (result.detectedLanguages.length === 1) {
                result.langCode = result.detectedLanguages[0];
                result.translations = translationsByLanguage[result.langCode];
            }

            result.success = true;
            return result;
        }

        // Legacy flat format: { key: "value", key2: "value2", ... }
        if (typeof data === 'object' && !Array.isArray(data)) {
            const translations = {};
            for (const [key, value] of Object.entries(data)) {
                if (!key.startsWith('_') && typeof value === 'string') {
                    translations[key] = value;
                }
            }

            const langCode = normalizeLangCode(data.langCode || meta.langCode);
            if (!langCode) {
                result.errors.push('Legacy JSON is missing langCode');
                return result;
            }

            result.langCode = langCode;
            result.translations = translations;
            result.translationsByLanguage = { [langCode]: translations };
            result.detectedLanguages = [langCode];
            result.detectedCategories = listCategoriesForTranslations(translations);
            result.success = true;
            return result;
        }

        result.errors.push('Invalid JSON structure');
    } catch (error) {
        result.errors.push(`JSON parse error: ${error.message}`);
    }

    return result;
}

/**
 * Parse Lua translation file
 * @param {string} content - Lua file content
 * @param {string} filename - Original filename for category detection
 * @returns {Object} Parse result
 */
export function parseLuaTranslations(content, filename = '') {
    let expectedCategory = null;
    const match = filename.match(/^(\w+)_\w+\.txt$/i);
    if (match) {
        expectedCategory = match[1];
    }

    const parsed = parseLuaFile(content, expectedCategory);
    const langCode = normalizeLangCode(parsed.langCode);

    return {
        success: parsed.errors.length === 0 || Object.keys(parsed.translations).length > 0,
        translations: parsed.translations,
        translationsByLanguage: langCode ? { [langCode]: parsed.translations } : {},
        langCode,
        detectedLanguages: langCode ? [langCode] : [],
        detectedCategories: parsed.tableName ? [parsed.tableName] : [],
        category: parsed.tableName,
        errors: parsed.errors,
        warnings: parsed.errors.length > 0 && Object.keys(parsed.translations).length > 0
            ? [`${filename || 'Lua file'} has parse warnings`]
            : []
    };
}

/**
 * Parse ZIP file containing translations
 * @param {File|Blob} file - ZIP file
 * @returns {Promise<Object>} Parse result
 */
export async function parseZipTranslations(file) {
    const result = {
        success: false,
        translations: {},
        translationsByLanguage: {},
        files: [],
        langCode: null,
        detectedLanguages: [],
        detectedCategories: [],
        errors: [],
        warnings: [],
        blockingIssues: []
    };

    if (typeof JSZip === 'undefined') {
        result.errors.push('JSZip library not loaded');
        return result;
    }

    try {
        const zip = await JSZip.loadAsync(file);
        const txtFiles = [];

        zip.forEach((relativePath, zipEntry) => {
            if (!zipEntry.dir && relativePath.toLowerCase().endsWith('.txt')) {
                txtFiles.push({ path: relativePath, entry: zipEntry });
            }
        });

        if (txtFiles.length === 0) {
            result.errors.push('No translation files (.txt) found in ZIP');
            return result;
        }

        const languages = new Set();
        const categories = new Set();
        const translationsByLanguage = {};

        for (const { path, entry } of txtFiles) {
            try {
                const buffer = await entry.async('arraybuffer');
                const content = decodeWithCorrectEncoding(buffer);
                const filename = path.split('/').pop() || path;
                const parsed = parseLuaTranslations(content, filename);

                if (!parsed.success) {
                    result.errors.push(`${path}: ${parsed.errors.join(', ')}`);
                    continue;
                }

                const langCode = parsed.langCode;
                if (!langCode) {
                    result.errors.push(`${path}: Missing or invalid language code in table name`);
                    continue;
                }

                languages.add(langCode);
                if (parsed.category) {
                    categories.add(parsed.category);
                }

                if (!translationsByLanguage[langCode]) {
                    translationsByLanguage[langCode] = {};
                }
                Object.assign(translationsByLanguage[langCode], parsed.translations);

                result.files.push({
                    path,
                    category: parsed.category,
                    langCode,
                    keyCount: Object.keys(parsed.translations).length
                });

                for (const warning of parsed.warnings || []) {
                    result.warnings.push(`${path}: ${warning}`);
                }
            } catch (e) {
                result.errors.push(`Failed to read ${path}: ${e.message}`);
            }
        }

        result.detectedLanguages = [...languages].sort();
        result.detectedCategories = [...categories].sort();
        result.translationsByLanguage = translationsByLanguage;

        if (result.detectedLanguages.length > 1) {
            result.blockingIssues.push(
                `ZIP contains multiple languages (${result.detectedLanguages.join(', ')}). Import one language per ZIP.`
            );
        } else if (result.detectedLanguages.length === 1) {
            result.langCode = result.detectedLanguages[0];
            result.translations = translationsByLanguage[result.langCode] || {};
        }

        const hasTranslations = Object.keys(translationsByLanguage).length > 0;
        result.success = hasTranslations && result.errors.length === 0;
    } catch (error) {
        result.errors.push(`ZIP error: ${error.message}`);
    }

    return result;
}

/**
 * Import from file input
 * @param {File} file - File object from input
 * @returns {Promise<Object>} Import result
 */
export async function importFromFile(file) {
    const result = {
        success: false,
        translations: {},
        translationsByLanguage: {},
        langCode: null,
        format: 'unknown',
        errors: [],
        warnings: [],
        blockingIssues: [],
        detectedLanguages: [],
        detectedCategories: []
    };

    const filename = file.name;

    if (filename.toLowerCase().endsWith('.zip')) {
        const zipResult = await parseZipTranslations(file);
        result.format = 'zip';
        Object.assign(result, zipResult, { format: 'zip' });
        return result;
    }

    const content = await readFileAsText(file);
    const fileType = detectFileType(content, filename);
    result.format = fileType;

    if (fileType === 'json') {
        const jsonResult = parseJsonTranslations(content);
        Object.assign(result, jsonResult, { format: 'json' });
    } else if (fileType === 'lua') {
        const luaResult = parseLuaTranslations(content, filename);
        result.translations = luaResult.translations;
        result.translationsByLanguage = luaResult.translationsByLanguage;
        result.langCode = luaResult.langCode;
        result.detectedLanguages = luaResult.detectedLanguages;
        result.detectedCategories = luaResult.detectedCategories;
        result.success = luaResult.success;
        result.errors = luaResult.errors;
        result.warnings = luaResult.warnings;
    } else {
        result.errors.push('Unknown file format');
    }

    if (result.success && result.detectedLanguages.length === 0) {
        result.warnings.push('Could not detect language code from import payload.');
    }

    return result;
}

/**
 * Read file as text with default browser decoding
 * @param {File} file - File object
 * @returns {Promise<string>} File content
 */
function readFileAsText(file) {
    return new Promise((resolve, reject) => {
        const reader = new FileReader();
        reader.onload = () => resolve(reader.result);
        reader.onerror = () => reject(reader.error);
        reader.readAsText(file);
    });
}

/**
 * Validate imported translations against English baseline
 * @param {Object} translations - Imported translations
 * @param {Object} options - Validation options
 * @returns {Object} Validation result
 */
export function validateImportedTranslations(translations, options = {}) {
    const english = getEnglishBaseline();
    const englishKeys = Object.keys(english);
    const importedKeys = Object.keys(translations || {});
    const blockOnPlaceholderIssues = options.blockOnPlaceholderIssues !== false;

    const result = {
        valid: [],
        warnings: [],
        missing: [],
        extra: [],
        placeholderIssues: [],
        blockingIssues: []
    };

    for (const key of importedKeys) {
        if (englishKeys.includes(key)) {
            const validation = validateTranslation(key, translations[key], english[key]);
            if (validation.valid) {
                result.valid.push(key);
            } else {
                result.placeholderIssues.push({
                    key,
                    warnings: validation.warnings
                });
            }
        } else {
            result.extra.push(key);
        }
    }

    for (const key of englishKeys) {
        if (!importedKeys.includes(key)) {
            result.missing.push(key);
        }
    }

    if (result.placeholderIssues.length > 0 && blockOnPlaceholderIssues) {
        result.blockingIssues.push(
            `${result.placeholderIssues.length} keys have placeholder mismatches.`
        );
    }

    return result;
}

/**
 * Validate all languages from an import result
 * @param {Object} importResult - Result from importFromFile
 * @param {Object} options - Validation options
 * @returns {Object} Validation-by-language report
 */
export function validateImportByLanguage(importResult, options = {}) {
    const report = {
        byLanguage: {},
        blockingIssues: [],
        warnings: []
    };

    const maps = importResult.translationsByLanguage || {};
    for (const [langCode, translations] of Object.entries(maps)) {
        const validation = validateImportedTranslations(translations, options);
        report.byLanguage[langCode] = validation;

        for (const issue of validation.blockingIssues) {
            report.blockingIssues.push(`${langCode}: ${issue}`);
        }
        if (validation.extra.length > 0) {
            report.warnings.push(`${langCode}: ${validation.extra.length} unknown keys will be ignored.`);
        }
    }

    return report;
}

/**
 * Merge imported translations with existing
 * @param {Object} existing - Existing translations
 * @param {Object} imported - Imported translations
 * @param {string} mode - Merge mode: 'overwrite', 'skip', 'fill'
 * @returns {Object} Merged translations
 */
export function mergeTranslations(existing, imported, mode = 'fill') {
    const merged = { ...existing };

    for (const [key, value] of Object.entries(imported || {})) {
        switch (mode) {
            case 'overwrite':
                merged[key] = value;
                break;
            case 'skip':
                if (!(key in merged)) {
                    merged[key] = value;
                }
                break;
            case 'fill':
            default:
                if (!(key in merged) || !merged[key] || !merged[key].trim()) {
                    merged[key] = value;
                }
                break;
        }
    }

    return merged;
}

/**
 * Create a file input and trigger it
 * @param {string} accept - Accepted file types
 * @param {boolean} multiple - Allow multiple files
 * @returns {Promise<FileList>} Selected files
 */
export function openFileDialog(accept = '.json,.txt,.zip', multiple = false) {
    return new Promise((resolve) => {
        const input = document.createElement('input');
        input.type = 'file';
        input.accept = accept;
        input.multiple = multiple;

        input.onchange = () => resolve(input.files);
        input.click();
    });
}

/**
 * Handle drag and drop file import
 * @param {DragEvent} event - Drag event
 * @returns {Promise<Object[]>} Array of import results
 */
export async function handleDrop(event) {
    event.preventDefault();

    const files = event.dataTransfer?.files;
    if (!files || files.length === 0) {
        return [];
    }

    const results = [];
    for (const file of files) {
        const result = await importFromFile(file);
        result.filename = file.name;
        results.push(result);
    }

    return results;
}

/**
 * Get import summary for UI display
 * @param {Object} importResult - Result from importFromFile
 * @param {Object} validationResult - Result from validateImportedTranslations or validateImportByLanguage
 * @returns {Object} Summary for display
 */
export function getImportSummary(importResult, validationResult) {
    const detectedLanguages = importResult.detectedLanguages || [];
    const totalKeys = Object.values(importResult.translationsByLanguage || {})
        .reduce((sum, map) => sum + Object.keys(map).length, 0);

    return {
        format: importResult.format,
        langCode: importResult.langCode,
        detectedLanguages,
        detectedCategories: importResult.detectedCategories || [],
        totalKeys,
        hasErrors: (importResult.errors || []).length > 0,
        hasBlockingIssues: (importResult.blockingIssues || []).length > 0 ||
            (validationResult?.blockingIssues || []).length > 0,
        errors: importResult.errors || [],
        warnings: [
            ...(importResult.warnings || []),
            ...(validationResult?.warnings || [])
        ],
        blockingIssues: [
            ...(importResult.blockingIssues || []),
            ...(validationResult?.blockingIssues || [])
        ]
    };
}
