import { PlayerControls } from './player-controls.js';
import { ProgressBar } from './progress-bar.js';
import { PlayerHeader } from './player-header.js';
import { AudioLoader } from './audio-loader.js';
import { FavoriteHandler } from './favorite-handler.js';
import { ShareHandler } from './share-handler.js';
import { DownloadHandler } from './download-handler.js';
import { MarkersHandler } from './markers-handler.js';
// import { EqualizerVisualizer } from './equalizer-visualizer.js';

export class LecturePlayer {
    constructor() {
        this.audio = document.getElementById('audio-player');
        this.isLoading = false;
        this.lectureId = null;
        this.progressUpdateInterval = null;
        this.lastSavedTime = 0;
        this.targetSeekTime = null;
        this.isAudioReady = false;
        this.isFullyLoaded = false;
        this.pendingPlay = false;
        this.isIOS = /iPad|iPhone|iPod/.test(navigator.userAgent);

        this.SKIP_SECONDS = 15;
        this.PROGRESS_UPDATE_INTERVAL = 5000;

        this.audioLoader = new AudioLoader();
        this.setupAudioLoader();

        this.controls = new PlayerControls(this);
        this.progressBar = new ProgressBar(this);
        this.header = new PlayerHeader(this);
        this.favoriteHandler = new FavoriteHandler(this);
        this.shareHandler = new ShareHandler(this);
        this.downloadHandler = new DownloadHandler(this);
        this.markersHandler = new MarkersHandler(this);
        // this.equalizer = new EqualizerVisualizer(this);

        this.init();
        this.loadLecture();
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
        this.controls.updateLoadingProgress(data.percent);
    }

    onLoadComplete(data) {
        this.isFullyLoaded = true;
        this.isAudioReady = true;
        this.hideLoadingState();
        
        this.controls.setReadyState();
        
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

    onLoadError(error) {
        console.error('Load error:', error);
        this.isLoading = false;
        this.isFullyLoaded = false;
        this.isAudioReady = false;
        this.pendingPlay = false;
        this.hideLoadingState();
    }

    hideLoadingState() {
        this.progressBar.hideLoading();
    }

    init() {
        this.controls.init();
        this.progressBar.init();
        this.header.init();
        this.favoriteHandler.init();
        this.shareHandler.init();
        this.downloadHandler.init();
        this.markersHandler.init();
        // this.equalizer.init();

        // Audio events
        this.audio.addEventListener('loadstart', () => this.onLoadStart());
        this.audio.addEventListener('loadedmetadata', () => this.onMetadataLoaded());
        this.audio.addEventListener('loadeddata', () => this.onLoadedData());
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
        const container = document.querySelector('.audio-player-section');
        const duration = parseFloat(container?.dataset.duration || '0');
        
        if (duration === 0) {
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

    onLoadedData() {
        // Audio loaded
    }

    onCanPlay() {
        console.log("Audio can start playing");
    }

    onCanPlayThrough() {
        // Audio can play through
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

    async loadLecture() {
        const container = document.querySelector('.audio-player-section');
        if (!container) return;
        
        this.lectureId = parseInt(container.dataset.lectureId);
        const audioUrl = container.dataset.audioUrl;
        const duration = parseFloat(container.dataset.duration || '0');
        
        // Set target time from saved progress or URL parameter
        this.targetSeekTime = parseFloat(container.dataset.targetStartTime || '0') || 
                            parseFloat(container.dataset.currentTime || '0');
        this.lastSavedTime = this.targetSeekTime;

        if (duration > 0) {
            this.progressBar.updateTotalTime(duration);
        }

        if (!audioUrl) {
            this.onLoadError(new Error('No audio URL found'));
            return;
        }
        
        try {
            if (this.audioLoader.isLoaded(this.lectureId)) {
                this.isFullyLoaded = true;
                
                const objectURL = await this.audioLoader.loadAudio(this.lectureId, audioUrl);
                this.audio.src = objectURL;
                
                if (this.isIOS) {
                    this.audio.load();
                }
            } else {
                this.isLoading = true;
                
                const objectURL = await this.audioLoader.loadAudio(this.lectureId, audioUrl);
                this.audio.src = objectURL;
                
                if (this.isIOS) {
                    this.audio.load();
                }
            }
        } catch (error) {
            this.onLoadError(error);
        }
    }

    requestPlay() {
        if (this.isAudioReady && this.isFullyLoaded) {
            this.startPlayback();
        } else {
            this.pendingPlay = true;
        }
    }

    requestPause() {
        this.pendingPlay = false;
        if (this.isAudioReady && this.isFullyLoaded) {
            this.audio.pause();
        }
    }

    onTimeUpdate() {
        this.progressBar.updateProgress();
    }

    onSeeked() {
        this.progressBar.updateProgress();
        // Force save progress after seek
        this.saveCurrentProgress();
    }

    onPlay() {
        this.controls.updatePlayPauseBtn(true);
        this.startProgressUpdates();
    }

    onPause() {
        this.controls.updatePlayPauseBtn(false);
        this.stopProgressUpdates();
        // Save progress immediately on pause
        this.saveCurrentProgress();
    }

    async onEnded() {
        await this.saveCurrentProgress(true);
    }

    onError(e) {
        if (!this.audio.src || !this.lectureId) {
            return;
        }
        
        console.error('Audio error:', e);
        
        this.audioLoader.abort();
        
        this.isLoading = false;
        this.isAudioReady = false;
        this.isFullyLoaded = false;
        this.pendingPlay = false;
        this.hideLoadingState();
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
        }
    }

    async saveCurrentProgress(completed = false) {
        if (!this.lectureId) {
            console.log('No lecture ID for progress save');
            return;
        }

        if (!this.audio || !this.audio.src) {
            console.log('No audio source for progress save');
            return;
        }

        const currentTime = this.audio.currentTime || 0;
        const container = document.querySelector('.audio-player-section');
        const duration = parseFloat(container?.dataset.duration || '0') || this.audio.duration;
        
        if (!duration || duration <= 0) {
            console.log('No valid duration for progress save');
            return;
        }

        // Skip if time hasn't changed much (unless completed)
        if (Math.abs(currentTime - this.lastSavedTime) < 2 && !completed) {
            return;
        }

        console.log(`Saving progress: ${currentTime}s of ${duration}s (completed: ${completed})`);

        try {
            const response = await fetch(`/api/v1/lectures/${this.lectureId}/progress/`, {
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
                this.lastSavedTime = currentTime;
                console.log('Progress saved successfully:', data);
            } else {
                console.error('Failed to save progress:', response.status, response.statusText);
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
