/**
 * UI Controller
 * Handles all UI rendering and user interactions
 */

import { CATEGORIES } from './config.js';
import {
    initialize,
    on,
    getEnglishBaseline,
    getCurrentLanguage,
    getCurrentTranslations,
    switchLanguage,
    updateTranslation,
    getCompletionStats,
    getCategoryStats,
    getAvailableLanguages,
    getZomboidLanguages,
    getAllLanguages,
    getLanguagesWithLocalWork,
    isLanguageInRepo,
    getAllSavedTranslationsForSubmission,
    getFullMergedTranslationsForSubmission,
    forceSave
} from './translation-manager.js';
import {
    downloadCategoryFile,
    downloadModReadyZip,
    downloadJsonBackup,
    copyCategoryToClipboard,
    getExportStats
} from './export-utils.js';
import {
    importFromFile,
    validateImportedTranslations,
    mergeTranslations,
    openFileDialog
} from './import-utils.js';
import {
    startOAuthFlow,
    isOAuthCallback,
    handleOAuthCallback,
    getAuthStatus,
    logout,
    getGitHubUser,
    isGitHubAuthenticated
} from './github-auth.js';
import { submitTranslationsPR, canSubmitPR, generatePRTitle, generatePRBody } from './github-pr.js';
import { extractPlaceholders } from './lua-parser.js';
import { getSavedLanguages, deleteLanguageTranslations } from './storage-manager.js';

// UI State
let currentCategory = 'all';
let filterMode = 'all'; // 'all', 'empty', 'filled'
let searchQuery = '';
let githubUser = null;

// DOM Elements cache
const elements = {};

/**
 * Initialize UI
 */
export async function initUI() {
    // Cache DOM elements
    cacheElements();

    // Set up event listeners
    setupEventListeners();

    // Check for OAuth callback
    if (isOAuthCallback()) {
        showLoadingOverlay('Completing GitHub login...');
        const result = await handleOAuthCallback();
        if (result.success) {
            showNotification('Successfully connected to GitHub!', 'success');
            githubUser = await getGitHubUser();
        } else {
            showNotification(`GitHub login failed: ${result.description}`, 'error');
        }
        hideLoadingOverlay();
    }

    // Subscribe to translation manager events
    on('onLoadingStart', handleLoadingStart);
    on('onLoadingEnd', handleLoadingEnd);
    on('onLanguageChanged', handleLanguageChanged);
    on('onError', handleError);

    // Initialize translation manager
    showLoadingOverlay('Loading translations...');
    const success = await initialize((message, current, total) => {
        updateLoadingProgress(message, (current / total) * 100);
    });

    if (success) {
        hideLoadingOverlay();
        renderLanguageSelector();
        renderTranslations(); // Show "select a language" prompt
        updateGitHubStatus();

        // Add attention-grabbing animation to language dropdown
        if (elements.languageSelect) {
            elements.languageSelect.classList.add('needs-attention');
        }
    }
}

/**
 * Cache DOM elements
 */
function cacheElements() {
    elements.loadingOverlay = document.getElementById('loadingOverlay');
    elements.loadingText = document.getElementById('loadingText');
    elements.loadingProgress = document.getElementById('loadingProgress');
    elements.languageSelect = document.getElementById('languageSelect');
    elements.categoryFilter = document.getElementById('categoryFilter');
    elements.statusFilter = document.getElementById('statusFilter');
    elements.searchInput = document.getElementById('searchInput');
    elements.translationContainer = document.getElementById('translationContainer');
    elements.progressBar = document.getElementById('progressBar');
    elements.progressText = document.getElementById('progressText');
    elements.githubStatus = document.getElementById('githubStatus');
    elements.githubBtn = document.getElementById('githubBtn');
    elements.submitPrBtn = document.getElementById('submitPrBtn');
    elements.exportBtn = document.getElementById('exportBtn');
    elements.importBtn = document.getElementById('importBtn');
    elements.notification = document.getElementById('notification');
}

/**
 * Set up event listeners
 */
