export class DownloadHandler {
    constructor(player) {
        this.player = player;
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
        const lectureId = button.dataset.lectureId;
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
            if (downloadUrl) {
                this.downloadFile(downloadUrl, this.generateFileName(lectureId));
            } else {
                const response = await fetch(`/api/v1/lectures/${lectureId}/audio/`, {
                    headers: { 'X-CSRFToken': this.getCSRFToken() }
                });
                
                if (!response.ok) {
                    throw new Error(`HTTP error! status: ${response.status}`);
                }

                const blob = await response.blob();
                const url = window.URL.createObjectURL(blob);
                this.downloadFile(url, this.generateFileName(lectureId));
                window.URL.revokeObjectURL(url);
            }
            
            this.showDownloadFeedback(button, 'success');
        } catch (error) {
            console.error('Download failed:', error);
            this.showDownloadFeedback(button, 'error');
        } finally {
            button.downloading = false;
        }
    }

    downloadFile(url, filename) {
        const link = document.createElement('a');
        link.href = url;
        link.download = filename;
        link.style.display = 'none';
        
        document.body.appendChild(link);
        link.click();
        document.body.removeChild(link);
    }

    generateFileName(lectureId) {
        const titleElement = document.querySelector('.now-playing-title') || 
                           document.querySelector('h1');
        const title = titleElement?.textContent?.trim() || 'lecture';
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
                button.innerHTML = '<i class="fas fa-spinner fa-spin"></i> Загрузка...';
                button.disabled = true;
                break;
            case 'success':
                button.innerHTML = '<i class="fas fa-check"></i> Готово';
                button.disabled = false;
                button.resetTimeout = setTimeout(() => this.resetButton(button), 2000);
                break;
            case 'error':
                button.innerHTML = '<i class="fas fa-exclamation-triangle"></i> Ошибка';
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
