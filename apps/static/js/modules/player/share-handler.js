export class ShareHandler {
    constructor(player) {
        this.player = player;
    }

    init() {
        document.querySelectorAll('.share-btn').forEach(btn => {
            btn.addEventListener('click', (e) => {
                e.preventDefault();
                e.stopPropagation();
                this.handleShare(btn);
            });
        });
    }

    async handleShare(button) {
        const lectureId = parseInt(button.dataset.lectureId);
        const topicId = parseInt(button.dataset.topicId);
        
        // Get current time if this is the playing lecture
        let currentTime = null;
        if (this.player.currentLectureId === lectureId && this.player.isAudioReady) {
            currentTime = this.player.audio.currentTime;
        }

        // Generate share URL (with time if available)
        const shareUrl = this.generateShareUrl(topicId, lectureId, currentTime);
        
        // Copy directly to clipboard
        const success = await this.copyUrl(shareUrl, currentTime > 0);
        
        if (success) {
            // Visual feedback - briefly change button state
            this.showCopyFeedback(button, currentTime > 0);
        }
    }

    generateShareUrl(topicId, lectureId, currentTime = null) {
        const baseUrl = window.location.origin;
        
        if (currentTime && currentTime > 0) {
            const timeInSeconds = Math.floor(currentTime);
            return `${baseUrl}/topic/${topicId}/lecture/${lectureId}/${timeInSeconds}/`;
        } else {
            return `${baseUrl}/topic/${topicId}/lecture/${lectureId}/`;
        }
    }

    async copyUrl(url, withTime = false) {
        try {
            await navigator.clipboard.writeText(url);
            this.showCopySuccess(withTime ? 'Ссылка с временем скопирована!' : 'Ссылка скопирована!');
            return true;
        } catch (err) {
            console.error('Failed to copy:', err);
            // Fallback for older browsers
            try {
                const textArea = document.createElement('textarea');
                textArea.value = url;
                textArea.style.position = 'fixed';
                textArea.style.opacity = '0';
                document.body.appendChild(textArea);
                textArea.focus();
                textArea.select();
                document.execCommand('copy');
                document.body.removeChild(textArea);
                this.showCopySuccess(withTime ? 'Ссылка с временем скопирована!' : 'Ссылка скопирована!');
                return true;
            } catch (fallbackErr) {
                this.showCopyError('Не удалось скопировать ссылку');
                return false;
            }
        }
    }

    showCopyFeedback(button, withTime = false) {
        // Save original state
        const originalHTML = button.innerHTML;
        const originalClass = button.className;
        
        // Show feedback
        button.innerHTML = '<i class="fas fa-check"></i>';
        button.classList.add('share-success');
        
        // Reset after animation
        setTimeout(() => {
            button.innerHTML = originalHTML;
            button.className = originalClass;
        }, 1000);
    }

    showCopySuccess(message) {
        this.showToast(message, 'success');
    }

    showCopyError(message) {
        this.showToast(message, 'error');
    }

    showToast(message, type = 'info') {
        // Remove existing toast
        const existing = document.querySelector('.share-toast');
        if (existing) {
            existing.remove();
        }

        const toast = document.createElement('div');
        toast.className = `share-toast share-toast-${type}`;
        toast.textContent = message;

        document.body.appendChild(toast);

        // Show toast
        requestAnimationFrame(() => {
            toast.classList.add('show');
        });

        // Auto hide after 3 seconds
        setTimeout(() => {
            if (toast.parentNode) {
                toast.classList.remove('show');
                setTimeout(() => {
                    if (toast.parentNode) {
                        toast.remove();
                    }
                }, 300);
            }
        }, 3000);
    }
}
