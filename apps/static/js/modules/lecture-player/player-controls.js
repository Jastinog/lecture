export class PlayerControls {
    constructor(player) {
        this.player = player;
        this.playPauseBtn = document.getElementById('btn-play-pause');
        this.rewindBtn = document.getElementById('btn-rewind');
        this.forwardBtn = document.getElementById('btn-forward');
        this.originalPlayIcon = 'fas fa-play';
        this.originalPauseIcon = 'fas fa-pause';
    }

    init() {
        // Set initial disabled state
        this.setLoadingState();
        
        // Control buttons
        if (this.playPauseBtn) {
            this.playPauseBtn.addEventListener('click', (e) => {
                e.preventDefault();
                if (!this.playPauseBtn.disabled) {
                    this.togglePlayPause();
                }
            });
        }
        
        this.rewindBtn?.addEventListener('click', () => this.skip(-this.player.SKIP_SECONDS));
        this.forwardBtn?.addEventListener('click', () => this.skip(this.player.SKIP_SECONDS));

        // Keyboard shortcuts
        document.addEventListener('keydown', (e) => {
            if (e.target.tagName === 'INPUT' || e.target.tagName === 'TEXTAREA') return;
            
            switch(e.key.toLowerCase()) {
                case ' ':
                case 'k':
                    e.preventDefault();
                    if (!this.playPauseBtn.disabled) {
                        this.togglePlayPause();
                    }
                    break;
                case 'j':
                case 'arrowleft':
                    e.preventDefault();
                    this.skip(-this.player.SKIP_SECONDS);
                    break;
                case 'l':
                case 'arrowright':
                    e.preventDefault();
                    this.skip(this.player.SKIP_SECONDS);
                    break;
            }
        });
    }

    setLoadingState() {
        if (this.playPauseBtn) {
            this.playPauseBtn.disabled = true;
            this.playPauseBtn.classList.add('loading');
            // const icon = this.playPauseBtn.querySelector('i');
            // if (icon) {
            //     icon.className = 'fas fa-spinner fa-spin';
            // }
        }
    }

    updateLoadingProgress(percent) {
        if (this.playPauseBtn) {
            const icon = this.playPauseBtn.querySelector('i');
            if (icon && percent !== undefined) {
                // Remove spinner and show percentage
                icon.className = '';
                icon.textContent = `${Math.round(percent)}`;
                icon.style.fontSize = '12px';
            }
        }
    }

    setReadyState() {
        if (this.playPauseBtn) {
            this.playPauseBtn.disabled = false;
            this.playPauseBtn.classList.remove('loading');
            const icon = this.playPauseBtn.querySelector('i');
            if (icon) {
                icon.textContent = '';
                icon.style.fontSize = '';
                icon.className = this.originalPlayIcon;
            }
        }
    }

    skip(seconds) {
        if (!this.player.audio.duration || this.playPauseBtn.disabled) return;
        this.player.audio.currentTime = Math.max(0, 
            Math.min(this.player.audio.duration, this.player.audio.currentTime + seconds)
        );
    }

    togglePlayPause() {
        if (this.playPauseBtn.disabled) return;
        
        if (this.player.audio.paused) {
            this.player.audio.play().catch(e => console.error('Play failed:', e));
        } else {
            this.player.audio.pause();
        }
    }

    updatePlayPauseBtn(isPlaying) {
        if (this.playPauseBtn.disabled) return;
        
        const icon = this.playPauseBtn?.querySelector('i');
        if (icon) {
            icon.className = isPlaying ? this.originalPauseIcon : this.originalPlayIcon;
        }
    }
}
