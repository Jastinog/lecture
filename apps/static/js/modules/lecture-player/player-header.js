export class PlayerHeader {
    constructor(player) {
        this.player = player;
        this.nowPlayingTitle = document.querySelector('.now-playing-title');
        this.nowPlayingContainer = document.querySelector('.now-playing');
        this.scrollTimeout = null;
    }

    init() {
        // Any header-specific initialization can go here
    }

    updateNowPlaying(title) {
        if (this.nowPlayingTitle && this.nowPlayingContainer) {
            // Clear any existing timeout
            if (this.scrollTimeout) {
                clearTimeout(this.scrollTimeout);
            }

            // Remove scrolling class and reset
            this.nowPlayingTitle.classList.remove('scrolling');
            this.nowPlayingTitle.textContent = title;
            this.nowPlayingTitle.setAttribute('data-title', title);
            
            // Force reflow
            this.nowPlayingTitle.offsetHeight;
            
            // Check if scrolling is needed after a brief delay
            setTimeout(() => {
                const titleWidth = this.nowPlayingTitle.scrollWidth;
                const containerWidth = this.nowPlayingContainer.offsetWidth;
                
                if (titleWidth > containerWidth) {
                    // Start scrolling immediately
                    this.nowPlayingTitle.classList.add('scrolling');
                }
            }, 100);
        }
    }

    setPlaceholder() {
        if (this.nowPlayingTitle) {
            // Clear any existing timeout
            if (this.scrollTimeout) {
                clearTimeout(this.scrollTimeout);
            }
            
            this.nowPlayingTitle.textContent = '- - -';
            this.nowPlayingTitle.classList.remove('scrolling');
            this.nowPlayingTitle.removeAttribute('data-title');
        }
    }
}
