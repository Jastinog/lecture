import { PlaylistManager } from './playlist-manager.js';
import { PlayerControls } from './player-controls.js';
import { ProgressBar } from './progress-bar.js';
import { PlayerHeader } from './player-header.js';
import { AudioLoader } from './audio-loader.js';

export class LecturePlayer {
    constructor() {
        this.audio = document.getElementById('audio-player');
        this.currentCard = null;
        this.isLoading = false;
        this.currentLectureId = null;
        this.progressUpdateInterval = null;
        this.lastSavedTime = 0;
        this.targetSeekTime = null;
        this.isSeekingToTarget = false;

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
        
        // Update loading indicator if exists
        const loadingIndicator = document.querySelector('.loading-indicator');
        if (loadingIndicator) {
            loadingIndicator.style.width = `${data.percent}%`;
        }
    }

    onLoadComplete(data) {
        console.log(`Audio loaded: ${data.sizeMB}MB`);
        this.isLoading = false;
        
        // Hide loading indicator
        const loadingIndicator = document.querySelector('.loading-indicator');
        if (loadingIndicator) {
            loadingIndicator.style.width = '0%';
        }
    }

    onLoadError(error) {
        console.error('Audio loading failed:', error);
        this.isLoading = false;
        
        // Show error message
        const status = document.querySelector('.now-playing-title');
        if (status) {
            status.textContent = 'Ошибка загрузки';
        }
    }

    init() {
        // Initialize all modules
        this.playlist.init();
        this.controls.init();
        this.progressBar.init();
        this.header.init();

        // Audio events
        this.audio.addEventListener('loadedmetadata', () => this.onMetadataLoaded());
        this.audio.addEventListener('canplay', () => this.onCanPlay());
        this.audio.addEventListener('timeupdate', () => this.onTimeUpdate());
        this.audio.addEventListener('seeked', () => this.onSeeked());
        this.audio.addEventListener('ended', () => this.onEnded());
        this.audio.addEventListener('pause', () => this.onPause());
        this.audio.addEventListener('play', () => this.onPlay());
        this.audio.addEventListener('error', (e) => this.onError(e));

        // Page unload
        window.addEventListener('beforeunload', () => {
            this.saveCurrentProgress();
            this.audioLoader.clearCache();
        });
    }

    async loadCurrentLecture() {
        const container = document.querySelector('.audio-player-container');
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

    async setupLecture(card, autoPlay = false) {
        this.currentCard = card;
        this.currentLectureId = parseInt(card.dataset.id);
        this.isSeekingToTarget = false;
        
        this.header.updateNowPlaying(card.dataset.title);
        this.playlist.updateUI();
        
        const url = card.dataset.url;
        
        try {
            // Check if already loaded
            if (this.audioLoader.isLoaded(url)) {
                console.log("Audio already loaded from cache");
                const objectURL = await this.audioLoader.loadAudio(url);
                this.audio.src = objectURL;
                this.audio.load();
            } else {
                console.log("Loading new audio file...");
                this.isLoading = true;
                this.showLoadingState();
                
                const objectURL = await this.audioLoader.loadAudio(url);
                this.audio.src = objectURL;
                this.audio.load();
            }

            if (autoPlay) {
                this.audio.play().catch(e => console.error('Autoplay failed:', e));
            }
        } catch (error) {
            console.error('Failed to setup lecture:', error);
            this.onLoadError(error);
        }
    }

    showLoadingState() {
        const status = document.querySelector('.now-playing-title');
        if (status) {
            status.textContent = 'Загрузка...';
        }
    }

    onMetadataLoaded() {
        console.log("Metadata loaded, duration:", this.audio.duration);
        this.progressBar.updateTotalTime(this.audio.duration);
    }

    onCanPlay() {
        console.log("Can play event");
        this.isLoading = false;
        
        // Seek to target time if needed
        if (this.targetSeekTime !== null && !this.isSeekingToTarget) {
            console.log("Seeking to target time:", this.targetSeekTime);
            this.isSeekingToTarget = true;
            this.audio.currentTime = this.targetSeekTime;
            
            const onSeeked = () => {
                console.log("Seek completed successfully, time:", this.audio.currentTime);
                this.audio.removeEventListener('seeked', onSeeked);
                this.finishSeeking();
            };
            
            this.audio.addEventListener('seeked', onSeeked);
            
            setTimeout(() => {
                if (this.isSeekingToTarget) {
                    console.log("Seek timeout, finishing anyway");
                    this.finishSeeking();
                }
            }, 1000);
        }
    }

    finishSeeking() {
        this.isSeekingToTarget = false;
        this.targetSeekTime = null;
        this.lastSavedTime = this.audio.currentTime;
        console.log("Seeking finished, final time:", this.audio.currentTime);
        this.progressBar.updateProgress();
    }

    onSeeked() {
        console.log("Seeked event, current time:", this.audio.currentTime);
    }

    onTimeUpdate() {
        if (!this.isSeekingToTarget) {
            this.progressBar.updateProgress();
        }
    }

    async playLecture(card) {
        const lectureId = parseInt(card.dataset.id);
        
        if (this.currentLectureId && this.currentLectureId !== lectureId) {
            await this.saveCurrentProgress();
        }

        if (this.currentCard === card) {
            this.controls.togglePlayPause();
            return;
        }

        // Load progress before setup
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
        console.error('Audio error:', e);
        this.isLoading = false;
        this.isSeekingToTarget = false;
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
        if (!this.currentLectureId || !this.audio.duration || this.isSeekingToTarget) return;

        const currentTime = this.audio.currentTime;
        
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
