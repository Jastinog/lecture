// В progress-bar.js
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
        
        this.bufferIndicator = document.createElement('div');
        this.bufferIndicator.className = 'progress-buffer';
        this.bufferIndicator.style.cssText = `
            position: absolute;
            top: 0;
            left: 0;
            height: 100%;
            background: #6B7280;
            width: 0%;
            z-index: 1;
        `;
        
        this.progressBar.insertBefore(this.bufferIndicator, this.progressFilled);
        this.progressFilled.style.zIndex = '2';
        this.progressFilled.style.position = 'relative';
    }

    init() {
        this.progressBar?.addEventListener('click', (e) => this.seek(e));
        
        // Используем событие progress для отслеживания буферизации
        this.player.audio.addEventListener('progress', () => this.updateBuffer());
    }

    updateBuffer() {
        if (!this.player.audio.duration || !this.bufferIndicator) return;

        const buffered = this.player.audio.buffered;
        let bufferedEnd = 0;
        
        // Находим буферизованный участок, содержащий текущую позицию
        const currentTime = this.player.audio.currentTime;
        
        for (let i = 0; i < buffered.length; i++) {
            if (buffered.start(i) <= currentTime && buffered.end(i) >= currentTime) {
                bufferedEnd = buffered.end(i);
                break;
            }
            // Если текущая позиция впереди всех буферов, берем максимальный
            if (buffered.end(i) > bufferedEnd) {
                bufferedEnd = buffered.end(i);
            }
        }
        
        const bufferPercent = (bufferedEnd / this.player.audio.duration) * 100;
        this.bufferIndicator.style.width = `${bufferPercent}%`;
        
        console.log(`Buffer: ${bufferedEnd.toFixed(1)}s / ${this.player.audio.duration.toFixed(1)}s (${bufferPercent.toFixed(1)}%)`);
        
        // Проверяем готовность для seek
        if (this.player.targetSeekTime && bufferedEnd >= this.player.targetSeekTime && !this.player.isSeekingToTarget) {
            console.log(`Buffer ready for seek: ${bufferedEnd} >= ${this.player.targetSeekTime}`);
            this.player.onBufferReady();
        }
    }

    // Добавляем метод для принудительной буферизации до определенного времени
    async waitForBuffer(targetTime, timeout = 30000) {
        return new Promise((resolve, reject) => {
            const startTime = Date.now();
            
            const checkBuffer = () => {
                if (Date.now() - startTime > timeout) {
                    reject(new Error('Buffer timeout'));
                    return;
                }
                
                const buffered = this.player.audio.buffered;
                let isBuffered = false;
                
                for (let i = 0; i < buffered.length; i++) {
                    if (buffered.start(i) <= targetTime && buffered.end(i) >= targetTime) {
                        isBuffered = true;
                        break;
                    }
                }
                
                if (isBuffered) {
                    resolve();
                } else {
                    setTimeout(checkBuffer, 100);
                }
            };
            
            checkBuffer();
        });
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
        
        // Проверяем, есть ли буфер для этого времени
        const buffered = this.player.audio.buffered;
        let canSeek = false;
        
        for (let i = 0; i < buffered.length; i++) {
            if (buffered.start(i) <= newTime && buffered.end(i) >= newTime) {
                canSeek = true;
                break;
            }
        }
        
        if (canSeek) {
            // Можем искать сразу
            this.performSeek(newTime);
        } else {
            // Ждем буферизации
            console.log("Waiting for buffer before seek...");
            this.waitForBuffer(newTime, 10000)
                .then(() => this.performSeek(newTime))
                .catch(() => {
                    console.log("Buffer timeout, seeking anyway");
                    this.performSeek(newTime);
                });
        }
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
