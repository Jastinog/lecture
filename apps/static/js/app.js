document.addEventListener('DOMContentLoaded', function() {
    if (document.querySelector('.audio-player-section')) {
        import('./modules/lecture-player/player-module.js').then(module => {
            window.lecturePlayer = new module.LecturePlayer();
        });
    }
});
