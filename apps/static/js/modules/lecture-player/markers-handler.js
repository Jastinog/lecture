export class MarkersHandler {
    constructor(player) {
        this.player = player;

        this.addMarkerBtn = document.getElementById('add-marker-btn');
        this.markersList = document.querySelector('.markers-list');
        this.markersContainer = document.querySelector('.markers-section');

        this.lectureId = null;
        this.editingMarkerId = null;
        
        // Create markers list if it doesn't exist
        if (!this.markersList && this.markersContainer) {
            this.markersList = document.createElement('div');
            this.markersList.className = 'markers-list';
            this.markersContainer.appendChild(this.markersList);
        }
    }

    init() {
        const container = document.querySelector('.audio-player-section');
        this.lectureId = container ? parseInt(container.dataset.lectureId) : null;
        
        if (this.addMarkerBtn) {
            this.addMarkerBtn.addEventListener('click', (e) => {
                e.preventDefault();
                e.stopPropagation();
                this.createNewMarker();
            });
        } else {
            console.error('Add marker button not found');
        }

        // Add click handlers to existing markers
        this.attachMarkerHandlers();
    }

    attachMarkerHandlers() {
        if (!this.markersList) return;
        
        this.markersList.querySelectorAll('.marker-item').forEach(item => {
            this.attachSingleMarkerHandlers(item);
        });
    }

    attachSingleMarkerHandlers(item) {
        // Click on marker to seek
        item.addEventListener('click', (e) => {
            if (e.target.closest('.marker-actions') || e.target.closest('.marker-input')) {
                return;
            }
            
            const timestamp = parseFloat(item.dataset.timestamp);
            if (!isNaN(timestamp)) {
                this.seekToTimestamp(timestamp);
            }
        });

        // Edit button
        const editBtn = item.querySelector('.marker-edit-btn');
        if (editBtn) {
            editBtn.addEventListener('click', (e) => {
                e.stopPropagation();
                this.editMarker(item);
            });
        }

        // Delete button
        const deleteBtn = item.querySelector('.marker-delete-btn');
        if (deleteBtn) {
            deleteBtn.addEventListener('click', (e) => {
                e.stopPropagation();
                this.deleteMarker(item);
            });
        }
    }

    createNewMarker() {
        if (!this.player) {
            return;
        }
        
        if (!this.player.audio) {
            return;
        }

        // Check if audio is actually playable (has duration and current time)
        const isAudioPlayable = this.player.audio.duration > 0 && 
                               this.player.audio.currentTime >= 0 && 
                               this.player.audio.src;

        if (!isAudioPlayable) {
            this.showError('Аудио еще не загружено');
            return;
        }

        const currentTime = this.player.audio.currentTime;
        if (isNaN(currentTime)) {
            console.error('Invalid current time');
            return;
        }

        if (!this.markersList) {
            console.error('Markers list not found');
            return;
        }

        // Create marker element
        const markerItem = this.createMarkerElement({
            id: 'new',
            timestamp: currentTime,
            text: '',
            formatted_timestamp: this.formatTimestamp(currentTime)
        }, true);

        this.markersList.appendChild(markerItem);
        
        // Focus on input
        const input = markerItem.querySelector('.marker-input');
        if (input) {
            console.log('Focusing on input');
            setTimeout(() => input.focus(), 100);
        } else {
            console.error('Input not found in marker element');
        }

        // Scroll to new marker
        markerItem.scrollIntoView({ behavior: 'smooth', block: 'nearest' });
    }

    createMarkerElement(marker, isNew = false) {
        const item = document.createElement('div');
        item.className = 'marker-item';
        item.dataset.timestamp = marker.timestamp;
        item.dataset.markerId = marker.id;

        if (isNew) {
            item.innerHTML = `
                <span class="marker-timestamp">${marker.formatted_timestamp}</span>
                <input type="text" class="marker-input" value="${marker.text}" placeholder="Добавить заметку...">
                <div class="marker-actions">
                    <button class="marker-action-btn marker-save-btn">
                        <i class="fas fa-check"></i>
                    </button>
                    <button class="marker-action-btn marker-cancel-btn">
                        <i class="fas fa-times"></i>
                    </button>
                </div>
            `;

            this.attachNewMarkerHandlers(item);
        } else {
            item.innerHTML = `
                <span class="marker-timestamp">${marker.formatted_timestamp}</span>
                <span class="marker-text">${this.escapeHtml(marker.text)}</span>
                <div class="marker-actions">
                    <button class="marker-action-btn marker-edit-btn" data-marker-id="${marker.id}">
                        <i class="fas fa-edit"></i>
                    </button>
                    <button class="marker-action-btn marker-delete-btn" data-marker-id="${marker.id}">
                        <i class="fas fa-trash"></i>
                    </button>
                </div>
            `;

            this.attachSingleMarkerHandlers(item);
        }

        return item;
    }

    attachNewMarkerHandlers(item) {
        const input = item.querySelector('.marker-input');
        const saveBtn = item.querySelector('.marker-save-btn');
        const cancelBtn = item.querySelector('.marker-cancel-btn');

        console.log('Attaching handlers to new marker:', {
            input: !!input,
            saveBtn: !!saveBtn,
            cancelBtn: !!cancelBtn
        });

        // Save on Enter
        input.addEventListener('keydown', (e) => {
            if (e.key === 'Enter') {
                e.preventDefault();
                console.log('Enter pressed, saving marker');
                this.saveNewMarker(item);
            } else if (e.key === 'Escape') {
                e.preventDefault();
                console.log('Escape pressed, canceling marker');
                this.cancelNewMarker(item);
            }
        });

        // Save button
        saveBtn.addEventListener('click', (e) => {
            e.stopPropagation();
            console.log('Save button clicked');
            this.saveNewMarker(item);
        });

        // Cancel button
        cancelBtn.addEventListener('click', (e) => {
            e.stopPropagation();
            console.log('Cancel button clicked');
            this.cancelNewMarker(item);
        });
    }

    async saveNewMarker(item) {
        const input = item.querySelector('.marker-input');
        const text = input.value.trim();

        if (!text) {
            this.showError('Текст заметки не может быть пустым');
            return;
        }

        const timestamp = parseFloat(item.dataset.timestamp);

        try {
            const response = await fetch(`/api/v1/lectures/${this.lectureId}/markers/`, {
                method: 'POST',
                headers: {
                    'Content-Type': 'application/json',
                    'X-CSRFToken': this.player.getCSRFToken()
                },
                body: JSON.stringify({
                    timestamp: timestamp,
                    text: text
                })
            });

            const data = await response.json();

            if (response.ok && data.success) {
                // Replace with permanent marker
                const newMarker = this.createMarkerElement(data.marker, false);
                item.replaceWith(newMarker);
                this.sortMarkers();
            } else {
                this.showError(data.error || 'Ошибка при сохранении');
            }
        } catch (error) {
            console.error('Failed to save marker:', error);
            this.showError('Ошибка при сохранении');
        }
    }

    cancelNewMarker(item) {
        item.remove();
    }

    editMarker(item) {
        if (this.editingMarkerId) return; // Prevent multiple edits

        const markerId = item.dataset.markerId;
        const textSpan = item.querySelector('.marker-text');
        const actions = item.querySelector('.marker-actions');
        const currentText = textSpan.textContent;

        this.editingMarkerId = markerId;
        item.classList.add('editing');

        // Replace text with input
        textSpan.innerHTML = `<input type="text" class="marker-input" value="${this.escapeHtml(currentText)}">`;
        
        // Replace actions
        actions.innerHTML = `
            <button class="marker-action-btn marker-save-btn">
                <i class="fas fa-check"></i>
            </button>
            <button class="marker-action-btn marker-cancel-btn">
                <i class="fas fa-times"></i>
            </button>
        `;

        const input = textSpan.querySelector('.marker-input');
        const saveBtn = actions.querySelector('.marker-save-btn');
        const cancelBtn = actions.querySelector('.marker-cancel-btn');

        // Focus and select text
        input.focus();
        input.select();

        // Handlers
        input.addEventListener('keydown', (e) => {
            if (e.key === 'Enter') {
                e.preventDefault();
                this.saveEditedMarker(item, currentText);
            } else if (e.key === 'Escape') {
                e.preventDefault();
                this.cancelEditMarker(item, currentText);
            }
        });

        saveBtn.addEventListener('click', (e) => {
            e.stopPropagation();
            this.saveEditedMarker(item, currentText);
        });

        cancelBtn.addEventListener('click', (e) => {
            e.stopPropagation();
            this.cancelEditMarker(item, currentText);
        });
    }

    async saveEditedMarker(item, originalText) {
        const input = item.querySelector('.marker-input');
        const text = input.value.trim();
        const markerId = item.dataset.markerId;

        if (!text) {
            this.showError('Текст заметки не может быть пустым');
            return;
        }

        try {
            const response = await fetch(`/api/v1/lectures/markers/${markerId}/`, {
                method: 'PUT',
                headers: {
                    'Content-Type': 'application/json',
                    'X-CSRFToken': this.player.getCSRFToken()
                },
                body: JSON.stringify({ text: text })
            });

            const data = await response.json();

            if (response.ok && data.success) {
                this.restoreMarkerDisplay(item, text);
            } else {
                this.showError(data.error || 'Ошибка при сохранении');
                this.restoreMarkerDisplay(item, originalText);
            }
        } catch (error) {
            this.showError('Ошибка при сохранении');
            this.restoreMarkerDisplay(item, originalText);
        }
    }

    cancelEditMarker(item, originalText) {
        this.restoreMarkerDisplay(item, originalText);
    }

    restoreMarkerDisplay(item, text) {
        const markerId = item.dataset.markerId;
        const textSpan = item.querySelector('.marker-text');
        const actions = item.querySelector('.marker-actions');

        textSpan.innerHTML = this.escapeHtml(text);
        
        actions.innerHTML = `
            <button class="marker-action-btn marker-edit-btn" data-marker-id="${markerId}">
                <i class="fas fa-edit"></i>
            </button>
            <button class="marker-action-btn marker-delete-btn" data-marker-id="${markerId}">
                <i class="fas fa-trash"></i>
            </button>
        `;

        this.editingMarkerId = null;
        item.classList.remove('editing');
        this.attachSingleMarkerHandlers(item);
    }

    async deleteMarker(item) {
        const markerId = item.dataset.markerId;
        
        if (!confirm('Удалить заметку?')) return;

        try {
            const response = await fetch(`/api/v1/lectures/markers/${markerId}/`, {
                method: 'DELETE',
                headers: {
                    'X-CSRFToken': this.player.getCSRFToken()
                }
            });

            const data = await response.json();

            if (response.ok && data.success) {
                item.remove();
            } else {
                this.showError('Ошибка при удалении');
            }
        } catch (error) {
            console.error('Failed to delete marker:', error);
            this.showError('Ошибка при удалении');
        }
    }

    seekToTimestamp(timestamp) {
        if (!this.player.audio.duration) return;
        
        const validTime = Math.min(timestamp, this.player.audio.duration - 1);
        this.player.audio.currentTime = validTime;
    }

    sortMarkers() {
        if (!this.markersList) return;
        
        const markers = Array.from(this.markersList.querySelectorAll('.marker-item'));
        markers.sort((a, b) => {
            const timeA = parseFloat(a.dataset.timestamp);
            const timeB = parseFloat(b.dataset.timestamp);
            return timeA - timeB;
        });

        markers.forEach(marker => this.markersList.appendChild(marker));
    }

    formatTimestamp(seconds) {
        if (isNaN(seconds)) return '0:00';
        const m = Math.floor(seconds / 60);
        const s = Math.floor(seconds % 60);
        return `${m}:${s.toString().padStart(2, '0')}`;
    }

    escapeHtml(text) {
        const div = document.createElement('div');
        div.textContent = text;
        return div.innerHTML;
    }

    showError(message) {
        console.error('Error:', message);
        
        // Create temporary error message
        const errorDiv = document.createElement('div');
        errorDiv.textContent = message;
        errorDiv.style.cssText = `
            position: fixed;
            top: 20px;
            right: 20px;
            background: var(--red);
            color: var(--fg-0);
            padding: 10px 15px;
            border-radius: 5px;
            z-index: 1000;
            font-size: 14px;
        `;
        
        document.body.appendChild(errorDiv);
        
        setTimeout(() => {
            errorDiv.remove();
        }, 3000);
    }
}
