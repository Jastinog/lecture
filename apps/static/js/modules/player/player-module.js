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
        this.progressBar.updateLoadingProgress(data.percent);

        this.playlist.syncBufferState(data.percent);
    }

    onLoadComplete(data) {
        this.isFullyLoaded = true;
        this.hideLoadingState();

        this.playlist.syncBufferState(100);
    }

    onLoadError(error) {
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
        this.isAudioReady = false;
    }

    onMetadataLoaded() {
        const durationFromData = this.currentCard ? parseFloat(this.currentCard.dataset.duration || '0') : 0;
        if (durationFromData === 0) {
            this.progressBar.updateTotalTime(this.audio.duration);
        }
        
        if (this.targetSeekTime !== null && this.targetSeekTime > 0 && this.audio.duration) {
            if (this.audio.readyState >= 2) {
                setTimeout(() => {
                    this.applySavedPosition();
                }, 50);
            }
        }
    }

    onCanPlay() {
        console.log("Audio can start playing");
    }

    onCanPlayThrough() {
        if (this.isFullyLoaded && !this.isAudioReady) {
            this.isAudioReady = true;
            this.hideLoadingState();
            
            if (this.targetSeekTime !== null && this.targetSeekTime > 0) {
                setTimeout(() => {
                    this.applySavedPosition();
                }, 100);
            }
            
            if (this.pendingPlay) {
                this.pendingPlay = false;
                setTimeout(() => {
                    this.startPlayback();
                }, this.targetSeekTime > 0 ? 200 : 50);
            }
        }
    }

    applySavedPosition() {
        if (this.targetSeekTime !== null && this.targetSeekTime > 0 && this.audio.duration) {
            const validTime = Math.min(this.targetSeekTime, this.audio.duration - 1);
            
            this.audio.currentTime = validTime;
            this.targetSeekTime = null;
            
            setTimeout(() => {
                this.progressBar.forceUpdateProgress();
            }, 50);
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
                const isCompleted = container.dataset.completed === 'true';
                
                if (savedTime > 0 && !isCompleted) {
                    this.targetSeekTime = savedTime;
                    this.lastSavedTime = savedTime;
                } else {
                    this.targetSeekTime = 0;
                    this.lastSavedTime = 0;
                    
                    if (isCompleted) {
                        await this.resetCompletedLecture(parseInt(lectureId));
                    }
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
                this.showLoadingState('Подготовка из кеша...');
                this.isFullyLoaded = true;
                
                const objectURL = await this.audioLoader.loadAudio(this.currentLectureId);
                
                if (this.currentLectureId === parseInt(card.dataset.id)) {
                    this.audio.src = objectURL;
                }
            } else {
                this.isLoading = true;
                this.showLoadingState('Начинаем загрузку...');
                
                const objectURL = await this.audioLoader.loadAudio(this.currentLectureId);
                
                if (this.currentLectureId === parseInt(card.dataset.id)) {
                    this.audio.src = objectURL;
                }
            }
        } catch (error) {
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
        if (progress?.current_time > 0 && !progress.completed) {
            this.targetSeekTime = progress.current_time;
            this.lastSavedTime = progress.current_time;
        } else {
            this.targetSeekTime = 0;
            this.lastSavedTime = 0;
            
            if (progress?.completed) {
                await this.resetCompletedLecture(lectureId);
            }
        }

        await this.setupLecture(card, true);
        await this.setCurrentLecture(lectureId);
    }

    requestPlay() {
        if (!this.currentCard) {
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
        this.progressBar.updateProgress();
    }

    async loadProgress(lectureId) {
        try {
            const response = await fetch(`/api/v1/lectures/${lectureId}/progress/`, {
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
            await fetch(`/api/v1/lectures/${lectureId}/set-current/`, {
                method: 'POST',
                headers: {
                    'Content-Type': 'application/json',
                    'X-CSRFToken': this.getCSRFToken()
                },
                body: JSON.stringify({})
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

    async saveCurrentProgress(completed = false) {
        if (!this.currentLectureId || !this.isAudioReady || !this.isFullyLoaded) return;

        const currentTime = this.audio.currentTime;
        const durationFromData = this.currentCard ? parseFloat(this.currentCard.dataset.duration || '0') : 0;
        const duration = durationFromData > 0 ? durationFromData : this.audio.duration;
        
        if (!duration) return;
        
        if (Math.abs(currentTime - this.lastSavedTime) < 2 && !completed) return;

        try {
            const response = await fetch(`/api/v1/lectures/${this.currentLectureId}/progress/`, {
                method: 'POST',
                headers: {
                    'Content-Type': 'application/json',
                    'X-CSRFToken': this.getCSRFToken()
                },
                body: JSON.stringify({
                    current_time: currentTime,
                    completed: completed
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

    async resetCompletedLecture(lectureId) {
        try {
            const response = await fetch(`/api/v1/lectures/${lectureId}/progress/`, {
                method: 'POST',
                headers: {
                    'Content-Type': 'application/json',
                    'X-CSRFToken': this.getCSRFToken()
                },
                body: JSON.stringify({
                    current_time: 0,
                    completed: false
                })
            });

            if (response.ok) {
                const data = await response.json();
                this.playlist.updateLectureUI(lectureId, data);
                console.log('Completed lecture reset to beginning');
            }
        } catch (error) {
            console.error('Failed to reset completed lecture:', error);
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