function setupEventListeners() {
    // Language selector
    elements.languageSelect?.addEventListener('change', handleLanguageChange);

    // Filters
    elements.categoryFilter?.addEventListener('change', handleFilterChange);
    elements.statusFilter?.addEventListener('change', handleFilterChange);
    elements.searchInput?.addEventListener('input', debounce(handleSearchChange, 300));

    // Buttons
    elements.githubBtn?.addEventListener('click', handleGitHubClick);
    elements.submitPrBtn?.addEventListener('click', handleSubmitPR);
    elements.exportBtn?.addEventListener('click', handleExport);
    elements.importBtn?.addEventListener('click', handleImport);

    // Keyboard shortcuts
    document.addEventListener('keydown', handleKeydown);

    // Before unload - save work
    window.addEventListener('beforeunload', () => {
        forceSave();
    });
}

/**
 * Render language selector
 */
function renderLanguageSelector() {
    if (!elements.languageSelect) return;

    const available = getAvailableLanguages();
    const zomboid = getZomboidLanguages();

    let html = '<option value="">Select a language...</option>';

    // English always at the top as the reference language
    html += '<option value="EN">English (EN) - Reference</option>';

    // Other languages available in repo (excluding EN since it's already at top)
    const otherAvailable = available.filter(l => l.code !== 'EN');
    if (otherAvailable.length > 0) {
        html += '<optgroup label="Existing Translations">';
        for (const lang of otherAvailable) {
            html += `<option value="${lang.code}">${lang.name} (${lang.code})</option>`;
        }
        html += '</optgroup>';
    }

    // New translations (languages not yet in repo)
    if (zomboid.length > 0) {
        html += '<optgroup label="Start New Translation">';
        for (const lang of zomboid) {
            html += `<option value="${lang.code}">${lang.name} (${lang.code})</option>`;
        }
        html += '</optgroup>';
    }

    elements.languageSelect.innerHTML = html;
}

/**
 * Render translations
 */
function renderTranslations() {
    if (!elements.translationContainer) return;

    const english = getEnglishBaseline();
    const translations = getCurrentTranslations();
    const langCode = getCurrentLanguage();

    if (!langCode) {
        elements.translationContainer.innerHTML = `
            <div class="empty-state">
                <h3>Welcome to the Translation Tool!</h3>
                <p>Please select a language from the dropdown above to begin translating.</p>
            </div>
        `;
        return;
    }

    // Get filtered keys
    const keys = getFilteredKeys(english, translations);

    if (keys.length === 0) {
        elements.translationContainer.innerHTML = `
            <div class="empty-state">
                <p>No translations match your filters</p>
            </div>
        `;
        return;
    }

    // Group by category
    const grouped = groupKeysByCategory(keys);

    let html = '';
    for (const [category, categoryKeys] of Object.entries(grouped)) {
        if (categoryKeys.length === 0) continue;

        const stats = getCategoryCompletionStats(categoryKeys, translations);

        const percentage = stats.total > 0 ? Math.round((stats.filled / stats.total) * 100) : 0;
        const tooltipText = `${stats.filled} translated of ${stats.total} keys (${percentage}%)`;

        html += `
            <div class="category-section" data-category="${category}">
                <div class="category-header" onclick="toggleCategory('${category}')">
                    <span class="category-name">${category}</span>
                    <div class="category-header-right">
                        <span class="category-stats" data-tooltip="${tooltipText}" data-tooltip-position="bottom">${stats.filled}/${stats.total}</span>
                        <span class="category-toggle" data-tooltip="Click to expand/collapse" data-tooltip-position="bottom">▼</span>
                    </div>
                </div>
                <div class="category-content">
        `;

        for (const key of categoryKeys) {
            const englishValue = english[key] || '';
            const translatedValue = translations[key] || '';
            const placeholders = extractPlaceholders(englishValue);
            const isFilled = translatedValue && translatedValue.trim();

            html += `
                <div class="translation-item ${isFilled ? 'filled' : 'empty'}" data-key="${key}">
                    <div class="translation-key">
                        <span class="key-name">${escapeHtml(key)}</span>
                        ${placeholders.length > 0 ? `<span class="placeholders">${placeholders.join(' ')}</span>` : ''}
                    </div>
                    <div class="translation-english">
                        <label>English:</label>
                        <div class="english-text">${escapeHtml(englishValue)}</div>
                    </div>
                    <div class="translation-input">
                        <label>Translation:</label>
                        <textarea
                            class="translation-textarea"
                            data-key="${key}"
                            placeholder="Enter ${langCode} translation..."
                            rows="${getTextareaRows(englishValue)}"
                        >${escapeHtml(translatedValue)}</textarea>
                    </div>
                </div>
            `;
        }

        html += '</div></div>';
    }

    elements.translationContainer.innerHTML = html;

    // Add event listeners to textareas
    elements.translationContainer.querySelectorAll('.translation-textarea').forEach(textarea => {
        textarea.addEventListener('input', handleTranslationInput);
        textarea.addEventListener('blur', handleTranslationBlur);
    });

    // Update progress bar
    updateProgressBar();
}

