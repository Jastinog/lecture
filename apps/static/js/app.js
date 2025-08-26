document.addEventListener('DOMContentLoaded', function() {
    // Initialize lecture player if on player page
    if (document.querySelector('.lecture-player')) {
        window.lecturePlayer = new LecturePlayer();
    }
});
