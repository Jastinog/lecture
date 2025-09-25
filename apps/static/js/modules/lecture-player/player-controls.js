export class PlayerControls {
    constructor(player) {
        this.player = player;
        this.playPauseBtn = document.getElementById('btn-play-pause');
        this.rewindBtn = document.getElementById('btn-rewind');
        this.forwardBtn = document.getElementById('btn-forward');
    }

    init() {
        // Control buttons
        if (this.playPauseBtn) {
            this.playPauseBtn.addEventListener('click', (e) => {
                e.preventDefault();
                this.togglePlayPause();
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
                    this.togglePlayPause();
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

    skip(seconds) {
        if (!this.player.audio.duration) return;
        this.player.audio.currentTime = Math.max(0, 
            Math.min(this.player.audio.duration, this.player.audio.currentTime + seconds)
        );
    }

    togglePlayPause() {
        if (this.player.audio.paused) {
            this.player.audio.play().catch(e => console.error('Play failed:', e));
        } else {
            this.player.audio.pause();
        }
    }

    updatePlayPauseBtn(isPlaying) {
        const icon = this.playPauseBtn?.querySelector('i');
        if (icon) {
            icon.className = isPlaying ? 'fas fa-pause' : 'fas fa-play';
        }
    }
}
