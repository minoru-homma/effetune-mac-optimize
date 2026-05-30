import { SearchManager } from './plugin-list/search-manager.js';
import { CollapseManager } from './plugin-list/collapse-manager.js';
import { DragDropManager } from './plugin-list/drag-drop-manager.js';
import { PresetManager } from './plugin-list/preset-manager.js';

// The native macOS host implements only the 8 Rust DSP effects (by class name,
// matching EffectKind.all in native/Sources/EffeTuneEngine/EffectModule.swift).
// Other effects are hidden from the plugin list when running in that host.
const NATIVE_SUPPORTED_EFFECTS = new Set([
    'FifteenBandPEQPlugin', 'FiveBandPEQPlugin', 'TransientShaperPlugin',
    'SubSynthPlugin', 'AutoLevelerPlugin', 'BrickwallLimiterPlugin',
    'MultibandCompressorPlugin', 'SpectrumAnalyzerPlugin',
    // Display-only JS analyzers (native taps audio; no Rust DSP):
    'LevelMeterPlugin', 'SpectrogramPlugin', 'OscilloscopePlugin', 'StereoMeterPlugin',
]);

export class PluginListManager {
    constructor(pluginManager) {
        this.pluginManager = pluginManager;
        this.pluginList = document.getElementById('pluginList');
        
        // Create loading spinner
        this.loadingSpinner = document.createElement('div');
        this.loadingSpinner.className = 'loading-spinner';
        this.pluginList.appendChild(this.loadingSpinner);
        
        // Create progress display as a separate element
        this.progressDisplay = document.createElement('div');
        this.progressDisplay.className = 'loading-spinner-progress';
        this.progressDisplay.textContent = '0%';
        this.pluginList.appendChild(this.progressDisplay);

        // Initialize managers
        this.searchManager = new SearchManager(this);
        this.collapseManager = new CollapseManager(this);
        this.dragDropManager = new DragDropManager(this);
        this.presetManager = new PresetManager(this);
    }
    
    // Delegate to collapse manager
    updateCategoryVisibility(category) {
        return this.collapseManager.updateCategoryVisibility(category);
    }
    
    // Update all categories visibility
    updateAllCategoriesVisibility() {
        return this.collapseManager.updateAllCategoriesVisibility();
    }

    // Delegate to search manager
    switchToTab(tab) {
        return this.searchManager.switchToTab(tab);
    }

