export class ShareHandler {
    constructor(player) {
        this.player = player;
    }

    init() {
        document.addEventListener('click', (e) => {
            if (e.target.closest('.share-btn')) {
                e.preventDefault();
                e.stopPropagation();
                this.handleShare(e.target.closest('.share-btn'));
            }
        });
    }

    async handleShare(button) {
        const lectureId = parseInt(button.dataset.lectureId);
        const topicId = parseInt(button.dataset.topicId);
        
        // Get current time if audio is ready
        let currentTime = null;
        if (this.player.isAudioReady && this.player.audio.currentTime > 0) {
            currentTime = this.player.audio.currentTime;
        }

        // Generate share URL (with time if available)
        const shareUrl = this.generateShareUrl(lectureId, currentTime);
        
        // Copy to clipboard
        const success = await this.copyUrl(shareUrl, currentTime > 0);
        
        if (success) {
            this.showCopyFeedback(button, currentTime > 0);
        }
    }

    generateShareUrl(lectureId, currentTime = null) {
        const baseUrl = window.location.origin;
        
        if (currentTime && currentTime > 0) {
            const timeInSeconds = Math.floor(currentTime);
            return `${baseUrl}/lecture/${lectureId}/${timeInSeconds}/`;
        } else {
            return `${baseUrl}/lecture/${lectureId}/`;
        }
    }

    async copyUrl(shareUrl, withTime = false) {
        try {
            await navigator.clipboard.writeText(shareUrl);
            this.showCopySuccess(withTime ? 'Ссылка с временем скопирована!' : 'Ссылка скопирована!');
            return true;
        } catch (err) {
            console.error('Failed to copy:', err);
            // Fallback for older browsers
            try {
                const textArea = document.createElement('textarea');
                textArea.value = shareUrl;
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
        toast.style.cssText = `
            position: fixed;
            bottom: 20px;
            left: 50%;
            transform: translateX(-50%);
            background: ${type === 'success' ? '#10b981' : type === 'error' ? '#ef4444' : '#6b7280'};
            color: white;
            padding: 12px 24px;
            border-radius: 6px;
            z-index: 1000;
            font-size: 14px;
            opacity: 0;
            transition: opacity 0.3s ease;
        `;

        document.body.appendChild(toast);

        // Show toast
        requestAnimationFrame(() => {
            toast.style.opacity = '1';
        });

        // Auto hide after 3 seconds
        setTimeout(() => {
            if (toast.parentNode) {
                toast.style.opacity = '0';
                setTimeout(() => {
                    if (toast.parentNode) {
                        toast.remove();
                    }
                }, 300);
            }
        }, 3000);
    }
}