/**
 * Get filtered keys based on current filters
 */
function getFilteredKeys(english, translations) {
    let keys = Object.keys(english);

    // Category filter
    if (currentCategory !== 'all') {
        keys = keys.filter(key => {
            const keyCategory = getCategoryFromKey(key);
            return keyCategory === currentCategory;
        });
    }

    // Status filter
    if (filterMode === 'empty') {
        keys = keys.filter(key => !translations[key] || !translations[key].trim());
    } else if (filterMode === 'filled') {
        keys = keys.filter(key => translations[key] && translations[key].trim());
    }

    // Search filter
    if (searchQuery) {
        const query = searchQuery.toLowerCase();
        keys = keys.filter(key => {
            const englishValue = english[key] || '';
            const translatedValue = translations[key] || '';
            return key.toLowerCase().includes(query) ||
                   englishValue.toLowerCase().includes(query) ||
                   translatedValue.toLowerCase().includes(query);
        });
    }

    return keys;
}

/**
 * Group keys by category
 */
function groupKeysByCategory(keys) {
    const grouped = {};
    for (const category of CATEGORIES) {
        grouped[category] = [];
    }

    for (const key of keys) {
        const category = getCategoryFromKey(key);
        if (category && grouped[category]) {
            grouped[category].push(key);
        }
    }

    return grouped;
}

/**
 * Get category from key
 */
