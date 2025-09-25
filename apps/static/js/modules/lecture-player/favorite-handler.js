export class FavoriteHandler {
    constructor(player) {
        this.player = player;
    }

    init() {
        // Add event listeners to all favorite buttons
        document.addEventListener('click', (e) => {
            if (e.target.closest('.favorite-btn')) {
                e.preventDefault();
                e.stopPropagation();
                this.toggleFavorite(e.target.closest('.favorite-btn'));
            }
        });
    }

    async toggleFavorite(button) {
        const lectureId = button.dataset.lectureId;
        const isActive = button.classList.contains('active');

        try {
            const response = await fetch(`/api/v1/lectures/${lectureId}/favorite/`, {
                method: 'POST',
                headers: {
                    'Content-Type': 'application/json',
                    'X-CSRFToken': this.getCSRFToken()
                },
                body: JSON.stringify({
                    action: isActive ? 'remove' : 'add'
                })
            });

            if (response.ok) {
                button.classList.toggle('active', !isActive);
                
                // Update button text if it exists
                const btnText = button.querySelector('.btn-text');
                if (btnText) {
                    btnText.textContent = button.classList.contains('active') 
                        ? 'Убрать из избранного' 
                        : 'Добавить в избранное';
                }
                
                // Animate heart
                const icon = button.querySelector('i');
                if (!isActive && icon) {
                    icon.style.animation = 'favoriteAnimation 0.6s ease-in-out';
                    setTimeout(() => {
                        icon.style.animation = '';
                    }, 600);
                }
            }
        } catch (error) {
            console.error('Failed to toggle favorite:', error);
        }
    }

    getCSRFToken() {
        return document.querySelector('[name=csrfmiddlewaretoken]')?.value || 
               document.querySelector('meta[name=csrf-token]')?.content || '';
    }
}
