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
        });
        this.player.audio.addEventListener('canplaythrough', () => {
            this.isLoadingComplete = true;
            this.updateBuffer();
        });
    }

    showLoading(message = 'Загрузка...') {
        if (this.loadingIndicator) {
            this.loadingIndicator.textContent = message;
            this.loadingIndicator.style.display = 'block';
        }
        
        if (this.progressBar) {
            this.progressBar.style.pointerEvents = 'none';
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

    reset() {
        if (this.progressFilled) {
            this.progressFilled.style.width = '0%';
        }
        if (this.timeCurrent) {
            this.timeCurrent.textContent = '0:00';
        }
        if (this.timeTotal) {
            this.timeTotal.textContent = '0:00';
        }
        this.hideLoading();
        this.isLoadingComplete = false;
    }

    resetBuffer() {
        if (this.bufferIndicator) {
            this.bufferIndicator.style.width = '0%';
        }
    }

    resetForNewLecture() {
        this.resetBuffer();
        this.isLoadingComplete = false;
        if (this.progressFilled) {
            this.progressFilled.style.width = '0%';
        }
        if (this.timeCurrent) {
            this.timeCurrent.textContent = '0:00';
        }
        if (this.timeTotal) {
            this.timeTotal.textContent = '0:00';
        }
    }

    updateBuffer() {
        if (!this.bufferIndicator) return;

        if (this.player.currentLectureId && this.player.audioLoader.isLoaded(this.player.currentLectureId)) {
            this.bufferIndicator.style.width = '100%';
            // Синхронизация буфера с активной карточкой
            this.player.playlist.syncBufferState(100);
            return;
        }

        if (!this.player.audio.duration) return;

        const buffered = this.player.audio.buffered;
        let maxBufferedEnd = 0;
        
        for (let i = 0; i < buffered.length; i++) {
            maxBufferedEnd = Math.max(maxBufferedEnd, buffered.end(i));
        }
        
        const bufferPercent = Math.min(100, (maxBufferedEnd / this.player.audio.duration) * 100);
        this.bufferIndicator.style.width = `${bufferPercent}%`;
        
        // Синхронизация буфера с активной карточкой
        this.player.playlist.syncBufferState(bufferPercent);
    }

    updateLoadingProgress(percent) {
        if (!this.bufferIndicator) return;
        if (!this.isLoadingComplete && 
            !(this.player.currentLectureId && this.player.audioLoader.isLoaded(this.player.currentLectureId))) {
            this.bufferIndicator.style.width = `${percent}%`;
            // Синхронизация загрузки с активной карточкой
            this.player.playlist.syncBufferState(percent);
        }
    }

    forceUpdateProgress() {
        const currentTime = this.player.audio.currentTime;
        const durationFromData = this.player.currentCard ? parseFloat(this.player.currentCard.dataset.duration || '0') : 0;
        const duration = durationFromData > 0 ? durationFromData : this.player.audio.duration;

        if (isNaN(currentTime) || isNaN(duration) || duration <= 0) return;

        const percent = (currentTime / duration) * 100;
        
        if (this.progressFilled) {
            this.progressFilled.style.width = `${percent}%`;
        }
        
        if (this.timeCurrent) {
            this.timeCurrent.textContent = this.player.formatTime(currentTime);
        }

        // Синхронизация с активной карточкой
        this.player.playlist.syncPlaybackProgress(currentTime, duration);
    }

    updateProgress() {
        if (!this.player.isAudioReady) return;

        const currentTime = this.player.audio.currentTime;
        const durationFromData = this.player.currentCard ? parseFloat(this.player.currentCard.dataset.duration || '0') : 0;
        const duration = durationFromData > 0 ? durationFromData : this.player.audio.duration;

        if (isNaN(currentTime) || isNaN(duration) || duration <= 0) return;

        if (!this.isSeeking) {
            const percent = (currentTime / duration) * 100;
            
            if (this.progressFilled) {
                this.progressFilled.style.width = `${percent}%`;
            }
            
            if (this.timeCurrent) {
                this.timeCurrent.textContent = this.player.formatTime(currentTime);
            }

            // Синхронизация с активной карточкой в реальном времени
            this.player.playlist.syncPlaybackProgress(currentTime, duration);
        }
    }

    updateTotalTime(duration) {
        if (isNaN(duration) || duration <= 0) return;
        
        if (this.timeTotal) {
            this.timeTotal.textContent = this.player.formatTime(duration);
        }
    }

    seek(e) {
        const durationFromData = this.player.currentCard ? parseFloat(this.player.currentCard.dataset.duration || '0') : 0;
        const duration = durationFromData > 0 ? durationFromData : this.player.audio.duration;
        
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

        // Синхронизация с активной карточкой
        const duration = this.player.currentCard ? parseFloat(this.player.currentCard.dataset.duration || '0') : this.player.audio.duration;
        this.player.playlist.syncPlaybackProgress(newTime, duration);
        
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
