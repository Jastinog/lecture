export class AudioLoader {
    constructor() {
        this.currentRequest = null;
        this.onProgress = null;
        this.onComplete = null;
        this.onError = null;
        this.loadedBlobs = new Map();
    }

    async loadAudio(url) {
        // Check if already loaded
        if (this.loadedBlobs.has(url)) {
            const blob = this.loadedBlobs.get(url);
            return URL.createObjectURL(blob);
        }

        // Cancel previous request
        if (this.currentRequest) {
            this.currentRequest.abort();
        }

        return new Promise((resolve, reject) => {
            const xhr = new XMLHttpRequest();
            this.currentRequest = xhr;

            xhr.open('GET', url, true);
            xhr.responseType = 'blob';

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
                    this.loadedBlobs.set(url, blob);
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

    isLoaded(url) {
        return this.loadedBlobs.has(url);
    }

    abort() {
        if (this.currentRequest) {
            this.currentRequest.abort();
            this.currentRequest = null;
        }
    }

    clearCache() {
        // Revoke all object URLs to prevent memory leaks
        this.loadedBlobs.forEach((blob, url) => {
            if (url.startsWith('blob:')) {
                URL.revokeObjectURL(url);
            }
        });
        this.loadedBlobs.clear();
    }

    getCacheSize() {
        let totalSize = 0;
        this.loadedBlobs.forEach(blob => {
            totalSize += blob.size;
        });
        return {
            bytes: totalSize,
            mb: (totalSize / 1024 / 1024).toFixed(2),
            count: this.loadedBlobs.size
        };
    }
}
