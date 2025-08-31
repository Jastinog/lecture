import { PlaylistManager } from './playlist-manager.js';
import { PlayerControls } from './player-controls.js';
import { ProgressBar } from './progress-bar.js';
import { PlayerHeader } from './player-header.js';
import { AudioLoader } from './audio-loader.js';
import { FavoriteHandler } from './favorite-handler.js';

export class LecturePlayer {
    constructor() {
        this.audio = document.getElementById('audio-player');
        this.currentCard = null;
        this.isLoading = false;
        this.currentLectureId = null;
        this.progressUpdateInterval = null;
        this.lastSavedTime = 0;
        this.targetSeekTime = null;
        this.isAudioReady = false;
        this.isFullyLoaded = false;
        this.pendingPlay = false;

        // Constants
        this.SKIP_SECONDS = 15;
        this.PROGRESS_UPDATE_INTERVAL = 5000;

        // Initialize AudioLoader
        this.audioLoader = new AudioLoader();
        this.setupAudioLoader();

        // Initialize modules
        this.playlist = new PlaylistManager(this);
        this.controls = new PlayerControls(this);
        this.progressBar = new ProgressBar(this);
        this.header = new PlayerHeader(this);
        this.favoriteHandler = new FavoriteHandler(this);

        this.init();
        this.loadCurrentLecture();
    }

    setupAudioLoader() {
        this.audioLoader.onProgress = (data) => {
            this.onLoadProgress(data);
        };

        this.audioLoader.onComplete = (data) => {
            this.onLoadComplete(data);
        };

        this.audioLoader.onError = (error) => {
            this.onLoadError(error);
        };
    }

    onLoadProgress(data) {
        console.log(`Loading: ${data.percent.toFixed(1)}% (${data.loadedMB}MB / ${data.totalMB}MB)`);
        this.progressBar.updateLoadingProgress(data.percent);
        this.showLoadingState(`Загрузка ${data.percent.toFixed(0)}%`);
    }

    onLoadComplete(data) {
        console.log(`Audio loaded: ${data.sizeMB}MB`);
        this.isFullyLoaded = true;
        this.hideLoadingState();
    }

    onLoadError(error) {
        console.error('Audio loading failed:', error);
        this.isLoading = false;
        this.isFullyLoaded = false;
        this.isAudioReady = false;
        this.pendingPlay = false;
        this.hideLoadingState();
        this.showError('Ошибка загрузки аудио');
    }

    showLoadingState(message = 'Загрузка...') {
        this.progressBar.showLoading(message);
    }

    hideLoadingState() {
        this.progressBar.hideLoading();
    }

    showError(message) {
        console.error(message);
    }

    init() {
        this.playlist.init();
        this.controls.init();
        this.progressBar.init();
        this.header.init();
        this.favoriteHandler.init();

        // Audio events
        this.audio.addEventListener('loadstart', () => this.onLoadStart());
        this.audio.addEventListener('loadedmetadata', () => this.onMetadataLoaded());
        this.audio.addEventListener('canplay', () => this.onCanPlay());
        this.audio.addEventListener('canplaythrough', () => this.onCanPlayThrough());
        this.audio.addEventListener('timeupdate', () => this.onTimeUpdate());
        this.audio.addEventListener('seeked', () => this.onSeeked());
        this.audio.addEventListener('ended', () => this.onEnded());
        this.audio.addEventListener('pause', () => this.onPause());
        this.audio.addEventListener('play', () => this.onPlay());
        this.audio.addEventListener('error', (e) => this.onError(e));

        window.addEventListener('beforeunload', () => {
            this.saveCurrentProgress();
            this.audioLoader.clearCache();
        });
    }

    onLoadStart() {
        console.log("Audio load started");
        this.isAudioReady = false;
    }

    onMetadataLoaded() {
        console.log("Metadata loaded, duration:", this.audio.duration);
        const durationFromData = this.currentCard ? parseFloat(this.currentCard.dataset.duration || '0') : 0;
        if (durationFromData === 0) {
            this.progressBar.updateTotalTime(this.audio.duration);
        }
    }

    onCanPlay() {
        console.log("Audio can start playing");
    }

    onCanPlayThrough() {
        console.log("Audio can play through without buffering");
        
        // Only mark as ready when audio is fully loaded and not already ready
        if (this.isFullyLoaded && !this.isAudioReady) {
            this.isAudioReady = true;
            this.hideLoadingState();
            
            // Apply saved position
            this.applySavedPosition();
            
            // Now audio is ready for playback
            if (this.pendingPlay) {
                this.pendingPlay = false;
                this.startPlayback();
            }
        }
    }

    applySavedPosition() {
        if (this.targetSeekTime !== null && this.targetSeekTime > 0) {
            console.log("Applying saved position:", this.targetSeekTime);
            this.audio.currentTime = this.targetSeekTime;
            this.targetSeekTime = null;
            this.progressBar.updateProgress();
        }
    }

    async startPlayback() {
        if (this.isAudioReady && this.isFullyLoaded) {
            try {
                await this.audio.play();
            } catch (e) {
                console.error('Playback failed:', e);
            }
        }
    }

    async loadCurrentLecture() {
        const container = document.querySelector('.audio-player-section');
        const lectureId = container?.dataset.currentLectureId;
        
        if (lectureId) {
            const card = document.querySelector(`[data-id="${lectureId}"]`);
            if (card) {
                const savedTime = parseFloat(container.dataset.currentTime || '0');
                console.log("Loading current lecture with saved time:", savedTime);

                if (savedTime > 0) {
                    this.targetSeekTime = savedTime;
                    this.lastSavedTime = savedTime;
                }
                
                await this.setupLecture(card, false);
                return;
            }
        }
        
        this.playlist.loadFirstIncompleteLecture();
    }

