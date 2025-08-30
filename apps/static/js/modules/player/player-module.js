class LecturePlayer {
    constructor() {
        this.audio = document.getElementById('audio-player');
        this.currentCard = null;
        this.isLoading = false;
        this.currentLectureId = null;
        this.progressUpdateInterval = null;
        this.lastSavedTime = 0;
        this.seekTarget = null;  // Add this property

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
        this.isSeeking = false;

        // Constants
        this.SKIP_SECONDS = 15;
        this.PROGRESS_UPDATE_INTERVAL = 5000;

        this.init();
        this.loadCurrentLecture();
    }

    init() {
        // Card click handlers
        document.querySelectorAll('.lecture-card').forEach(card => {
            card.addEventListener('click', (e) => {
                e.preventDefault();
                this.playLecture(card);
            });
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
        this.rewindBtn?.addEventListener('click', () => this.skip(-this.SKIP_SECONDS));
        this.forwardBtn?.addEventListener('click', () => this.skip(this.SKIP_SECONDS));

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
                    this.skip(-this.SKIP_SECONDS);
                    break;
                case 'l':
                case 'arrowright':
                    e.preventDefault();
                    this.skip(this.SKIP_SECONDS);
                    break;
            }
        });

        // Audio events
        this.audio.addEventListener('ended', () => this.onEnded());
        this.audio.addEventListener('pause', () => this.onPause());
        this.audio.addEventListener('play', () => this.onPlay());
        this.audio.addEventListener('timeupdate', () => this.updateProgress());
        this.audio.addEventListener('loadedmetadata', () => this.onMetadataLoaded());
        this.audio.addEventListener('error', (e) => this.onError(e));

        // Page unload
        window.addEventListener('beforeunload', () => this.saveCurrentProgress());

        // Progress bar seek
        this.progressBar?.addEventListener('click', (e) => this.seek(e));
    }

    async loadCurrentLecture() {
        const container = document.querySelector('.audio-player-container');
        const lectureId = container?.dataset.currentLectureId;
        
        if (lectureId) {
            const card = document.querySelector(`[data-id="${lectureId}"]`);
            if (card) {
                this.setupLecture(card, false);
                
                // Restore saved position
                const savedTime = parseFloat(container.dataset.currentTime || '0');
                if (savedTime > 0) {
                    this.lastSavedTime = savedTime;
                    this.audio.currentTime = savedTime;
                }
                return;
            }
        }
        
        // Load first incomplete
        this.loadFirstIncompleteLecture();
    }

    loadFirstIncompleteLecture() {
        const cards = document.querySelectorAll('.lecture-card');
        
        for (const card of cards) {
            const badge = card.querySelector('.status-badge');
            if (!badge?.classList.contains('status-completed')) {
                this.setupLecture(card, false);
                return;
            }
        }
        
        // All completed - load first
        if (cards[0]) {
            this.setupLecture(cards[0], false);
        }
    }

    setupLecture(card, autoPlay = false) {
        this.currentCard = card;
        this.currentLectureId = parseInt(card.dataset.id);
        this.audio.src = card.dataset.url;
        this.nowPlayingTitle.textContent = card.dataset.title;
        this.updatePlaylistUI();
        
        if (autoPlay) {
            this.audio.play().catch(e => console.error('Autoplay failed:', e));
        }
    }

    async playLecture(card) {
        const lectureId = parseInt(card.dataset.id);
        
        // Save current progress if switching
        if (this.currentLectureId && this.currentLectureId !== lectureId) {
            await this.saveCurrentProgress();
        }

        // Toggle play/pause if same lecture
        if (this.currentCard === card) {
            this.togglePlayPause();
            return;
        }

        // Setup new lecture
        this.setupLecture(card, true);
        
        // Set as current on server
        await this.setCurrentLecture(lectureId);
        
        // Load saved progress
        const progress = await this.loadProgress(lectureId);
        if (progress?.current_time > 0) {
            this.audio.currentTime = progress.current_time;
            this.lastSavedTime = progress.current_time;
        }
    }

    async loadProgress(lectureId) {
        try {
            const response = await fetch(`/api/progress/?lecture_id=${lectureId}`, {
                headers: { 'X-CSRFToken': this.getCSRFToken() }
            });
            return response.ok ? await response.json() : null;
        } catch (error) {
            console.error('Failed to load progress:', error);
            return null;
        }
    }

    async setCurrentLecture(lectureId) {
        try {
            await fetch('/api/current-lecture/', {
                method: 'POST',
                headers: {
                    'Content-Type': 'application/json',
                    'X-CSRFToken': this.getCSRFToken()
                },
                body: JSON.stringify({ lecture_id: lectureId })
            });
        } catch (error) {
            console.error('Failed to set current lecture:', error);
        }
    }

    skip(seconds) {
        if (!this.audio.duration) return;
        this.audio.currentTime = Math.max(0, Math.min(this.audio.duration, this.audio.currentTime + seconds));
    }

    togglePlayPause() {
        if (!this.currentCard) {
            const firstCard = document.querySelector('.lecture-card');
            if (firstCard) this.playLecture(firstCard);
            return;
        }

        if (this.audio.paused) {
            this.audio.play().catch(e => console.error('Play failed:', e));
        } else {
            this.audio.pause();
        }
    }

    playPrevious() {
        if (!this.currentCard) return;
        const prev = this.currentCard.previousElementSibling;
        if (prev?.classList.contains('lecture-card')) {
            this.playLecture(prev);
        }
    }

    playNext() {
        if (!this.currentCard) return;
        const next = this.currentCard.nextElementSibling;
        if (next?.classList.contains('lecture-card')) {
            this.playLecture(next);
        }
    }

    onMetadataLoaded() {
        this.timeTotal.textContent = this.formatTime(this.audio.duration);
        
        // Restore position if needed
        if (this.lastSavedTime > 0 && this.audio.currentTime === 0) {
            this.audio.currentTime = this.lastSavedTime;
        }
    }

    onPlay() {
        this.updatePlayPauseBtn(true);
        this.startProgressUpdates();
    }

    onPause() {
        this.updatePlayPauseBtn(false);
        this.stopProgressUpdates();
        // Don't save here - will be saved by interval stop
    }

    async onEnded() {
        await this.saveCurrentProgress(true);
        this.playNext();
    }

    onError(e) {
        console.error('Audio error:', e);
        this.isLoading = false;
    }

    startProgressUpdates() {
        this.stopProgressUpdates();
        this.progressUpdateInterval = setInterval(() => {
            this.saveCurrentProgress();
        }, this.PROGRESS_UPDATE_INTERVAL);
    }

    stopProgressUpdates() {
        if (this.progressUpdateInterval) {
            clearInterval(this.progressUpdateInterval);
            this.progressUpdateInterval = null;
            this.saveCurrentProgress(); // Save once on stop
        }
    }

    async saveCurrentProgress(forceCompleted = false) {
        if (!this.currentLectureId || !this.audio.duration) return;

        const currentTime = this.audio.currentTime;
        
        // Skip if time hasn't changed significantly
        if (Math.abs(currentTime - this.lastSavedTime) < 2 && !forceCompleted) return;

        try {
            const response = await fetch('/api/progress/', {
                method: 'POST',
                headers: {
                    'Content-Type': 'application/json',
                    'X-CSRFToken': this.getCSRFToken()
                },
                body: JSON.stringify({
                    lecture_id: this.currentLectureId,
                    current_time: currentTime,
                    duration: this.audio.duration,
                    force_completed: forceCompleted
                })
            });

            if (response.ok) {
                const data = await response.json();
                this.updateLectureUI(this.currentLectureId, data);
                this.lastSavedTime = currentTime;
            }
        } catch (error) {
            console.error('Failed to save progress:', error);
        }
    }

    updateLectureUI(lectureId, data) {
        const card = document.querySelector(`[data-id="${lectureId}"]`);
        if (!card) return;

        const progressBar = card.querySelector('.lecture-progress-filled');
        const statusBadge = card.querySelector('.status-badge');
        const listenCount = card.querySelector('.listen-count');

        if (progressBar) {
            progressBar.style.width = `${data.progress_percentage}%`;
            progressBar.className = `lecture-progress-filled ${data.completed ? 'completed' : 'in-progress'}`;
        }

        if (statusBadge) {
            if (data.completed) {
                statusBadge.innerHTML = '<i class="fas fa-check"></i> Прослушано';
                statusBadge.className = 'status-badge status-completed';
            } else if (data.progress_percentage > 0) {
                statusBadge.innerHTML = `<i class="fas fa-play"></i> ${Math.round(data.progress_percentage)}%`;
                statusBadge.className = 'status-badge status-in-progress';
            }
        }

        if (listenCount) {
            listenCount.innerHTML = `<i class="fas fa-repeat"></i> ${data.listen_count}x`;
        }
    }

    updateProgress() {
        // Don't update if we're currently seeking
        if (this.isSeeking || !this.audio.duration) return;
        
        const percent = (this.audio.currentTime / this.audio.duration) * 100;
        this.progressFilled.style.width = `${percent}%`;
        this.timeCurrent.textContent = this.formatTime(this.audio.currentTime);
    }

    updatePlaylistUI() {
        document.querySelectorAll('.lecture-card').forEach(card => {
            card.classList.toggle('active', card === this.currentCard);
        });
    }

    updatePlayPauseBtn(isPlaying) {
        const icon = this.playPauseBtn?.querySelector('i');
        if (icon) {
            icon.className = isPlaying ? 'fas fa-pause' : 'fas fa-play';
        }
    }

    seek(e) {
        if (!this.audio.duration) return;
        
        e.preventDefault();
        e.stopPropagation();
        
        const rect = this.progressBar.getBoundingClientRect();
        const clickX = e.clientX - rect.left;
        const percent = Math.max(0, Math.min(1, clickX / rect.width));
        const newTime = percent * this.audio.duration;
        
        // Set seeking flag BEFORE changing time
        this.isSeeking = true;
        
        // Update UI immediately
        this.progressFilled.style.width = `${percent * 100}%`;
        this.timeCurrent.textContent = this.formatTime(newTime);
        
        // Store the target time to prevent race conditions
        this.seekTarget = newTime;
        
        // Set new time
        this.audio.currentTime = newTime;
        
        // Reset seeking flag only after seek actually completes
        const onSeeked = () => {
            this.isSeeking = false;
            this.seekTarget = null;
            this.audio.removeEventListener('seeked', onSeeked);
            this.audio.removeEventListener('seeking', onSeeking);
        };
        
        const onSeeking = () => {
            // Keep the visual in sync while seeking
            if (this.seekTarget !== null) {
                const percent = (this.seekTarget / this.audio.duration) * 100;
                this.progressFilled.style.width = `${percent}%`;
                this.timeCurrent.textContent = this.formatTime(this.seekTarget);
            }
        };
        
        this.audio.addEventListener('seeked', onSeeked);
        this.audio.addEventListener('seeking', onSeeking);
        
        // Fallback timeout in case events don't fire
        setTimeout(() => {
            if (this.isSeeking) {
                this.isSeeking = false;
                this.seekTarget = null;
            }
        }, 1000);
    }

    formatTime(seconds) {
        if (isNaN(seconds)) return '0:00';
        const m = Math.floor(seconds / 60);
        const s = Math.floor(seconds % 60);
        return `${m}:${s.toString().padStart(2, '0')}`;
    }

    getCSRFToken() {
        return document.querySelector('[name=csrfmiddlewaretoken]')?.value || 
               document.querySelector('meta[name=csrf-token]')?.content || '';
    }
}
