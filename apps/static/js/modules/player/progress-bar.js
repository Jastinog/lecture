export class ProgressBar {
    constructor(player) {
        this.player = player;
        this.progressBar = document.querySelector('.progress-bar');
        this.progressFilled = document.querySelector('.progress-filled');
        this.timeCurrent = document.querySelector('.time-current');
        this.timeTotal = document.querySelector('.time-total');
        this.isSeeking = false;
        this.seekTarget = null;
        
        this.createBufferIndicator();
    }

    createBufferIndicator() {
        if (!this.progressBar) return;
        
        // Create buffer indicator inside the main progress bar
        this.bufferIndicator = document.createElement('div');
        this.bufferIndicator.className = 'progress-buffer';
        
        // Insert buffer indicator before the progress-filled
        this.progressBar.insertBefore(this.bufferIndicator, this.progressFilled);
    }

    init() {
        this.progressBar?.addEventListener('click', (e) => this.seek(e));
        
        // Track buffering progress
        this.player.audio.addEventListener('progress', () => this.updateBuffer());
        this.player.audio.addEventListener('loadstart', () => this.resetBuffer());
    }

    resetBuffer() {
        // Don't reset buffer width - keep it visible
        // Only reset when new file starts loading
    }

    updateBuffer() {
        if (!this.player.audio.duration || !this.bufferIndicator) return;

        const buffered = this.player.audio.buffered;
        let maxBufferedEnd = 0;
        
        // Find the maximum buffered end time
        for (let i = 0; i < buffered.length; i++) {
            maxBufferedEnd = Math.max(maxBufferedEnd, buffered.end(i));
        }
        
        const bufferPercent = Math.min(100, (maxBufferedEnd / this.player.audio.duration) * 100);
        this.bufferIndicator.style.width = `${bufferPercent}%`;
        
        // Log buffer progress for debugging
        console.log(`Buffer: ${maxBufferedEnd.toFixed(1)}s / ${this.player.audio.duration.toFixed(1)}s (${bufferPercent.toFixed(1)}%)`);
    }

    // Show loading progress during initial file download
    updateLoadingProgress(percent) {
        if (!this.bufferIndicator) return;
        this.bufferIndicator.style.width = `${percent}%`;
        // Don't reset after loading - let the normal buffer update handle it
    }

    updateProgress() {
        if (this.isSeeking || this.player.isSeekingToTarget || !this.player.audio.duration) return;

        const currentTime = this.player.audio.currentTime;
        const duration = this.player.audio.duration;

        if (isNaN(currentTime) || isNaN(duration) || duration <= 0) return;

        const percent = (currentTime / duration) * 100;
        
        if (this.progressFilled) {
            this.progressFilled.style.width = `${percent}%`;
        }
        
        if (this.timeCurrent) {
            this.timeCurrent.textContent = this.player.formatTime(currentTime);
        }
    }

    updateTotalTime(duration) {
        if (isNaN(duration) || duration <= 0) return;
        
        if (this.timeTotal) {
            this.timeTotal.textContent = this.player.formatTime(duration);
        }
    }

    seek(e) {
        if (!this.player.audio.duration || this.player.isSeekingToTarget) return;
        
        e.preventDefault();
        e.stopPropagation();
        
        const rect = this.progressBar.getBoundingClientRect();
        const clickX = e.clientX - rect.left;
        const percent = Math.max(0, Math.min(1, clickX / rect.width));
        const newTime = percent * this.player.audio.duration;
        
        console.log("Manual seek to:", newTime);
        
        this.isSeeking = true;
        this.progressFilled.style.width = `${percent * 100}%`;
        this.timeCurrent.textContent = this.player.formatTime(newTime);
        
        this.seekTarget = newTime;
        this.performSeek(newTime);
    }

    performSeek(newTime) {
        this.player.audio.currentTime = newTime;
        
        const onSeeked = () => {
            console.log("Manual seek completed, time:", this.player.audio.currentTime);
            this.isSeeking = false;
            this.seekTarget = null;
            this.player.audio.removeEventListener('seeked', onSeeked);
            this.player.saveCurrentProgress();
        };
        
        this.player.audio.addEventListener('seeked', onSeeked);
        
        setTimeout(() => {
            if (this.isSeeking) {
                console.log("Manual seek timeout");
                this.isSeeking = false;
                this.seekTarget = null;
                this.player.saveCurrentProgress();
            }
        }, 2000);
    }
}
