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
    getAvailableLanguages,
    getLocalDraftLanguages,
    getZomboidLanguages,
    getAllLanguages,
    buildSubmissionPreflight,
    forceSave,
    getTranslationHealth,
    getTranslationCategoryDiagnostics,
    buildDiagnosticsReport,
    getDiagnosticsReport
} from './translation-manager.js';
import {
    downloadCategoryFile,
    downloadModReadyZip,
    downloadJsonBackup,
    downloadTemplate,
    downloadLLMPack,
    copyCategoryToClipboard,
    getExportStats
} from './export-utils.js';
import {
    importFromFile,
    validateImportByLanguage,
    mergeTranslations,
    openFileDialog,
    getImportSummary
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
import { extractPlaceholders, validateTranslation } from './lua-parser.js';
import { getLanguageTranslations } from './storage-manager.js';

// UI State
let currentCategory = 'all';
let filterMode = 'all'; // 'all', 'empty', 'filled'
let searchQuery = '';
let githubUser = null;
const diagnosticsRequestedLanguages = new Set();

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
    elements.exportTemplateBtn = document.getElementById('exportTemplateBtn');
    elements.exportLlmBtn = document.getElementById('exportLlmBtn');
    elements.importBtn = document.getElementById('importBtn');
    elements.notification = document.getElementById('notification');
    elements.healthPanel = document.getElementById('healthPanel');
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
    elements.exportTemplateBtn?.addEventListener('click', handleExportTemplate);
    elements.exportLlmBtn?.addEventListener('click', handleExportLlm);
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

    const previousValue = elements.languageSelect.value;
    const available = getAvailableLanguages();
    const localDrafts = getLocalDraftLanguages();
    const zomboid = getZomboidLanguages();

    let html = '<option value="">Select a language...</option>';

    const english = available.find(l => l.code === 'EN');
    if (english) {
        html += `<option value="${english.code}">${escapeHtml(english.name)} (${english.code}) [Repo]</option>`;
    }

    const existing = available.filter(l => l.code !== 'EN');
    if (existing.length > 0) {
        html += '<optgroup label="Existing Translations (Repo)">';
        for (const lang of existing) {
            const status = lang.hasLocalDraft ? 'Repo + Draft' : 'Repo';
            html += `<option value="${lang.code}">${escapeHtml(lang.name)} (${lang.code}) [${status}]</option>`;
        }
        html += '</optgroup>';
    }

    if (localDrafts.length > 0) {
        html += '<optgroup label="Local Drafts">';
        for (const lang of localDrafts) {
            html += `<option value="${lang.code}">${escapeHtml(lang.name)} (${lang.code}) [Local Draft]</option>`;
        }
        html += '</optgroup>';
    }

    if (zomboid.length > 0) {
        html += '<optgroup label="Start New Translation">';
        for (const lang of zomboid) {
            html += `<option value="${lang.code}">${escapeHtml(lang.name)} (${lang.code}) [New]</option>`;
        }
        html += '</optgroup>';
    }

    elements.languageSelect.innerHTML = html;
    if (previousValue && elements.languageSelect.querySelector(`option[value="${previousValue}"]`)) {
        elements.languageSelect.value = previousValue;
    }
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
                <p>Select a language to begin translating, or import a file and apply to the detected language.</p>
            </div>
        `;
        updateTranslationHealthPanel();
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
        updateTranslationHealthPanel();
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
                        <span class="category-toggle" data-tooltip="Click to expand/collapse" data-tooltip-position="bottom">&#9662;</span>
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
    updateTranslationHealthPanel();
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
    renderLanguageSelector();
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
    updateTranslationHealthPanel();
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

function getLanguageDisplayName(langCode) {
    const allLangs = getAllLanguages();
    return allLangs.find(l => l.code === langCode)?.name || langCode;
}

function getFilteredImportMap(translations, english) {
    const filtered = {};
    for (const [key, value] of Object.entries(translations || {})) {
        if (english[key] !== undefined) {
            filtered[key] = value;
        }
    }
    return filtered;
}

function countMergeDiff(existing, imported, mode) {
    const merged = mergeTranslations(existing, imported, mode);
    let changed = 0;
    let added = 0;
    let overwritten = 0;

    for (const [key, value] of Object.entries(merged)) {
        if (existing[key] !== value) {
            changed++;
            if (existing[key] === undefined || !existing[key]) {
                added++;
            } else {
                overwritten++;
            }
        }
    }

    return { changed, added, overwritten };
}

async function showImportPreflightModal(fileName, importResult, validationResult) {
    const summary = getImportSummary(importResult, validationResult);
    const detectedLanguages = importResult.detectedLanguages || [];
    const currentLang = getCurrentLanguage();
    const hasPlaceholderBlocking = (validationResult.blockingIssues || []).length > 0;
    const hasHardBlocking = (importResult.errors || []).length > 0 || (importResult.blockingIssues || []).length > 0;

    const singleDetectedLanguage = detectedLanguages.length === 1 ? detectedLanguages[0] : null;
    const defaultTargetLanguage = singleDetectedLanguage || currentLang || '';
    const canOfferCurrentOverride = singleDetectedLanguage && currentLang && currentLang !== singleDetectedLanguage;

    const languageRows = detectedLanguages.map(langCode => {
        const map = importResult.translationsByLanguage?.[langCode] || {};
        const validation = validationResult.byLanguage?.[langCode];
        const placeholderIssues = validation?.placeholderIssues?.length || 0;
        return `
            <label class="import-lang-row">
                <input type="checkbox" class="import-lang-checkbox" value="${langCode}" checked />
                <span class="import-lang-label">${escapeHtml(getLanguageDisplayName(langCode))} (${langCode})</span>
                <span class="import-lang-stats">${Object.keys(map).length} keys${placeholderIssues ? `, ${placeholderIssues} placeholder issue(s)` : ''}</span>
            </label>
        `;
    }).join('');

    const modal = document.createElement('div');
    modal.className = 'modal-overlay';
    modal.innerHTML = `
        <div class="modal import-preflight-modal">
            <div class="modal-header">
                <h3>Import Preview</h3>
                <button class="modal-close" id="importCloseBtn">&times;</button>
            </div>
            <div class="modal-body">
                <div class="import-summary-grid">
                    <div><strong>File</strong><br>${escapeHtml(fileName)}</div>
                    <div><strong>Format</strong><br>${escapeHtml(summary.format || 'unknown')}</div>
                    <div><strong>Languages</strong><br>${summary.detectedLanguages.join(', ') || 'None'}</div>
                    <div><strong>Total Keys</strong><br>${summary.totalKeys}</div>
                </div>

                <div class="import-section">
                    <label for="importMergeMode"><strong>Merge mode</strong></label>
                    <select id="importMergeMode" class="import-select">
                        <option value="fill">Fill empty values only (recommended)</option>
                        <option value="overwrite">Overwrite existing values</option>
                        <option value="skip">Add new keys only</option>
                    </select>
                </div>

                ${singleDetectedLanguage ? `
                    <div class="import-section">
                        <label for="importTargetLanguage"><strong>Target language</strong></label>
                        <select id="importTargetLanguage" class="import-select">
                            <option value="${singleDetectedLanguage}">${escapeHtml(getLanguageDisplayName(singleDetectedLanguage))} (${singleDetectedLanguage})</option>
                            ${canOfferCurrentOverride ? `<option value="${currentLang}">${escapeHtml(getLanguageDisplayName(currentLang))} (${currentLang})</option>` : ''}
                        </select>
                    </div>
                ` : ''}

                <div class="import-section">
                    <strong>Languages to apply</strong>
                    <div class="import-lang-list">${languageRows || '<div class="import-empty">No languages detected.</div>'}</div>
                </div>

                ${summary.warnings.length > 0 ? `
                    <div class="import-section">
                        <strong>Warnings</strong>
                        <ul class="import-issues warning">
                            ${summary.warnings.map(w => `<li>${escapeHtml(w)}</li>`).join('')}
                        </ul>
                    </div>
                ` : ''}

                ${summary.errors.length > 0 ? `
                    <div class="import-section">
                        <strong>Errors</strong>
                        <ul class="import-issues error">
                            ${summary.errors.map(err => `<li>${escapeHtml(err)}</li>`).join('')}
                        </ul>
                    </div>
                ` : ''}

                ${summary.blockingIssues.length > 0 ? `
                    <div class="import-section">
                        <strong>Blocking issues</strong>
                        <ul class="import-issues error">
                            ${summary.blockingIssues.map(issue => `<li>${escapeHtml(issue)}</li>`).join('')}
                        </ul>
                    </div>
                ` : ''}

                ${hasPlaceholderBlocking ? `
                    <div class="import-section">
                        <label class="import-override-label">
                            <input type="checkbox" id="importAllowPlaceholderOverride" />
                            <span>Allow placeholder mismatches for this import</span>
                        </label>
                    </div>
                ` : ''}

                <div id="importPreviewStats" class="import-preview-stats"></div>
            </div>
            <div class="pr-actions">
                <button class="btn btn-secondary" id="importCancelBtn">Cancel</button>
                <button class="btn btn-primary" id="importConfirmBtn">Apply Import</button>
            </div>
        </div>
    `;

    document.body.appendChild(modal);

    const mergeModeSelect = modal.querySelector('#importMergeMode');
    const targetLanguageSelect = modal.querySelector('#importTargetLanguage');
    const confirmBtn = modal.querySelector('#importConfirmBtn');
    const placeholderOverride = modal.querySelector('#importAllowPlaceholderOverride');
    const previewStats = modal.querySelector('#importPreviewStats');

    function getSelectedLanguages() {
        return Array.from(modal.querySelectorAll('.import-lang-checkbox:checked')).map(cb => cb.value);
    }

    function updatePreview() {
        const mergeMode = mergeModeSelect?.value || 'fill';
        const selectedLanguages = getSelectedLanguages();
        const targetLanguage = targetLanguageSelect?.value || defaultTargetLanguage;
        const english = getEnglishBaseline();

        let totalChanged = 0;
        let totalAdded = 0;
        let totalOverwritten = 0;

        for (const sourceLang of selectedLanguages) {
            const importMap = getFilteredImportMap(importResult.translationsByLanguage?.[sourceLang] || {}, english);
            const targetLang = singleDetectedLanguage ? targetLanguage : sourceLang;
            const existing = targetLang === getCurrentLanguage()
                ? getCurrentTranslations()
                : (getLanguageTranslations(targetLang) || {});
            const diff = countMergeDiff(existing, importMap, mergeMode);
            totalChanged += diff.changed;
            totalAdded += diff.added;
            totalOverwritten += diff.overwritten;
        }

        previewStats.innerHTML = `
            <strong>Preview:</strong> ${totalChanged} key(s) will change
            (${totalAdded} added/fill, ${totalOverwritten} overwritten).
        `;

        const placeholderBlocked = hasPlaceholderBlocking && !placeholderOverride?.checked;
        const noLanguageSelected = selectedLanguages.length === 0;
        confirmBtn.disabled = hasHardBlocking || placeholderBlocked || noLanguageSelected;
    }

    updatePreview();
    mergeModeSelect?.addEventListener('change', updatePreview);
    targetLanguageSelect?.addEventListener('change', updatePreview);
    placeholderOverride?.addEventListener('change', updatePreview);
    modal.querySelectorAll('.import-lang-checkbox').forEach(cb => cb.addEventListener('change', updatePreview));

    return await new Promise(resolve => {
        const close = (value) => {
            modal.remove();
            resolve(value);
        };

        modal.querySelector('#importCloseBtn')?.addEventListener('click', () => close(null));
        modal.querySelector('#importCancelBtn')?.addEventListener('click', () => close(null));
        modal.querySelector('#importConfirmBtn')?.addEventListener('click', () => {
            close({
                mergeMode: mergeModeSelect?.value || 'fill',
                selectedLanguages: getSelectedLanguages(),
                targetLanguage: targetLanguageSelect?.value || defaultTargetLanguage,
                allowPlaceholderOverride: !!placeholderOverride?.checked
            });
        });

        modal.addEventListener('click', (e) => {
            if (e.target === modal) {
                close(null);
            }
        });
    });
}

async function applyImportPlan(importResult, plan) {
    const english = getEnglishBaseline();
    const selected = plan.selectedLanguages || [];
    const previousLanguage = getCurrentLanguage();
    const hadCurrentLanguage = !!previousLanguage;
    const singleSourceLanguage = importResult.detectedLanguages?.length === 1 ? importResult.detectedLanguages[0] : null;

    let totalChanged = 0;
    const touchedLanguages = new Set();

    for (const sourceLang of selected) {
        const sourceMap = importResult.translationsByLanguage?.[sourceLang] || {};
        const filteredMap = getFilteredImportMap(sourceMap, english);
        const targetLang = singleSourceLanguage ? (plan.targetLanguage || sourceLang) : sourceLang;

        await switchLanguage(targetLang, true);
        const existing = getCurrentTranslations();
        const merged = mergeTranslations(existing, filteredMap, plan.mergeMode || 'fill');

        for (const [key, value] of Object.entries(merged)) {
            if (existing[key] !== value) {
                updateTranslation(key, value);
                totalChanged++;
            }
        }

        touchedLanguages.add(targetLang);
    }

    forceSave();

    if (hadCurrentLanguage && previousLanguage && previousLanguage !== getCurrentLanguage()) {
        await switchLanguage(previousLanguage, true);
    } else if (!hadCurrentLanguage && singleSourceLanguage) {
        await switchLanguage(plan.targetLanguage || singleSourceLanguage, true);
    }

    renderLanguageSelector();
    renderTranslations();
    return { totalChanged, touchedLanguages: [...touchedLanguages] };
}

async function handleSubmitPR() {
    showLoadingOverlay('Preparing submission...');

    try {
        const preflight = await buildSubmissionPreflight();
        hideLoadingOverlay();

        if (preflight.blockingIssues.length > 0 && preflight.languagesIncluded.length === 0) {
            showNotification(preflight.blockingIssues[0], 'warning');
            return;
        }

        const status = canSubmitPR(preflight.changedByLang);
        if (!status.canSubmit) {
            showNotification(status.reason, 'warning');
            return;
        }

        showPRConfirmationModal(preflight);
    } catch (error) {
        hideLoadingOverlay();
        showNotification(`Failed to prepare PR submission: ${error.message}`, 'error');
    }
}

function showPRConfirmationModal(preflight) {
    const changedByLang = preflight.changedByLang || {};
    const fullByLang = preflight.fullTranslationsByLang || {};
    const languages = Object.keys(changedByLang);
    const allLangs = getAllLanguages();

    const langNames = {};
    for (const langCode of languages) {
        const langInfo = allLangs.find(l => l.code === langCode);
        langNames[langCode] = langInfo?.name || langCode;
    }

    const languageRows = languages.map(langCode => {
        const changedCount = Object.keys(changedByLang[langCode] || {}).length;
        const plannedFiles = (preflight.filesPlanned || []).filter(f => f.langCode === langCode).length;
        return `
            <label class="pr-lang-row">
                <input type="checkbox" class="pr-lang-checkbox" value="${langCode}" checked />
                <span class="pr-lang-name">${escapeHtml(langNames[langCode])} (${langCode})</span>
                <span class="pr-lang-stats">${changedCount} changed keys, ${plannedFiles} file target(s)</span>
            </label>
        `;
    }).join('');

    const modal = document.createElement('div');
    modal.className = 'modal-overlay';
    modal.innerHTML = `
        <div class="modal pr-confirmation-modal">
            <div class="modal-header">
                <h3>Submit Pull Request</h3>
                <button class="modal-close" id="prCloseBtn">&times;</button>
            </div>
            <div class="modal-body">
                <div class="pr-summary-section">
                    <h4>Submission Preflight</h4>
                    <p>Select which languages to include in this PR.</p>
                    <div class="pr-lang-list">${languageRows}</div>
                    <div id="prSelectionSummary" class="pr-totals"></div>
                </div>

                ${preflight.warnings?.length ? `
                    <div class="pr-warning">
                        <strong>Warnings:</strong>
                        <ul>${preflight.warnings.map(w => `<li>${escapeHtml(w)}</li>`).join('')}</ul>
                    </div>
                ` : ''}

                ${preflight.blockingIssues?.length ? `
                    <div class="pr-warning">
                        <strong>Skipped / Blocking Issues:</strong>
                        <ul>${preflight.blockingIssues.map(issue => `<li>${escapeHtml(issue)}</li>`).join('')}</ul>
                    </div>
                ` : ''}

                <div class="pr-form-section">
                    <h4>Pull Request Details</h4>
                    <div class="pr-form-group">
                        <label for="prTitle">PR Title</label>
                        <input type="text" id="prTitle" class="pr-input" />
                    </div>
                    <div class="pr-form-group">
                        <label for="prBody">Description <span class="pr-label-hint">(Markdown supported)</span></label>
                        <textarea id="prBody" class="pr-textarea" rows="8"></textarea>
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
                        <li>A fork is created in your GitHub account if needed</li>
                        <li>Files are generated for both Build 42 and Build 41 paths</li>
                        <li>A pull request is opened for review</li>
                    </ul>
                </div>
            </div>
            <div class="pr-actions">
                <button class="btn btn-secondary" id="prCancelBtn">Cancel</button>
                <button class="btn btn-primary" id="prConfirmBtn">
                    <span class="btn-icon">&#11014;</span> Submit Pull Request
                </button>
            </div>
        </div>
    `;

    document.body.appendChild(modal);

    const titleInput = modal.querySelector('#prTitle');
    const bodyTextarea = modal.querySelector('#prBody');
    const previewCheckbox = modal.querySelector('#prPreview');
    const previewArea = modal.querySelector('#prPreviewArea');
    const summaryContainer = modal.querySelector('#prSelectionSummary');
    const confirmBtn = modal.querySelector('#prConfirmBtn');

    function getSelectedLanguages() {
        return Array.from(modal.querySelectorAll('.pr-lang-checkbox:checked')).map(cb => cb.value);
    }

    function buildSelectedMaps(selectedLanguages) {
        const selectedChanged = {};
        const selectedFull = {};
        for (const langCode of selectedLanguages) {
            selectedChanged[langCode] = changedByLang[langCode];
            selectedFull[langCode] = fullByLang[langCode];
        }
        return { selectedChanged, selectedFull };
    }

    function refreshInputs() {
        const selected = getSelectedLanguages();
        const { selectedChanged } = buildSelectedMaps(selected);
        const totalKeys = Object.values(selectedChanged).reduce((sum, map) => sum + Object.keys(map || {}).length, 0);
        const plannedFiles = (preflight.filesPlanned || []).filter(f => selected.includes(f.langCode)).length;

        summaryContainer.textContent = `${selected.length} language(s), ${totalKeys} changed key(s), ${plannedFiles} file target(s).`;
        confirmBtn.disabled = selected.length === 0;

        titleInput.value = generatePRTitle(selected, langNames);
        bodyTextarea.value = generatePRBody(selected, selectedChanged, langNames);
    }

    refreshInputs();
    modal.querySelectorAll('.pr-lang-checkbox').forEach(cb => cb.addEventListener('change', refreshInputs));

    previewCheckbox?.addEventListener('change', () => {
        if (previewCheckbox.checked) {
            previewArea.innerHTML = renderSimpleMarkdown(bodyTextarea.value);
            previewArea.style.display = 'block';
            bodyTextarea.style.display = 'none';
        } else {
            previewArea.style.display = 'none';
            bodyTextarea.style.display = 'block';
        }
    });

    const closeModal = () => modal.remove();
    modal.querySelector('#prCloseBtn')?.addEventListener('click', closeModal);
    modal.querySelector('#prCancelBtn')?.addEventListener('click', closeModal);

    modal.querySelector('#prConfirmBtn')?.addEventListener('click', async () => {
        const selected = getSelectedLanguages();
        if (selected.length === 0) {
            showNotification('Select at least one language to submit', 'warning');
            return;
        }

        const { selectedChanged, selectedFull } = buildSelectedMaps(selected);
        const customTitle = titleInput?.value?.trim() || generatePRTitle(selected, langNames);
        const customBody = bodyTextarea?.value || generatePRBody(selected, selectedChanged, langNames);

        modal.remove();
        await executePRSubmission(selectedChanged, {
            customTitle,
            customBody,
            langNames,
            fullTranslationsByLang: selectedFull
        });
    });

    modal.addEventListener('click', (e) => {
        if (e.target === modal) {
            modal.remove();
        }
    });
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

function handleExportTemplate() {
    const langCode = getCurrentLanguage();
    if (!langCode) {
        showNotification('Please select a language first', 'warning');
        return;
    }

    downloadTemplate(langCode, getCurrentTranslations());
    showNotification('Template downloaded!', 'success');
}

function handleExportLlm() {
    const langCode = getCurrentLanguage();
    if (!langCode) {
        showNotification('Please select a language first', 'warning');
        return;
    }

    downloadLLMPack(langCode, getCurrentTranslations());
    showNotification('LLM pack downloaded!', 'success');
}

async function handleImport() {
    const files = await openFileDialog('.json,.txt,.zip', true);
    if (!files || files.length === 0) return;

    showLoadingOverlay('Analyzing imports...');

    try {
        for (const file of files) {
            const result = await importFromFile(file);
            if (!result.success) {
                showNotification(`Failed to import ${file.name}: ${result.errors.join(', ')}`, 'error');
                continue;
            }

            const validation = validateImportByLanguage(result, { blockOnPlaceholderIssues: true });
            const plan = await showImportPreflightModal(file.name, result, validation);
            if (!plan) {
                showNotification(`Import cancelled for ${file.name}`, 'info');
                continue;
            }

            if (!plan.allowPlaceholderOverride && validation.blockingIssues.length > 0) {
                showNotification('Import blocked by placeholder mismatches. Enable override to continue.', 'warning');
                continue;
            }

            const applyResult = await applyImportPlan(result, plan);
            showNotification(
                `Imported ${applyResult.totalChanged} changes from ${file.name} into ${applyResult.touchedLanguages.join(', ')}`,
                'success'
            );
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
                    <button class="btn btn-secondary" id="exportTemplate">
                        Download Template
                    </button>
                    <button class="btn btn-secondary" id="exportLlm">
                        Download LLM Pack
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

    modal.querySelector('#exportTemplate')?.addEventListener('click', () => {
        downloadTemplate(langCode, translations);
        showNotification('Template downloaded!', 'success');
    });

    modal.querySelector('#exportLlm')?.addEventListener('click', () => {
        downloadLLMPack(langCode, translations);
        showNotification('LLM pack downloaded!', 'success');
    });

    // Close on background click
    modal.addEventListener('click', (e) => {
        if (e.target === modal) {
            modal.remove();
        }
    });
}

function updateTranslationHealthPanel() {
    if (!elements.healthPanel) return;

    const langCode = getCurrentLanguage();
    if (!langCode) {
        elements.healthPanel.innerHTML = `
            <div class="health-title">Translation Health</div>
            <div class="health-row">Select a language to view health metrics.</div>
        `;
        return;
    }

    const english = getEnglishBaseline();
    const current = getCurrentTranslations();
    const health = getTranslationHealth();
    const categoryDiag = getTranslationCategoryDiagnostics(current);

    let placeholderIssues = 0;
    for (const [key, value] of Object.entries(current)) {
        if (!value || !value.trim()) continue;
        if (english[key] === undefined) continue;
        const validation = validateTranslation(key, value, english[key]);
        if (!validation.valid) {
            placeholderIssues++;
        }
    }

    if (!diagnosticsRequestedLanguages.has(langCode)) {
        diagnosticsRequestedLanguages.add(langCode);
        buildDiagnosticsReport({ langCodes: [langCode] }).catch(() => {
            diagnosticsRequestedLanguages.delete(langCode);
        });
    }

    const diagnostics = getDiagnosticsReport();
    const missingByLang = diagnostics?.missingCategoriesByLang?.[langCode]?.length || 0;
    const duplicateKeys = (diagnostics?.duplicateKeys || []).filter(item => item.langCode === langCode).length;
    const legacyItems = diagnostics?.legacyItemsPresent?.some(item => item.langCode === langCode) ? 'Yes' : 'No';

    elements.healthPanel.innerHTML = `
        <div class="health-title">Translation Health: ${escapeHtml(langCode)}</div>
        <div class="health-grid">
            <div class="health-cell"><strong>Coverage</strong><br>${health.coverage.translated}/${health.coverage.total} (${health.coverage.percentage}%)</div>
            <div class="health-cell"><strong>Empty Keys</strong><br>${health.emptyKeyCount}</div>
            <div class="health-cell"><strong>Placeholder Issues</strong><br>${placeholderIssues}</div>
            <div class="health-cell"><strong>Uncategorized Keys</strong><br>${categoryDiag.uncategorized.length}</div>
            <div class="health-cell"><strong>Duplicate Repo Keys</strong><br>${duplicateKeys}</div>
            <div class="health-cell"><strong>Repo Missing Categories</strong><br>${missingByLang}</div>
            <div class="health-cell"><strong>Legacy Items_XX.txt</strong><br>${legacyItems}</div>
        </div>
    `;
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