function getCategoryFromKey(key) {
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
 * Get completion stats for a set of keys
 */
function getCategoryCompletionStats(keys, translations) {
    let filled = 0;
    for (const key of keys) {
        if (translations[key] && translations[key].trim()) {
            filled++;
        }
    }
    return { filled, total: keys.length };
}

/**
 * Update progress bar
 */
function updateProgressBar() {
    const stats = getCompletionStats();

    if (elements.progressBar) {
        elements.progressBar.style.width = `${stats.percentage}%`;
        elements.progressBar.className = `progress-fill ${getProgressClass(stats.percentage)}`;
    }

    if (elements.progressText) {
        elements.progressText.textContent = `${stats.translated}/${stats.total} (${stats.percentage}%)`;
    }
}

/**
 * Get progress bar class based on percentage
 */
function getProgressClass(percentage) {
    if (percentage >= 100) return 'complete';
    if (percentage >= 75) return 'good';
    if (percentage >= 50) return 'moderate';
    return 'low';
}

/**
 * Update GitHub status
 */
async function updateGitHubStatus() {
    const status = getAuthStatus();

    if (status.isAuthenticated) {
        if (!githubUser) {
            githubUser = await getGitHubUser();
        }

        if (elements.githubStatus) {
            elements.githubStatus.textContent = githubUser?.login || 'Connected';
            elements.githubStatus.className = 'github-status connected';
        }

        if (elements.githubBtn) {
            elements.githubBtn.textContent = 'Disconnect';
            elements.githubBtn.className = 'btn btn-secondary';
        }

        if (elements.submitPrBtn) {
            elements.submitPrBtn.disabled = false;
        }
    } else {
        if (elements.githubStatus) {
            elements.githubStatus.textContent = 'Not connected';
            elements.githubStatus.className = 'github-status disconnected';
        }

        if (elements.githubBtn) {
            elements.githubBtn.textContent = 'Connect GitHub';
            elements.githubBtn.className = 'btn btn-primary';
        }

        if (elements.submitPrBtn) {
            elements.submitPrBtn.disabled = true;
        }
    }
}

// Event Handlers

function handleLoadingStart(data) {
    showLoadingOverlay(`Loading ${data.phase}...`);
}

function handleLoadingEnd(data) {
    hideLoadingOverlay();
}

function handleLanguageChanged(data) {
    renderTranslations();
    updateProgressBar();
}

function handleError(data) {
    showNotification(data.message, 'error');
}

async function handleLanguageChange(e) {
    const langCode = e.target.value;
    if (langCode) {
        // Remove the attention animation once user selects a language
        if (elements.languageSelect) {
            elements.languageSelect.classList.remove('needs-attention');
        }

        showLoadingOverlay(`Loading ${langCode}...`);
        await switchLanguage(langCode, true, (message, progress) => {
            updateLoadingProgress(message, progress * 100);
        });
        hideLoadingOverlay();
    }
}

function handleFilterChange() {
    currentCategory = elements.categoryFilter?.value || 'all';
    filterMode = elements.statusFilter?.value || 'all';
    renderTranslations();
}

function handleSearchChange(e) {
    searchQuery = e.target.value;
    renderTranslations();
}

function handleTranslationInput(e) {
    const key = e.target.dataset.key;
    const value = e.target.value;
    updateTranslation(key, value);

    // Update item styling
    const item = e.target.closest('.translation-item');
    if (item) {
        item.classList.toggle('filled', value && value.trim());
        item.classList.toggle('empty', !value || !value.trim());
    }
}

function handleTranslationBlur() {
    updateProgressBar();
}

async function handleGitHubClick() {
    if (isGitHubAuthenticated()) {
        showLoadingOverlay('Disconnecting from GitHub...');
        await logout();
        githubUser = null;
        hideLoadingOverlay();
        updateGitHubStatus();
        showNotification('Disconnected from GitHub', 'info');
    } else {
        startOAuthFlow();
    }
}

async function handleSubmitPR() {
    const allTranslations = getAllSavedTranslationsForSubmission();
    // Also get the full merged translations (repo + user edits) for complete file generation
    const fullMergedTranslations = getFullMergedTranslationsForSubmission();

    // Filter out EN (English is the baseline, not a translation to submit)
    // Also filter out any empty translation sets
    const submittableTranslations = {};
    for (const [langCode, translations] of Object.entries(allTranslations)) {
        if (langCode === 'EN') continue; // Never submit English as a "translation"

        // Only include translations that have actual content
        const filledKeys = Object.entries(translations).filter(([k, v]) => v && v.trim());
        if (filledKeys.length > 0) {
            submittableTranslations[langCode] = Object.fromEntries(filledKeys);
        }
    }

    const status = canSubmitPR(submittableTranslations);

    if (!status.canSubmit) {
        showNotification(status.reason, 'warning');
        return;
    }

    // Show confirmation modal - pass both changed translations and full merged translations
    showPRConfirmationModal(submittableTranslations, fullMergedTranslations);
}

/**
 * Show PR confirmation modal with summary of what will be submitted
 * @param {Object} translationsByLang - Changed translations to submit by language code
 * @param {Object} fullMergedTranslations - Full merged translations (repo + user edits) for complete files
 */
function showPRConfirmationModal(translationsByLang, fullMergedTranslations = null) {
    const english = getEnglishBaseline();
    const englishKeyCount = Object.keys(english).length;
    const languages = Object.keys(translationsByLang);
    const allLangs = getAllLanguages();

    // Build language name map for PR generation
    const langNames = {};
    for (const langCode of languages) {
        const langInfo = allLangs.find(l => l.code === langCode);
        langNames[langCode] = langInfo?.name || langCode;
    }

    // Generate default PR title and body
    const defaultTitle = generatePRTitle(languages, langNames);
    const defaultBody = generatePRBody(languages, translationsByLang, langNames);

    // Build summary for each language
    let languageSummaryHtml = '';
    let totalKeys = 0;

    for (const langCode of languages) {
        const translations = translationsByLang[langCode];
        const keyCount = Object.keys(translations).length;
        totalKeys += keyCount;

        const langName = langNames[langCode];

        // Categorize to show breakdown
        const categorized = {};
        for (const key of Object.keys(translations)) {
            const cat = getCategoryFromKey(key);
            if (cat) {
                categorized[cat] = (categorized[cat] || 0) + 1;
            }
        }

        languageSummaryHtml += `
            <div class="pr-language-summary">
                <div class="pr-language-header">
                    <span class="pr-language-name">${langName} (${langCode})</span>
                    <span class="pr-language-stats">${keyCount} changed keys</span>
                </div>
                <div class="pr-category-breakdown">
                    ${CATEGORIES.map(cat => {
                        const count = categorized[cat] || 0;
                        return count > 0 ? `<span class="pr-category-item">${cat}: ${count}</span>` : '';
                    }).filter(Boolean).join('')}
                </div>
            </div>
        `;
    }

    const modal = document.createElement('div');
    modal.className = 'modal-overlay';
    modal.innerHTML = `
        <div class="modal pr-confirmation-modal">
            <div class="modal-header">
                <h3>Submit Pull Request</h3>
                <button class="modal-close" onclick="this.closest('.modal-overlay').remove()">&times;</button>
            </div>
            <div class="modal-body">
                <div class="pr-summary-section">
                    <h4>Changes to Submit</h4>
                    <p>Only <strong>new or modified</strong> translations will be included:</p>

                    <div class="pr-languages-list">
                        ${languageSummaryHtml}
                    </div>

                    <div class="pr-totals">
                        <strong>Total:</strong> ${languages.length} language(s), ${totalKeys} changed/new keys
                    </div>
                </div>

                <div class="pr-form-section">
                    <h4>Pull Request Details</h4>

                    <div class="pr-form-group">
                        <label for="prTitle">PR Title</label>
                        <input type="text" id="prTitle" class="pr-input" value="${escapeHtml(defaultTitle)}" />
                    </div>

                    <div class="pr-form-group">
                        <label for="prBody">
                            Description
                            <span class="pr-label-hint">(Markdown supported)</span>
                        </label>
                        <textarea id="prBody" class="pr-textarea" rows="8">${escapeHtml(defaultBody)}</textarea>
                    </div>

                    <div class="pr-form-group pr-checkbox-group">
                        <label class="pr-checkbox-label">
                            <input type="checkbox" id="prPreview" />
                            <span>Preview description</span>
                        </label>
                    </div>

                    <div id="prPreviewArea" class="pr-preview-area" style="display: none;"></div>
                </div>

                <div class="pr-info-box">
                    <strong>What happens next:</strong>
                    <ul>
                        <li>A fork will be created in your GitHub account (if needed)</li>
                        <li>Your translations will be committed to a new branch</li>
                        <li>A Pull Request will be opened for the mod author to review</li>
                    </ul>
                </div>

                <div class="pr-actions">
                    <button class="btn btn-secondary" id="prCancelBtn">Cancel</button>
                    <button class="btn btn-primary" id="prConfirmBtn">
                        <span class="btn-icon">⬆</span> Submit Pull Request
                    </button>
                </div>
            </div>
        </div>
    `;

    document.body.appendChild(modal);

    // Cache elements
    const titleInput = modal.querySelector('#prTitle');
    const bodyTextarea = modal.querySelector('#prBody');
    const previewCheckbox = modal.querySelector('#prPreview');
    const previewArea = modal.querySelector('#prPreviewArea');

    // Preview toggle
    previewCheckbox?.addEventListener('change', () => {
        if (previewCheckbox.checked) {
            // Simple markdown preview (basic rendering)
            previewArea.innerHTML = renderSimpleMarkdown(bodyTextarea.value);
            previewArea.style.display = 'block';
            bodyTextarea.style.display = 'none';
        } else {
            previewArea.style.display = 'none';
            bodyTextarea.style.display = 'block';
        }
    });

    // Cancel button
    modal.querySelector('#prCancelBtn')?.addEventListener('click', () => {
        modal.remove();
    });

    // Submit button
    modal.querySelector('#prConfirmBtn')?.addEventListener('click', async () => {
        const customTitle = titleInput?.value?.trim() || defaultTitle;
        const customBody = bodyTextarea?.value || defaultBody;

        modal.remove();
        await executePRSubmission(translationsByLang, {
            customTitle,
            customBody,
            langNames,
            fullTranslationsByLang: fullMergedTranslations
        });
    });

    // Close on background click
    modal.addEventListener('click', (e) => {
        if (e.target === modal) {
            modal.remove();
        }
    });

    // Close on Escape key
    const handleEscape = (e) => {
        if (e.key === 'Escape') {
            modal.remove();
            document.removeEventListener('keydown', handleEscape);
        }
    };
    document.addEventListener('keydown', handleEscape);
}

/**
 * Render simple markdown to HTML (basic subset)
 * @param {string} markdown - Markdown text
 * @returns {string} HTML string
 */
function renderSimpleMarkdown(markdown) {
    let html = escapeHtml(markdown);

    // Headers
    html = html.replace(/^### (.+)$/gm, '<h4>$1</h4>');
    html = html.replace(/^## (.+)$/gm, '<h3>$1</h3>');
    html = html.replace(/^# (.+)$/gm, '<h2>$1</h2>');

    // Bold
    html = html.replace(/\*\*(.+?)\*\*/g, '<strong>$1</strong>');

    // Italic
    html = html.replace(/\*(.+?)\*/g, '<em>$1</em>');

    // Links
    html = html.replace(/\[(.+?)\]\((.+?)\)/g, '<a href="$2" target="_blank">$1</a>');

    // Lists
    html = html.replace(/^- (.+)$/gm, '<li>$1</li>');
    html = html.replace(/(<li>.*<\/li>\n?)+/g, '<ul>$&</ul>');

    // Line breaks
    html = html.replace(/\n\n/g, '</p><p>');
    html = `<p>${html}</p>`;

    // Horizontal rule
    html = html.replace(/^---$/gm, '<hr>');

    return html;
}

/**
 * Execute the actual PR submission after confirmation
 * @param {Object} translationsByLang - Changed translations to submit
 * @param {Object} options - Options including customTitle, customBody, langNames, fullTranslationsByLang
 */
async function executePRSubmission(translationsByLang, options = {}) {
    const { customTitle, customBody, langNames, fullTranslationsByLang } = options;

    showLoadingOverlay('Submitting to GitHub...');

    try {
        const result = await submitTranslationsPR(translationsByLang, {
            onProgress: (message, progress) => {
                updateLoadingProgress(message, progress);
            },
            customTitle,
            customBody,
            langNames,
            fullTranslationsByLang
        });

        hideLoadingOverlay();

        if (result.success) {
            showNotification(`PR created successfully!`, 'success');
            // Open PR in new tab
            window.open(result.prUrl, '_blank');
        }
    } catch (error) {
        hideLoadingOverlay();
        showNotification(`Failed to create PR: ${error.message}`, 'error');
    }
}

async function handleExport() {
    const langCode = getCurrentLanguage();
    if (!langCode) {
        showNotification('Please select a language first', 'warning');
        return;
    }

    showExportModal();
}

async function handleImport() {
    const files = await openFileDialog('.json,.txt,.zip', true);
    if (!files || files.length === 0) return;

    showLoadingOverlay('Importing...');

    try {
        for (const file of files) {
            const result = await importFromFile(file);

            if (result.success) {
                const validation = validateImportedTranslations(result.translations);

                // Merge with current translations
                const current = getCurrentTranslations();
                const merged = mergeTranslations(current, result.translations, 'fill');

                // Apply merged translations
                for (const [key, value] of Object.entries(merged)) {
                    updateTranslation(key, value);
                }

                showNotification(
                    `Imported ${Object.keys(result.translations).length} translations from ${file.name}`,
                    'success'
                );
            } else {
                showNotification(`Failed to import ${file.name}: ${result.errors.join(', ')}`, 'error');
            }
        }

        renderTranslations();
    } finally {
        hideLoadingOverlay();
    }
}

function handleKeydown(e) {
    // Ctrl+S to save
    if (e.ctrlKey && e.key === 's') {
        e.preventDefault();
        forceSave();
        showNotification('Saved!', 'success');
    }
}

// UI Helpers

function showLoadingOverlay(message) {
    if (elements.loadingOverlay) {
        elements.loadingOverlay.classList.add('visible');
    }
    if (elements.loadingText) {
        elements.loadingText.textContent = message;
    }
}

function hideLoadingOverlay() {
    if (elements.loadingOverlay) {
        elements.loadingOverlay.classList.remove('visible');
    }
}

function updateLoadingProgress(message, percentage) {
    if (elements.loadingText) {
        elements.loadingText.textContent = message;
    }
    if (elements.loadingProgress) {
        elements.loadingProgress.style.width = `${percentage}%`;
    }
}

function showNotification(message, type = 'info') {
    if (elements.notification) {
        elements.notification.textContent = message;
        elements.notification.className = `notification ${type} visible`;

        setTimeout(() => {
            elements.notification.classList.remove('visible');
        }, 3000);
    }
}

function showExportModal() {
    const langCode = getCurrentLanguage();
    const translations = getCurrentTranslations();
    const stats = getExportStats(translations);

    const modal = document.createElement('div');
    modal.className = 'modal-overlay';
    modal.innerHTML = `
        <div class="modal">
            <div class="modal-header">
                <h3>Export ${langCode} Translation</h3>
                <button class="modal-close" onclick="this.closest('.modal-overlay').remove()">&times;</button>
            </div>
            <div class="modal-body">
                <p>Total keys: ${stats.total}</p>
                <div class="export-options">
                    <button class="btn btn-primary" id="exportZip">
                        Download Mod-Ready ZIP
                    </button>
                    <button class="btn btn-secondary" id="exportJson">
                        Download JSON Backup
                    </button>
                </div>
                <h4>Individual Files:</h4>
                <div class="category-export-list">
                    ${CATEGORIES.map(cat => `
                        <div class="category-export-item">
                            <span>${cat} (${stats.byCategory[cat]} keys)</span>
                            <button class="btn btn-small" onclick="window.downloadCategory('${cat}')">Download</button>
                            <button class="btn btn-small" onclick="window.copyCategory('${cat}')">Copy</button>
                        </div>
                    `).join('')}
                </div>
            </div>
        </div>
    `;

    document.body.appendChild(modal);

    // Event listeners
    modal.querySelector('#exportZip')?.addEventListener('click', async () => {
        try {
            await downloadModReadyZip(langCode, translations);
            showNotification('ZIP downloaded!', 'success');
        } catch (e) {
            showNotification('Failed to create ZIP. Make sure JSZip is loaded.', 'error');
        }
    });

    modal.querySelector('#exportJson')?.addEventListener('click', () => {
        downloadJsonBackup(langCode, translations);
        showNotification('JSON backup downloaded!', 'success');
    });

    // Close on background click
    modal.addEventListener('click', (e) => {
        if (e.target === modal) {
            modal.remove();
        }
    });
}

// Global functions for inline handlers
window.toggleCategory = function(category) {
    const section = document.querySelector(`.category-section[data-category="${category}"]`);
    if (section) {
        section.classList.toggle('collapsed');
    }
};

window.downloadCategory = function(category) {
    downloadCategoryFile(category);
    showNotification(`Downloaded ${category}!`, 'success');
};

window.copyCategory = async function(category) {
    const success = await copyCategoryToClipboard(category);
    showNotification(success ? 'Copied to clipboard!' : 'Failed to copy', success ? 'success' : 'error');
};

// Utility Functions

function escapeHtml(text) {
    const div = document.createElement('div');
    div.textContent = text;
    return div.innerHTML;
}

function getTextareaRows(text) {
    if (!text) return 2;
    const lines = text.split('\n').length;
    const charLines = Math.ceil(text.length / 60);
    return Math.min(Math.max(lines, charLines, 2), 6);
}

function debounce(func, wait) {
    let timeout;
    return function executedFunction(...args) {
        const later = () => {
            clearTimeout(timeout);
            func(...args);
        };
        clearTimeout(timeout);
        timeout = setTimeout(later, wait);
    };
}
