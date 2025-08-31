export class PlaylistManager {
    constructor(player) {
        this.player = player;
    }

    init() {
        // Updated selector: .lecture-card → .card-item
        document.querySelectorAll('.card-item').forEach(card => {
            card.addEventListener('click', (e) => {
                e.preventDefault();
                this.player.playLecture(card);
            });
        });
    }

    loadFirstIncompleteLecture() {
        // Updated selector: .lecture-card → .card-item
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
        // Updated selector: .lecture-card → .card-item
        if (prev?.classList.contains('card-item')) {
            this.player.playLecture(prev);
        }
    }

    playNext() {
        if (!this.player.currentCard) return;
        const next = this.player.currentCard.nextElementSibling;
        // Updated selector: .lecture-card → .card-item
        if (next?.classList.contains('card-item')) {
            this.player.playLecture(next);
        }
    }

    updateUI() {
        // Updated selector: .lecture-card → .card-item
        document.querySelectorAll('.card-item').forEach(card => {
            card.classList.toggle('active', card === this.player.currentCard);
        });
    }

    updateLectureUI(lectureId, data) {
        const card = document.querySelector(`[data-id="${lectureId}"]`);
        if (!card) return;

        // Updated selectors to match new CSS classes
        const progressBar = card.querySelector('.progress-bar-fill');
        const statusBadge = card.querySelector('.status-badge');
        const listenCount = card.querySelector('.listen-count');

        if (progressBar) {
            progressBar.style.width = `${data.progress_percentage}%`;
            progressBar.className = `progress-bar-fill ${data.completed ? 'completed' : 'in-progress'}`;
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
