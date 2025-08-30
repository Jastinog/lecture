export class PlayerHeader {
    constructor(player) {
        this.player = player;
        this.nowPlayingTitle = document.querySelector('.now-playing-title');
    }

    init() {
        // Any header-specific initialization can go here
    }

    updateNowPlaying(title) {
        if (this.nowPlayingTitle) {
            this.nowPlayingTitle.textContent = title;
        }
    }

    setPlaceholder() {
        if (this.nowPlayingTitle) {
            this.nowPlayingTitle.textContent = '- - -';
        }
    }
}