    async setupLecture(card, requestPlay = false) {
        this.stopCurrentAudio();
        
        await new Promise(resolve => setTimeout(resolve, 100));
        
        this.currentCard = card;
        this.currentLectureId = parseInt(card.dataset.id);
        this.isAudioReady = false;
        this.isFullyLoaded = false;
        this.pendingPlay = requestPlay;
        this.isLoading = false;
        
        const durationFromData = parseFloat(card.dataset.duration || '0');
        if (durationFromData > 0) {
            this.progressBar.updateTotalTime(durationFromData);
        }
        
        this.header.updateNowPlaying(card.dataset.title);
        this.playlist.updateUI();
        
        try {
            if (this.audioLoader.isLoaded(this.currentLectureId)) {
                console.log("Audio already loaded from cache");
                this.showLoadingState('Подготовка из кеша...');
                this.isFullyLoaded = true;
                
                const objectURL = await this.audioLoader.loadAudio(this.currentLectureId);
                
                if (this.currentLectureId === parseInt(card.dataset.id)) {
                    this.audio.src = objectURL;
                    // Audio will trigger canplaythrough after load()
                }
            } else {
                console.log("Loading full audio file...");
                this.isLoading = true;
                this.showLoadingState('Начинаем загрузку...');
                
                const objectURL = await this.audioLoader.loadAudio(this.currentLectureId);
                
                if (this.currentLectureId === parseInt(card.dataset.id)) {
                    this.audio.src = objectURL;
                    // Wait for onLoadComplete to set isFullyLoaded = true
                }
            }
        } catch (error) {
            console.error('Failed to setup lecture:', error);
            if (this.currentLectureId === parseInt(card.dataset.id)) {
                this.onLoadError(error);
            }
        }
    }

    stopCurrentAudio() {
        this.audioLoader.abort();
        
        if (!this.audio.paused) {
            this.audio.pause();
        }
        this.audio.currentTime = 0;
        this.audio.src = '';
        
        this.stopProgressUpdates();
        this.progressBar.resetForNewLecture();
        
        this.isLoading = false;
        this.isAudioReady = false;
        this.isFullyLoaded = false;
        this.pendingPlay = false;
        this.hideLoadingState();
    }

    async playLecture(card) {
        const lectureId = parseInt(card.dataset.id);
        
        if (this.currentLectureId && this.currentLectureId !== lectureId) {
            await this.saveCurrentProgress();
        }

        if (this.currentCard === card) {
            if (this.isAudioReady && this.isFullyLoaded) {
                this.controls.togglePlayPause();
            }
            return;
        }

        const progress = await this.loadProgress(lectureId);
        if (progress?.current_time > 0) {
            this.targetSeekTime = progress.current_time;
            this.lastSavedTime = progress.current_time;
        } else {
            this.targetSeekTime = null;
        }

        await this.setupLecture(card, true);
        await this.setCurrentLecture(lectureId);
    }

    requestPlay() {
        if (!this.currentCard) {
            // Updated selector: .lecture-card → .card-item
            const firstCard = document.querySelector('.card-item');
            if (firstCard) this.playLecture(firstCard);
            return;
        }

        if (this.isAudioReady && this.isFullyLoaded) {
            this.startPlayback();
        } else {
            this.pendingPlay = true;
            this.showLoadingState('Подготовка к воспроизведению...');
        }
    }

    requestPause() {
        this.pendingPlay = false;
        if (this.isAudioReady && this.isFullyLoaded) {
            this.audio.pause();
        }
    }

    onTimeUpdate() {
        if (this.isAudioReady && this.isFullyLoaded) {
            this.progressBar.updateProgress();
        }
    }

    onSeeked() {
        console.log("Seeked event, current time:", this.audio.currentTime);
        this.progressBar.updateProgress();
    }

    async loadProgress(lectureId) {
        try {
            // Fixed API path
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
            // Fixed API path
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

    onPlay() {
        this.controls.updatePlayPauseBtn(true);
        this.startProgressUpdates();
    }

    onPause() {
        this.controls.updatePlayPauseBtn(false);
        this.stopProgressUpdates();
    }

    async onEnded() {
        await this.saveCurrentProgress(true);
        this.playlist.playNext();
    }

    onError(e) {
        // Ignore errors from empty audio element or when no audio is loaded
        if (!this.audio.src || !this.currentLectureId) {
            return;
        }
        
        console.error('Audio error:', e);
        
        this.audioLoader.abort();
        
        this.isLoading = false;
        this.isAudioReady = false;
        this.isFullyLoaded = false;
        this.pendingPlay = false;
        this.hideLoadingState();
        this.showError('Ошибка воспроизведения');
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
            this.saveCurrentProgress();
        }
    }

    async saveCurrentProgress(forceCompleted = false) {
        if (!this.currentLectureId || !this.isAudioReady || !this.isFullyLoaded) return;

        const currentTime = this.audio.currentTime;
        const durationFromData = this.currentCard ? parseFloat(this.currentCard.dataset.duration || '0') : 0;
        const duration = durationFromData > 0 ? durationFromData : this.audio.duration;
        
        if (!duration) return;
        
        if (Math.abs(currentTime - this.lastSavedTime) < 2 && !forceCompleted) return;

        try {
            // Fixed API path
            const response = await fetch('/api/progress/', {
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
                this.playlist.updateLectureUI(this.currentLectureId, data);
                this.lastSavedTime = currentTime;
            }
        } catch (error) {
            console.error('Failed to save progress:', error);
        }
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