    initPluginList() {
        let totalEffects = 0;
        const effectCountDiv = document.createElement('div');
        effectCountDiv.id = 'effectCount';
        effectCountDiv.style.textAlign = 'center';
        effectCountDiv.style.marginTop = '10px';
        effectCountDiv.style.color = '#666';
        effectCountDiv.style.fontSize = '14px';

        // Create content container for grid layout
        const contentContainer = document.createElement('div');
        contentContainer.className = 'plugin-list-content';

        // Create category sections from dynamically loaded categories
        for (const [category, {description, plugins}] of Object.entries(this.pluginManager.effectCategories)) {
            // Initialize collapsed state if not already set
            if (this.collapseManager.collapsedCategories[category] === undefined) {
                this.collapseManager.collapsedCategories[category] = false; // Default to expanded
            }

            // Create explicit row for the category
            const categoryRow = document.createElement('div');
            categoryRow.className = 'category-row';
            categoryRow.dataset.category = category;

            // Create category title with collapse indicator
            const categoryTitle = document.createElement('h3');
            
            // Create collapse indicator
            const collapseIndicator = document.createElement('span');
            collapseIndicator.className = 'collapse-indicator';
            collapseIndicator.textContent = this.collapseManager.collapsedCategories[category] ? '>' : '⌵';
            collapseIndicator.style.marginRight = '6px';
            collapseIndicator.style.display = 'inline-block';
            collapseIndicator.style.width = '12px';
            
            // Add indicator and text to title
            categoryTitle.appendChild(collapseIndicator);
            categoryTitle.appendChild(document.createTextNode(category));
            
            // Add click event to toggle category
            categoryTitle.addEventListener('click', () => {
                this.collapseManager.toggleCategoryCollapse(category);
            });

            // Create container for plugin items
            const pluginItemsContainer = document.createElement('div');
            pluginItemsContainer.className = 'plugin-category-items';
            
            // Create effect count display for collapsed state
            const effectsCountDisplay = document.createElement('div');
            effectsCountDisplay.className = 'category-effects-count';
            effectsCountDisplay.textContent = `${plugins.length} effects`;
            
            // Add title and items containers to the row (in the correct order)
            categoryRow.appendChild(categoryTitle);
            
            // Create a container for the right column content
            const rightColumnContent = document.createElement('div');
            rightColumnContent.className = 'right-column-content';
            
            // Add both the plugin items and effects count to the right column
            rightColumnContent.appendChild(effectsCountDisplay);
            rightColumnContent.appendChild(pluginItemsContainer);
            categoryRow.appendChild(rightColumnContent);
            
            // Set initial visibility based on collapsed state
            if (this.collapseManager.collapsedCategories[category]) {
                pluginItemsContainer.style.display = 'none';
                effectsCountDisplay.style.display = 'block';
            } else {
                pluginItemsContainer.style.display = 'flex';
                effectsCountDisplay.style.display = 'none';
            }

            // Add plugins for this category
            let addedInCategory = 0;
            plugins.forEach(name => {
                if (this.pluginManager.pluginClasses[name]) {
                    const plugin = new this.pluginManager.pluginClasses[name]();
                    // Native host supports only the 8 Rust DSP effects; hide the rest.
                    if (window.__effetuneNativeHost && !NATIVE_SUPPORTED_EFFECTS.has(plugin.constructor.name)) {
                        return;
                    }
                    const item = this.createPluginItem(plugin);
                    pluginItemsContainer.appendChild(item);
                    addedInCategory++;
                }
            });

            // Add row to container
            contentContainer.appendChild(categoryRow);
            totalEffects += addedInCategory;
        }

        // Find existing content container and remove it if it exists
        const existingContent = this.pluginList.querySelector('.plugin-list-content');
        if (existingContent) {
            existingContent.remove();
        }

        // Add new content while preserving h2
        this.pluginList.appendChild(contentContainer);

        // Add effect count at the end of the list
        if (window.uiManager && window.uiManager.t) {
            effectCountDiv.textContent = window.uiManager.t('ui.effectsAvailable', { count: totalEffects });
        } else {
            effectCountDiv.textContent = `${totalEffects} effects available`;
        }
        this.pluginList.appendChild(effectCountDiv);

        // Hide spinner after plugin list is fully initialized
        this.hideLoadingSpinner();
    }

    createPluginItem(plugin) {
        const item = document.createElement('div');
        item.className = 'plugin-item';
        item.draggable = true;
        item.textContent = plugin.name;
        
        const description = document.createElement('div');
        description.className = 'plugin-description';
        description.textContent = plugin.description;
        item.appendChild(description);

        this.setupPluginItemEvents(item, plugin);

        return item;
    }

