class LecturePlayer {
    constructor() {
        this.audio = document.getElementById('audio-player');
        this.currentCard = null;
        this.isLoading = false;
        this.currentLectureId = null;
        this.progressUpdateInterval = null;
        this.lastSavedTime = 0;

        // Controls
        this.playPauseBtn = document.getElementById('btn-play-pause');
        this.prevBtn = document.getElementById('btn-prev');
        this.nextBtn = document.getElementById('btn-next');
        this.rewindBtn = document.getElementById('btn-rewind');
        this.forwardBtn = document.getElementById('btn-forward');

        // Progress
        this.progressBar = document.querySelector('.progress-bar');
        this.progressFilled = document.querySelector('.progress-filled');
        this.timeCurrent = document.querySelector('.time-current');
        this.timeTotal = document.querySelector('.time-total');
        this.nowPlayingTitle = document.querySelector('.now-playing-title');

        // Constants
        this.SKIP_SECONDS = 15;
        this.PROGRESS_UPDATE_INTERVAL = 5000; // 5 seconds

        this.init();
    }

    init() {
        // Card click handlers
        document.querySelectorAll('.lecture-card').forEach(card => {
            card.addEventListener('click', () => this.playLecture(card));
        });

        // Control buttons
        if (this.playPauseBtn) {
            this.playPauseBtn.addEventListener('click', (e) => {
                e.preventDefault();
                this.togglePlayPause();
            });
        }
        this.prevBtn?.addEventListener('click', () => this.playPrevious());
        this.nextBtn?.addEventListener('click', () => this.playNext());

        // ±15s handlers
        this.rewindBtn.addEventListener('click', () => {
            if (!this.audio.duration) return;
            this.audio.currentTime = Math.max(0, this.audio.currentTime - this.SKIP_SECONDS);
        });
        this.forwardBtn.addEventListener('click', () => {
            if (!this.audio.duration) return;
            this.audio.currentTime = Math.min(this.audio.duration, this.audio.currentTime + this.SKIP_SECONDS);
        });

        // Keyboard shortcuts
        document.addEventListener('keydown', (e) => {
            if (e.target && (e.target.tagName === 'INPUT' || e.target.tagName === 'TEXTAREA' || e.target.isContentEditable)) return;
            if (e.key.toLowerCase() === 'k' || e.code === 'Space') {
                e.preventDefault();
                this.togglePlayPause();
            } else if (e.key.toLowerCase() === 'j' || e.key === 'ArrowLeft') {
                e.preventDefault();
                if (!this.audio.duration) return;
                this.audio.currentTime = Math.max(0, this.audio.currentTime - this.SKIP_SECONDS);
            } else if (e.key.toLowerCase() === 'l' || e.key === 'ArrowRight') {
                e.preventDefault();
                if (!this.audio.duration) return;
                this.audio.currentTime = Math.min(this.audio.duration, this.audio.currentTime + this.SKIP_SECONDS);
            }
        });

        // Audio events
        this.audio.addEventListener('ended', () => this.onEnded());
        this.audio.addEventListener('pause', () => this.onPause());
        this.audio.addEventListener('play', () => this.onPlay());
        this.audio.addEventListener('timeupdate', () => this.updateProgress());
        this.audio.addEventListener('loadedmetadata', () => this.updateDuration());
        this.audio.addEventListener('canplay', () => this.onCanPlay());
        this.audio.addEventListener('loadstart', () => this.isLoading = true);

        // Page unload handler
        window.addEventListener('beforeunload', () => {
            this.saveCurrentProgress();
        });

        // Progress bar click-to-seek
        this.initProgressBar();
    }

    async playLecture(card) {
        const url = card.dataset.url;
        const title = card.dataset.title;
        const lectureId = parseInt(card.dataset.id);

        // Save progress of previous lecture
        if (this.currentLectureId && this.currentLectureId !== lectureId) {
            await this.saveCurrentProgress();
        }

        // If clicking the same card that's currently playing, pause it
        if (this.currentCard === card && !this.audio.paused) {
            this.audio.pause();
            return;
        }

        // If it's a different card or the same card but paused
        if (this.currentCard !== card) {
            this.audio.pause();
            this.audio.src = url;
            this.currentCard = card;
            this.currentLectureId = lectureId;
            this.nowPlayingTitle.textContent = title;
            this.isLoading = true;
        }

        // Play the audio
        try {
            await this.audio.play();
            this.updatePlaylistUI();
        } catch (error) {
            console.error('Play failed:', error);
            this.isLoading = false;
        }
    }

    onCanPlay() {
        if (this.isLoading) {
            this.isLoading = false;
        }
    }

    onPlay() {
        this.updatePlayPauseBtn(true);
        this.startProgressUpdates();
    }

    onPause() {
        this.updatePlayPauseBtn(false);
        this.stopProgressUpdates();
        this.saveCurrentProgress();
    }

    async onEnded() {
        // Mark as completed and save
        await this.saveCurrentProgress(true);
        this.playNext();
    }

    startProgressUpdates() {
        this.stopProgressUpdates(); // Clear any existing interval
        
        this.progressUpdateInterval = setInterval(() => {
            this.saveCurrentProgress();
        }, this.PROGRESS_UPDATE_INTERVAL);
    }

