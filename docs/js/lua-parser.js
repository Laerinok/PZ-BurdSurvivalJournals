/**
 * Lua Translation File Parser
 * Parses Project Zomboid translation files in Lua table format
 */

/**
 * Parse a Lua translation file and extract key-value pairs
 * @param {string} content - The raw content of the Lua translation file
 * @param {string} expectedCategory - Expected category name (e.g., 'UI', 'Sandbox')
 * @returns {Object} Object containing parsed translations and metadata
 */
export function parseLuaFile(content, expectedCategory = null) {
    const result = {
        tableName: null,
        langCode: null,
        translations: {},
        comments: [],
        errors: []
    };

    if (!content || typeof content !== 'string') {
        result.errors.push('Invalid content: expected string');
        return result;
    }

    // Match table declaration: TableName_XX = {
    const tableMatch = content.match(/^(\w+)_(\w+)\s*=\s*\{/m);
    if (!tableMatch) {
        result.errors.push('Invalid format: No table declaration found (expected format: TableName_XX = {)');
        return result;
    }

    result.tableName = tableMatch[1];
    result.langCode = tableMatch[2];

    // Validate category if expected
    if (expectedCategory && result.tableName !== expectedCategory) {
        result.errors.push(`Category mismatch: expected ${expectedCategory}, found ${result.tableName}`);
    }

    // Extract content between { and }
    const braceStart = content.indexOf('{');
    const braceEnd = content.lastIndexOf('}');

    if (braceStart === -1 || braceEnd === -1 || braceEnd <= braceStart) {
        result.errors.push('Invalid format: Could not find matching braces');
        return result;
    }

    const tableContent = content.substring(braceStart + 1, braceEnd);

    // Parse line by line
    const lines = tableContent.split('\n');

    for (let i = 0; i < lines.length; i++) {
        const line = lines[i];
        const trimmedLine = line.trim();

        // Skip empty lines
        if (!trimmedLine) continue;

        // Check for comments
        if (trimmedLine.startsWith('--')) {
            result.comments.push({
                line: i + 1,
                text: trimmedLine.substring(2).trim()
            });
            continue;
        }

        // Parse key-value pairs
        // Handle both formats:
        // Key_Name = "value",
        // Key_Name.SubName = "value",
        const kvMatch = trimmedLine.match(/^([\w.]+)\s*=\s*"((?:[^"\\]|\\.)*)"\s*,?\s*(?:--.*)?$/);

        if (kvMatch) {
            const key = kvMatch[1];
            const value = unescapeLuaString(kvMatch[2]);
            result.translations[key] = value;
        } else if (trimmedLine && !trimmedLine.startsWith('--')) {
            // Check if it's a malformed line that looks like it should be a translation
            if (trimmedLine.includes('=') && trimmedLine.includes('"')) {
                result.errors.push(`Line ${i + 1}: Could not parse: ${trimmedLine.substring(0, 50)}...`);
            }
        }
    }

    return result;
}

/**
 * Unescape Lua string escape sequences
 * @param {string} str - The escaped Lua string
 * @returns {string} The unescaped string
 */
