export class AudioLoader {
    constructor() {
        this.currentRequest = null;
        this.onProgress = null;
        this.onComplete = null;
        this.onError = null;
        this.loadedBlobs = new Map();
    }

    async loadAudio(lectureId) {
        // Check if already loaded
        if (this.loadedBlobs.has(lectureId)) {
            const blob = this.loadedBlobs.get(lectureId);
            return URL.createObjectURL(blob);
        }

        // Cancel previous request
        if (this.currentRequest) {
            this.currentRequest.abort();
        }

        return new Promise((resolve, reject) => {
            const xhr = new XMLHttpRequest();
            this.currentRequest = xhr;

            // Fixed API path
            xhr.open('GET', `/api/v1/lectures/${lectureId}/audio/`, true);
            xhr.responseType = 'blob';

            const csrfToken = this.getCSRFToken();
            if (csrfToken) {
                xhr.setRequestHeader('X-CSRFToken', csrfToken);
            }

            xhr.onprogress = (e) => {
                if (e.lengthComputable && this.onProgress) {
                    const percent = (e.loaded / e.total) * 100;
                    const loadedMB = (e.loaded / 1024 / 1024).toFixed(2);
                    const totalMB = (e.total / 1024 / 1024).toFixed(2);
                    
                    this.onProgress({
                        percent,
                        loaded: e.loaded,
                        total: e.total,
                        loadedMB,
                        totalMB
                    });
                }
            };

            xhr.onload = () => {
                if (xhr.status === 200) {
                    const blob = xhr.response;
                    this.loadedBlobs.set(lectureId, blob);
                    const objectURL = URL.createObjectURL(blob);
                    
                    if (this.onComplete) {
                        this.onComplete({
                            url: objectURL,
                            size: blob.size,
                            sizeMB: (blob.size / 1024 / 1024).toFixed(2)
                        });
                    }
                    
                    resolve(objectURL);
                } else {
                    const error = new Error(`HTTP ${xhr.status}: ${xhr.statusText}`);
                    if (this.onError) this.onError(error);
                    reject(error);
                }
                this.currentRequest = null;
            };

            xhr.onerror = () => {
                const error = new Error('Network error');
                if (this.onError) this.onError(error);
                reject(error);
                this.currentRequest = null;
            };

            xhr.ontimeout = () => {
                const error = new Error('Request timeout');
                if (this.onError) this.onError(error);
                reject(error);
                this.currentRequest = null;
            };

            xhr.send();
        });
    }

    isLoaded(lectureId) {
        return this.loadedBlobs.has(lectureId);
    }

    abort() {
        if (this.currentRequest) {
            this.currentRequest.abort();
            this.currentRequest = null;
        }
    }

    clearCache() {
        this.loadedBlobs.forEach((blob, lectureId) => {
            URL.revokeObjectURL(URL.createObjectURL(blob));
        });
        this.loadedBlobs.clear();
    }

    getCSRFToken() {
        return document.querySelector('[name=csrfmiddlewaretoken]')?.value || 
               document.querySelector('meta[name=csrf-token]')?.content || '';
    }
}
