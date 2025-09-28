export class ProgressBar {
    constructor(player) {
        this.player = player;
        this.progressBar = document.querySelector('.progress-bar');
        this.progressFilled = document.querySelector('.progress-filled');
        this.timeCurrent = document.querySelector('.time-current');
        this.timeTotal = document.querySelector('.time-total');
        this.isSeeking = false;
        this.loadingIndicator = null;
        this.isLoadingComplete = false;
        this.preservedProgress = 0;
        this.currentBufferPercent = 0;
        this.savedProgressPercent = 0;
        this.isInitialProgressAnimationRunning = false;
        
        this.createBufferIndicator();
        this.createLoadingIndicator();
    }

    createBufferIndicator() {
        if (!this.progressBar) return;
        
        this.bufferIndicator = document.createElement('div');
        this.bufferIndicator.className = 'progress-buffer';
        this.progressBar.insertBefore(this.bufferIndicator, this.progressFilled);
    }

    createLoadingIndicator() {
        if (!this.progressBar) return;
        
        this.loadingIndicator = document.createElement('div');
        this.loadingIndicator.className = 'progress-loading';
        this.loadingIndicator.style.display = 'none';
        this.progressBar.appendChild(this.loadingIndicator);
    }

    init() {
        this.progressBar?.addEventListener('click', (e) => this.seek(e));
        
        this.player.audio.addEventListener('progress', () => this.updateBuffer());
        this.player.audio.addEventListener('loadstart', () => {
            this.isLoadingComplete = false;
            this.currentBufferPercent = 0;
        });
        this.player.audio.addEventListener('canplaythrough', () => {
            this.isLoadingComplete = true;
            this.updateBuffer();
        });

        this.initializeFromTemplate();
    }

    initializeFromTemplate() {
        const container = document.querySelector('.audio-player-section');
        if (!container) return;

        const savedProgress = parseFloat(container.dataset.progress || '0');
        const savedTime = parseFloat(container.dataset.currentTime || '0');
        
        this.savedProgressPercent = savedProgress;
        
        if (this.progressFilled) {
            this.progressFilled.style.width = '0%';
        }

        if (this.timeCurrent) {
            this.timeCurrent.textContent = '0:00';
        }
    }



    hideLoading() {
        if (this.loadingIndicator) {
            this.loadingIndicator.style.display = 'none';
        }
        
        if (this.progressBar) {
            this.progressBar.style.pointerEvents = 'auto';
        }
    }

    updateBuffer() {
        if (!this.bufferIndicator) return;

        let bufferPercent = 0;

        if (this.player.lectureId && this.player.audioLoader.isLoaded(this.player.lectureId)) {
            bufferPercent = 100;
        } else if (this.player.audio.duration) {
            const buffered = this.player.audio.buffered;
            let maxBufferedEnd = 0;
            
            for (let i = 0; i < buffered.length; i++) {
                maxBufferedEnd = Math.max(maxBufferedEnd, buffered.end(i));
            }
            
            bufferPercent = Math.min(100, (maxBufferedEnd / this.player.audio.duration) * 100);
        }

        this.currentBufferPercent = bufferPercent;
        this.bufferIndicator.style.width = `${bufferPercent}%`;
    }

    updateLoadingProgress(percent) {
        if (!this.bufferIndicator) return;
        
        if (!this.isLoadingComplete && 
            !(this.player.lectureId && this.player.audioLoader.isLoaded(this.player.lectureId))) {
            
            this.currentBufferPercent = percent;
            this.bufferIndicator.style.width = `${percent}%`;
            
            if (this.savedProgressPercent > 0) {
                const fillPercent = Math.min(percent, this.savedProgressPercent);
                
                if (this.progressFilled) {
                    this.progressFilled.style.width = `${fillPercent}%`;
                }
                
                if (this.timeCurrent) {
                    const container = document.querySelector('.audio-player-section');
                    const savedTime = parseFloat(container?.dataset.currentTime || '0');
                    const currentTimeValue = savedTime * (fillPercent / this.savedProgressPercent);
                    this.timeCurrent.textContent = this.player.formatTime(currentTimeValue);
                }
            }
        }
    }

    forceUpdateProgress() {
        const currentTime = this.player.audio.currentTime;
        const container = document.querySelector('.audio-player-section');
        const duration = parseFloat(container?.dataset.duration || '0') || this.player.audio.duration;

        if (isNaN(currentTime) || isNaN(duration) || duration <= 0) return;

        const percent = (currentTime / duration) * 100;
        
        if (this.progressFilled) {
            this.progressFilled.style.width = `${percent}%`;
        }
        
        if (this.timeCurrent) {
            this.timeCurrent.textContent = this.player.formatTime(currentTime);
        }
    }

    updateProgress() {
        const currentTime = this.player.audio.currentTime;
        const container = document.querySelector('.audio-player-section');
        const duration = parseFloat(container?.dataset.duration || '0') || this.player.audio.duration;

        if (isNaN(currentTime) || isNaN(duration) || duration <= 0) return;

        if (this.timeCurrent) {
            this.timeCurrent.textContent = this.player.formatTime(currentTime);
        }

        if (!this.isSeeking) {
            const percent = (currentTime / duration) * 100;
            
            if (this.progressFilled) {
                this.progressFilled.style.width = `${percent}%`;
            }
        }
    }

    updateTotalTime(duration) {
        if (isNaN(duration) || duration <= 0) return;
        
        if (this.timeTotal) {
            this.timeTotal.textContent = this.player.formatTime(duration);
        }
    }

    seek(e) {
        const container = document.querySelector('.audio-player-section');
        const duration = parseFloat(container?.dataset.duration || '0') || this.player.audio.duration;
        
        if (!this.player.isAudioReady || !duration || this.isSeeking) return;
        
        e.preventDefault();
        e.stopPropagation();
        
        const rect = this.progressBar.getBoundingClientRect();
        const clickX = e.clientX - rect.left;
        const percent = Math.max(0, Math.min(1, clickX / rect.width));
        const newTime = percent * duration;
        
        this.performSeek(newTime, percent);
    }

    performSeek(newTime, percent) {
        this.isSeeking = true;
        
        if (this.progressFilled) {
            this.progressFilled.style.width = `${percent * 100}%`;
        }
        if (this.timeCurrent) {
            this.timeCurrent.textContent = this.player.formatTime(newTime);
        }
        
        this.player.audio.currentTime = newTime;
        
        const onSeeked = () => {
            this.isSeeking = false;
            this.player.audio.removeEventListener('seeked', onSeeked);
            this.player.saveCurrentProgress();
        };
        
        this.player.audio.addEventListener('seeked', onSeeked);
        
        setTimeout(() => {
            if (this.isSeeking) {
                this.isSeeking = false;
                this.player.saveCurrentProgress();
            }
        }, 2000);
    }
}
