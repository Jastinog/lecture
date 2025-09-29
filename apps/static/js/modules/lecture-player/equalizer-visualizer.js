export class EqualizerVisualizer {
    constructor(player) {
        this.player = player;
        this.container = document.getElementById('equalizer-visualizer');
        this.bands = [];
        this.animationFrame = null;
        this.isPlaying = false;
        
        this.audioContext = null;
        this.analyser = null;
        this.source = null;
        this.dataArray = null;
        this.isInitialized = false;
        
        // Діапазон частот (Hz)
        this.minFreq = 60;
        this.maxFreq = 14000;
    }

    init() {
        if (!this.container) return;
        
        const bandElements = this.container.querySelectorAll('.frequency-band');
        
        bandElements.forEach((band) => {
            const bars = band.querySelectorAll('.eq-bar');
            this.bands.push({
                bars: Array.from(bars),
                currentLevel: 0
            });
        });

        this.player.audio.addEventListener('play', () => this.start());
        this.player.audio.addEventListener('pause', () => this.stop());
        this.player.audio.addEventListener('ended', () => this.stop());
    }

    initAudioContext() {
        if (this.isInitialized) return;

        try {
            this.audioContext = new (window.AudioContext || window.webkitAudioContext)();
            this.analyser = this.audioContext.createAnalyser();
            this.analyser.fftSize = 512;
            
            this.source = this.audioContext.createMediaElementSource(this.player.audio);
            this.source.connect(this.analyser);
            this.analyser.connect(this.audioContext.destination);
            
            this.dataArray = new Uint8Array(this.analyser.frequencyBinCount);
            this.isInitialized = true;
        } catch (e) {
            console.error('Audio context error:', e);
        }
    }

    start() {
        if (!this.isInitialized) {
            this.initAudioContext();
        }

        if (this.audioContext?.state === 'suspended') {
            this.audioContext.resume();
        }

        this.isPlaying = true;
        this.container?.classList.add('playing');
        this.animate();
    }

    stop() {
        this.isPlaying = false;
        this.container?.classList.remove('playing');
        
        if (this.animationFrame) {
            cancelAnimationFrame(this.animationFrame);
            this.animationFrame = null;
        }

        this.bands.forEach(band => {
            band.bars.forEach(bar => bar.classList.remove('active'));
        });
    }

    animate() {
        if (!this.isPlaying || !this.analyser) return;

        this.analyser.getByteFrequencyData(this.dataArray);

        const bandCount = this.bands.length;
        const sampleRate = this.audioContext.sampleRate;
        const nyquist = sampleRate / 2;
        const binCount = this.dataArray.length;
        
        // Переводимо Hz в bin індекси
        const minBin = Math.floor((this.minFreq / nyquist) * binCount);
        const maxBin = Math.floor((this.maxFreq / nyquist) * binCount);
        const rangeBins = maxBin - minBin;
        const binsPerBand = Math.floor(rangeBins / bandCount);

        this.bands.forEach((band, index) => {
            const start = minBin + (index * binsPerBand);
            const end = start + binsPerBand;
            
            let sum = 0;
            for (let i = start; i < end; i++) {
                sum += this.dataArray[i] || 0;
            }
            const avg = sum / binsPerBand;
            
            const intensity = avg / 255;
            const activeCount = Math.floor(band.bars.length * intensity);
            
            band.bars.forEach((bar, barIndex) => {
                if (barIndex < activeCount) {
                    bar.classList.add('active');
                } else {
                    bar.classList.remove('active');
                }
            });
        });

        this.animationFrame = requestAnimationFrame(() => this.animate());
    }
}