    setupPluginItemEvents(item, plugin) {
        // Mouse events
        item.addEventListener('mousedown', () => {
            this.dragDropManager.dragMessage.style.display = 'block';
        });

        // Setup tooltip positioning
        const description = item.querySelector('.plugin-description');
        if (description) {
            item.addEventListener('mouseenter', (e) => {
                const rect = item.getBoundingClientRect();
                const pluginList = this.pluginList;
                const pluginListRect = pluginList.getBoundingClientRect();
                
                // Position tooltip to the right of the plugin item
                description.style.left = (rect.right + 10) + 'px';
                description.style.top = rect.top + 'px';
            });
        }

        // Handle double click to add plugin to pipeline
        item.addEventListener('dblclick', (e) => {
            e.preventDefault();
            e.stopPropagation();
            
            // Create a new instance of the plugin
            const newPlugin = this.pluginManager.createPlugin(plugin.name);
            if (!newPlugin) return;

            // Get pipeline manager from UI manager
            const pipelineManager = window.uiManager.pipelineManager;
            if (!pipelineManager) return;

            // Calculate insertion position:
            // - If plugins are selected, insert before the first selected plugin
            // - If no plugins are selected, append to the end of pipeline
            let insertIndex;
            if (pipelineManager.selectedPlugins.size > 0) {
                insertIndex = Math.min(...Array.from(pipelineManager.selectedPlugins)
                    .map(plugin => pipelineManager.audioManager.pipeline.indexOf(plugin)));
            } else {
                insertIndex = pipelineManager.audioManager.pipeline.length;
            }

            // Add the new plugin at calculated position
            pipelineManager.audioManager.pipeline.splice(insertIndex, 0, newPlugin);
            pipelineManager.expandedPlugins.add(newPlugin);

            // Update selection to only include the new plugin
            pipelineManager.selectedPlugins.clear();
            pipelineManager.selectedPlugins.add(newPlugin);
            pipelineManager.updateSelectionClasses();

            // Update worklet directly without rebuilding pipeline (same as drag & drop)
            pipelineManager.core.updateWorkletPlugins();
            
            // Save state for undo/redo
            pipelineManager.historyManager.saveState();

            // Use rAF to ensure UI update happens after event processing (same as drag & drop)
            requestAnimationFrame(() => {
                if (pipelineManager.core?.updatePipelineUI) {
                    pipelineManager.core.updatePipelineUI(true); // Pass true for immediate update
                } else {
                    console.error("Missing core or updatePipelineUI in dblclick's rAF callback");
                }
            });
            
            pipelineManager.updateURL();
            
            // Check window width and adjust plugin list collapse state
            this.collapseManager.checkWindowWidthAndAdjust();

            // Auto-scroll to show newly added plugin if it was appended at the end
            if (insertIndex === pipelineManager.audioManager.pipeline.length - 1) {
                requestAnimationFrame(() => {
                    window.scrollTo({
                        top: document.body.scrollHeight,
                        behavior: 'smooth'
                    });
                });
            }
        });

        item.addEventListener('mouseup', () => {
            // Hide message if drag didn't start
            if (!item.matches('.dragging')) {
                this.dragDropManager.dragMessage.style.display = 'none';
            }
        });

        // Set up drag events via drag drop manager
        this.dragDropManager.setupPluginItemDragEvents(item, plugin);
    }

    // Delegate preset methods to preset manager
    async initSystemPresetList() {
        return this.presetManager.initSystemPresetList();
    }

    async initUserPresetList() {
        return this.presetManager.initUserPresetList();
    }

    async refreshPresetsIfVisible() {
        return this.presetManager.refreshPresetsIfVisible();
    }

    showLoadingSpinner() {
        this.loadingSpinner.style.display = 'block';
        this.progressDisplay.style.display = 'flex';
        this.updateLoadingProgress(0);
    }

    hideLoadingSpinner() {
        this.loadingSpinner.style.display = 'none';
        this.progressDisplay.style.display = 'none';
    }
    
    updateLoadingProgress(percent) {
        if (percent < 0) percent = 0;
        if (percent > 100) percent = 100;
        
        const formattedPercent = Math.round(percent);
        this.progressDisplay.textContent = `${formattedPercent}%`;
    }

    // Delegate to drag drop manager
    getDragMessage() {
        return this.dragDropManager.getDragMessage();
    }

    getInsertionIndicator() {
        return this.dragDropManager.getInsertionIndicator();
    }

    // Delegate to drag drop manager
    updateInsertionIndicator(clientX, clientY) {
        return this.dragDropManager.updateInsertionIndicator(clientX, clientY);
    }

    findInsertionIndex(clientX, clientY, pipeline) {
        return this.dragDropManager.findInsertionIndex(clientX, clientY, pipeline);
    }

    throttle(func, delay) {
        return this.dragDropManager.throttle(func, delay);
    }

    // Delegate to collapse manager  
    updatePositions() {
        return this.collapseManager.updatePositions();
    }

    checkWindowWidthAndAdjust() {
        return this.collapseManager.checkWindowWidthAndAdjust();
    }

    // Delegate to preset manager
    async initPresetManager() {
        return this.presetManager.initPresetManager();
    }

    // Delegate to preset manager
    async addUserPresetToPipeline(presetName, insertionIndex = null) {
        return this.presetManager.addUserPresetToPipeline(presetName, insertionIndex);
    }
}