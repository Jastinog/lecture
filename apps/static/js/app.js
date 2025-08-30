document.addEventListener('DOMContentLoaded', function() {
    // Initialize lecture player if on player page
    if (document.querySelector('.lecture-player')) {
        import('./modules/player/player-module.js').then(module => {
            window.lecturePlayer = new module.LecturePlayer();
        });
    }
});
