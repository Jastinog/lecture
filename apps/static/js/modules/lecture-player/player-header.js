export class PlayerHeader {
    constructor(player) {
        this.player = player;
        this.nowPlayingTitle = document.querySelector('.now-playing-title');
        this.nowPlayingContainer = document.querySelector('.now-playing');
        this.scrollTimeout = null;
    }

    init() {
        if (this.nowPlayingTitle) {
            const initialTitle = this.nowPlayingTitle.textContent.trim();
            if (initialTitle && initialTitle !== '- - -') {
                this.updateNowPlaying(initialTitle);
            }
        }
    }

    updateNowPlaying(title) {
        if (!this.nowPlayingTitle || !this.nowPlayingContainer) return;

        if (this.scrollTimeout) {
            clearTimeout(this.scrollTimeout);
        }

        // Reset animation
        this.nowPlayingTitle.classList.remove('scrolling');
        this.nowPlayingTitle.textContent = title;
        
        // Force reflow
        this.nowPlayingTitle.offsetHeight;
        
        // Check if scrolling is needed
        requestAnimationFrame(() => {
            this.checkAndStartScrolling();
        });
    }

    checkAndStartScrolling() {
        if (!this.nowPlayingTitle || !this.nowPlayingContainer) return;

        const titleWidth = this.nowPlayingTitle.scrollWidth;
        const containerWidth = this.nowPlayingContainer.offsetWidth;
        
        if (titleWidth > containerWidth - 10) {
            // Calculate the exact distance to move
            const moveDistance = titleWidth - containerWidth + 20; // 20px padding
            
            // Update CSS custom property for animation
            this.nowPlayingTitle.style.setProperty('--move-distance', `-${moveDistance}px`);
            
            // Start animation
            this.nowPlayingTitle.classList.add('scrolling');
        }
    }

    setPlaceholder() {
        if (!this.nowPlayingTitle) return;
        
        if (this.scrollTimeout) {
            clearTimeout(this.scrollTimeout);
        }
        
        this.nowPlayingTitle.classList.remove('scrolling');
        this.nowPlayingTitle.textContent = '- - -';
    }
}