export function unescapeLuaString(str) {
    if (!str) return '';

    return str
        .replace(/\\n/g, '\n')
        .replace(/\\r/g, '\r')
        .replace(/\\t/g, '\t')
        .replace(/\\"/g, '"')
        .replace(/\\\\/g, '\\');
}

/**
 * Escape a string for Lua format
 * @param {string} str - The raw string
 * @returns {string} The escaped string ready for Lua
 */
export function escapeLuaString(str) {
    if (!str) return '';

    return str
        .replace(/\\/g, '\\\\')
        .replace(/"/g, '\\"')
        .replace(/\n/g, '\\n')
        .replace(/\r/g, '\\r')
        .replace(/\t/g, '\\t');
}

/**
 * Generate Lua translation file content from translations object
 * @param {string} category - The category name (e.g., 'UI', 'Sandbox')
 * @param {string} langCode - The language code (e.g., 'EN', 'FR')
 * @param {Object} translations - Object with key-value translation pairs
 * @param {Object} options - Generation options
 * @returns {string} The generated Lua file content
 */
export function generateLuaFile(category, langCode, translations, options = {}) {
    const {
        includeComments = true,
        sortKeys = false,
        englishReference = null
    } = options;

    const lines = [];
    lines.push(`${category}_${langCode} = {`);

    // Get keys - either sorted or in original order
    let keys = Object.keys(translations);
    if (sortKeys) {
        keys.sort();
    } else if (englishReference) {
        // Use English key order as reference
        const englishKeys = Object.keys(englishReference);
        keys = englishKeys.filter(k => k in translations);
        // Add any new keys not in English at the end
        const newKeys = Object.keys(translations).filter(k => !englishKeys.includes(k));
        keys = [...keys, ...newKeys];
    }

    // Group keys by their prefix for better organization
    let currentGroup = '';

    for (const key of keys) {
        const value = translations[key];

        // Add group comment if prefix changes (optional)
        if (includeComments && englishReference) {
            const prefix = key.split('_').slice(0, 2).join('_');
            if (prefix !== currentGroup) {
                currentGroup = prefix;
                if (lines.length > 1) {
                    lines.push('');
                }
            }
        }

        const escapedValue = escapeLuaString(value);
        lines.push(`    ${key} = "${escapedValue}",`);
    }

    lines.push('}');
    lines.push('');

    return lines.join('\n');
}

/**
 * Validate translation value for common issues
 * @param {string} key - The translation key
 * @param {string} value - The translated value
 * @param {string} englishValue - The original English value
 * @returns {Object} Validation result with warnings array
 */
export function validateTranslation(key, value, englishValue) {
    const warnings = [];

    if (!value || !value.trim()) {
        warnings.push('Translation is empty');
        return { valid: false, warnings };
    }

    // Check for placeholder preservation
    const englishPlaceholders = extractPlaceholders(englishValue);
    const translatedPlaceholders = extractPlaceholders(value);

    // Check if all English placeholders exist in translation
    for (const ph of englishPlaceholders) {
        if (!translatedPlaceholders.includes(ph)) {
            warnings.push(`Missing placeholder: ${ph}`);
        }
    }

    // Check for extra placeholders in translation
    for (const ph of translatedPlaceholders) {
        if (!englishPlaceholders.includes(ph)) {
            warnings.push(`Extra placeholder: ${ph}`);
        }
    }

    return {
        valid: warnings.length === 0,
        warnings
    };
}

/**
 * Extract format placeholders from a string
 * @param {string} str - The string to extract placeholders from
 * @returns {string[]} Array of placeholders found
 */
export function extractPlaceholders(str) {
    if (!str) return [];

    const placeholders = [];

    // Match %s, %d, %1, %2, etc.
    const matches = str.match(/%[sd\d]/g);
    if (matches) {
        placeholders.push(...matches);
    }

    return placeholders;
}

/**
 * Get category from key name
 * @param {string} key - The translation key
 * @returns {string|null} The category or null if not recognized
 */
export function getCategoryFromKey(key) {
    if (key.startsWith('UI_')) return 'UI';
    if (key.startsWith('Sandbox_')) return 'Sandbox';
    if (key.startsWith('ContextMenu_')) return 'ContextMenu';
    if (key.startsWith('Tooltip_')) return 'Tooltip';
    if (key.startsWith('ItemName_')) return 'ItemName';
    if (
        key.startsWith('Recipes_') ||
        key.startsWith('Recipe_') ||
        key.startsWith('Bind_') ||
        key.startsWith('RestoreJournal_') ||
        key === 'EraseFilledJournal'
    ) return 'Recipes';
    if (key.startsWith('IG_UI_')) return 'IG_UI';
    return null;
}

/**
 * Categorize translations by their key prefix
 * @param {Object} translations - Flat object of all translations
 * @returns {Object} Translations organized by category
 */
export function categorizeTranslations(translations) {
    const categorized = {
        ContextMenu: {},
        IG_UI: {},
        ItemName: {},
        Recipes: {},
        Sandbox: {},
        Tooltip: {},
        UI: {}
    };

    for (const [key, value] of Object.entries(translations)) {
        const category = getCategoryFromKey(key);
        if (category && categorized[category]) {
            categorized[category][key] = value;
        }
    }

    return categorized;
}