    stopProgressUpdates() {
        if (this.progressUpdateInterval) {
            clearInterval(this.progressUpdateInterval);
            this.progressUpdateInterval = null;
        }
    }

    async saveCurrentProgress(forceCompleted = false) {
        if (!this.currentLectureId || !this.audio.duration) return;

        const currentTime = this.audio.currentTime;
        const duration = this.audio.duration;
        
        // Only save if time changed significantly (avoid spam)
        if (Math.abs(currentTime - this.lastSavedTime) < 2 && !forceCompleted) return;

        try {
            const response = await fetch('/progress/', {
                method: 'POST',
                headers: {
                    'Content-Type': 'application/json',
                    'X-CSRFToken': this.getCSRFToken()
                },
                body: JSON.stringify({
                    lecture_id: this.currentLectureId,
                    current_time: currentTime,
                    duration: duration,
                    force_completed: forceCompleted
                })
            });

            if (response.ok) {
                const data = await response.json();
                this.updateLectureUI(this.currentLectureId, data);
                this.lastSavedTime = currentTime;
                console.log('Progress saved:', data);
            }
        } catch (error) {
            console.error('Failed to save progress:', error);
        }
    }

    updateLectureUI(lectureId, progressData) {
        const card = document.querySelector(`[data-id="${lectureId}"]`);
        if (!card) return;

        const progressBar = card.querySelector('.lecture-progress-filled');
        const statusBadge = card.querySelector('.status-badge');
        const listenCount = card.querySelector('.listen-count');

        if (progressBar) {
            progressBar.style.width = `${progressData.progress_percentage}%`;
            progressBar.className = progressData.completed ? 
                'lecture-progress-filled completed' : 
                'lecture-progress-filled in-progress';
        }

        if (statusBadge) {
            if (progressData.completed) {
                statusBadge.innerHTML = '<i class="fas fa-check"></i> Прослушано';
                statusBadge.className = 'status-badge status-completed';
            } else if (progressData.progress_percentage > 0) {
                statusBadge.innerHTML = `<i class="fas fa-play"></i> ${Math.round(progressData.progress_percentage)}%`;
                statusBadge.className = 'status-badge status-in-progress';
            }
        }

        if (listenCount) {
            listenCount.innerHTML = `<i class="fas fa-repeat"></i> ${progressData.listen_count}x`;
        }
    }

    getCSRFToken() {
        return document.querySelector('[name=csrfmiddlewaretoken]')?.value || 
               document.querySelector('meta[name=csrf-token]')?.getAttribute('content') || '';
    }

    togglePlayPause() {
        if (!this.currentCard) {
            const firstCard = document.querySelector('.lecture-card');
            if (firstCard) {
                this.playLecture(firstCard);
            }
            return;
        }

        if (this.audio.paused || this.audio.ended) {
            this.audio.play().catch(error => {
                console.error('Play failed:', error);
            });
        } else {
            this.audio.pause();
        }
    }

    playPrevious() {
        if (!this.currentCard) return;
        const prevCard = this.currentCard.previousElementSibling;
        if (prevCard?.classList.contains('lecture-card')) {
            this.playLecture(prevCard);
        }
    }

    playNext() {
        if (!this.currentCard) return;
        const nextCard = this.currentCard.nextElementSibling;
        if (nextCard?.classList.contains('lecture-card')) {
            this.playLecture(nextCard);
        }
    }

    updatePlaylistUI() {
        document.querySelectorAll('.lecture-card').forEach(card => {
            card.classList.remove('active');
            card.querySelector('.play-indicator')?.classList.add('hidden');
            card.querySelector('.play-btn')?.classList.remove('hidden');
        });

        if (this.currentCard) {
            this.currentCard.classList.add('active');
            this.currentCard.querySelector('.play-btn')?.classList.add('hidden');
            this.currentCard.querySelector('.play-indicator')?.classList.remove('hidden');
        }
    }

    updatePlayPauseBtn(isPlaying) {
        const icon = this.playPauseBtn?.querySelector('i');
        if (icon) {
            icon.className = isPlaying ? 'fas fa-pause' : 'fas fa-play';
        }
    }

    updateProgress() {
        if (!this.audio.duration) return;
        
        const percent = (this.audio.currentTime / this.audio.duration) * 100;
        this.progressFilled.style.width = `${percent}%`;
        this.timeCurrent.textContent = this.formatTime(this.audio.currentTime);
    }

    updateDuration() {
        this.timeTotal.textContent = this.formatTime(this.audio.duration);
    }

    formatTime(seconds) {
        if (isNaN(seconds)) return '0:00';
        const mins = Math.floor(seconds / 60);
        const secs = Math.floor(seconds % 60);
        return `${mins}:${secs.toString().padStart(2, '0')}`;
    }

    initProgressBar() {
        this.progressBar.addEventListener('click', (e) => this.seek(e));
    }

    seek(e) {
        if (!this.audio.duration) return;
        
        e.preventDefault();
        const rect = this.progressBar.getBoundingClientRect();
        const clickX = e.clientX - rect.left;
        const percent = Math.max(0, Math.min(1, clickX / rect.width));
        const newTime = percent * this.audio.duration;
        
        this.audio.currentTime = newTime;
        
        this.progressFilled.style.width = `${percent * 100}%`;
        this.timeCurrent.textContent = this.formatTime(newTime);
    }
}
