export class DownloadHandler {
    constructor(player, audioLoader) {
        this.player = player;
        this.audioLoader = audioLoader;
    }

    init() {
        document.addEventListener('click', (e) => {
            if (e.target.closest('.download-btn')) {
                e.preventDefault();
                e.stopPropagation();
                this.handleDownload(e.target.closest('.download-btn'));
            }
        });
    }

    async handleDownload(button) {
        const lectureId = parseInt(button.dataset.lectureId);
        const downloadUrl = button.dataset.downloadUrl;
        
        if (!lectureId) {
            console.error('Missing lecture ID');
            return;
        }

        if (button.downloading) {
            return;
        }

        button.downloading = true;
        this.showDownloadFeedback(button, 'starting');
        
        try {
            let blob;
            
            if (this.audioLoader && this.audioLoader.isLoaded(lectureId)) {
                blob = this.audioLoader.loadedBlobs.get(lectureId);
                this.downloadBlob(blob, this.generateFileName(lectureId));
                this.showDownloadFeedback(button, 'success');
            } else {
                if (downloadUrl) {
                    const response = await fetch(downloadUrl);
                    if (!response.ok) {
                        throw new Error(`HTTP error! status: ${response.status}`);
                    }
                    blob = await response.blob();
                } else {
                    const response = await fetch(`/api/v1/lectures/${lectureId}/audio/`, {
                        headers: { 'X-CSRFToken': this.getCSRFToken() }
                    });
                    
                    if (!response.ok) {
                        throw new Error(`HTTP error! status: ${response.status}`);
                    }
                    blob = await response.blob();
                }
                
                if (this.audioLoader) {
                    this.audioLoader.loadedBlobs.set(lectureId, blob);
                }
                
                this.downloadBlob(blob, this.generateFileName(lectureId));
                this.showDownloadFeedback(button, 'success');
            }
            
        } catch (error) {
            console.error('Download failed:', error);
            this.showDownloadFeedback(button, 'error');
        } finally {
            button.downloading = false;
        }
    }

    downloadBlob(blob, filename) {
        const url = URL.createObjectURL(blob);
        const link = document.createElement('a');
        link.href = url;
        link.download = filename;
        link.style.display = 'none';
        
        document.body.appendChild(link);
        link.click();
        document.body.removeChild(link);
        
        URL.revokeObjectURL(url);
    }

    generateFileName(lectureId) {
        const playerSection = document.querySelector('.audio-player-section');
        const title = playerSection?.dataset.lectureTitle || 'lecture';
        return `${title}.mp3`;
    }

    showDownloadFeedback(button, state) {
        if (!button.originalState) {
            button.originalState = {
                html: button.innerHTML,
                className: button.className,
                disabled: button.disabled
            };
        }
        
        if (button.resetTimeout) {
            clearTimeout(button.resetTimeout);
            button.resetTimeout = null;
        }
        
        switch (state) {
            case 'starting':
                button.innerHTML = '<i class="fas fa-spinner fa-spin"></i>';
                button.disabled = true;
                break;
            case 'success':
                button.innerHTML = '<i class="fas fa-check"></i>';
                button.disabled = false;
                button.resetTimeout = setTimeout(() => this.resetButton(button), 2000);
                break;
            case 'error':
                button.innerHTML = '<i class="fas fa-exclamation-triangle"></i>';
                button.disabled = false;
                button.resetTimeout = setTimeout(() => this.resetButton(button), 3000);
                break;
        }
    }

    resetButton(button) {
        if (button.originalState) {
            button.innerHTML = button.originalState.html;
            button.className = button.originalState.className;
            button.disabled = button.originalState.disabled;
            delete button.originalState;
        }
        
        if (button.resetTimeout) {
            clearTimeout(button.resetTimeout);
            button.resetTimeout = null;
        }
        
        button.downloading = false;
    }

    getCSRFToken() {
        return document.querySelector('[name=csrfmiddlewaretoken]')?.value || 
               document.querySelector('meta[name=csrf-token]')?.content || '';
    }
}
