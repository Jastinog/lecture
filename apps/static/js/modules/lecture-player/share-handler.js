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

            return true;
        } catch (err) {
            console.error('Failed to copy:', err);
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
}
