export class PlaylistManager {
    constructor(player) {
        this.player = player;
    }

    init() {
        document.querySelectorAll('.card-item').forEach(card => {
            card.addEventListener('click', (e) => {
                if (e.target.closest('.favorite-btn')) {
                    return;
                }
                
                e.preventDefault();
                this.player.playLecture(card);
            });
        });
    }

    loadFirstIncompleteLecture() {
        const cards = document.querySelectorAll('.card-item');
        
        for (const card of cards) {
            const badge = card.querySelector('.status-badge');
            if (!badge?.classList.contains('status-completed')) {
                this.player.setupLecture(card, false);
                return;
            }
        }
        
        if (cards[0]) {
            this.player.setupLecture(cards[0], false);
        }
    }

    playPrevious() {
        if (!this.player.currentCard) return;
        const prev = this.player.currentCard.previousElementSibling;
        if (prev?.classList.contains('card-item')) {
            this.player.playLecture(prev);
        }
    }

    playNext() {
        if (!this.player.currentCard) return;
        const next = this.player.currentCard.nextElementSibling;
        if (next?.classList.contains('card-item')) {
            this.player.playLecture(next);
        }
    }

    updateUI() {
        document.querySelectorAll('.card-item').forEach(card => {
            card.classList.toggle('active', card === this.player.currentCard);
        });
    }

    syncBufferState(percent) {
        if (!this.player.currentCard) return;
        
        const bufferIndicator = this.player.currentCard.querySelector('.card-buffer-indicator');
        if (bufferIndicator) {
            bufferIndicator.style.width = `${Math.min(100, percent)}%`;
        }
    }

    syncPlaybackProgress(currentTime, duration) {
        if (!this.player.currentCard) return;
        
        const progressFill = this.player.currentCard.querySelector('.progress-bar-fill');
        if (!progressFill || !duration || duration <= 0) return;

        const percent = (currentTime / duration) * 100;
        progressFill.style.width = `${Math.min(100, percent)}%`;
        
        // Обновляем класс для визуального отличия от статического прогресса
        progressFill.className = 'progress-bar-fill in-progress playing';
    }

    updateLectureUI(lectureId, data) {
        const card = document.querySelector(`[data-id="${lectureId}"]`);
        if (!card) return;

        const progressBar = card.querySelector('.progress-bar-fill');
        const statusBadge = card.querySelector('.status-badge');
        const listenCount = card.querySelector('.listen-count');

        if (progressBar) {
            // Если это активная карточка и она проигрывается, не перезаписываем живой прогресс
            const isActiveAndPlaying = card === this.player.currentCard && !this.player.audio.paused;
            
            if (!isActiveAndPlaying) {
                progressBar.style.width = `${data.progress_percentage}%`;
                progressBar.className = `progress-bar-fill ${data.completed ? 'completed' : 'in-progress'}`;
            }
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
}
