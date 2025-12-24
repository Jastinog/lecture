export class AudioLoader {
    constructor() {
        this.currentRequest = null;
        this.onProgress = null;
        this.onComplete = null;
        this.onError = null;
        this.loadedBlobs = new Map();
        this.maxCacheSize = 3; // Maximum number of lectures to keep in memory
    }

    /**
     * Enforce cache size limit (LRU - removes oldest entries)
     */
    enforceCacheLimit() {
        while (this.loadedBlobs.size >= this.maxCacheSize) {
            const oldestKey = this.loadedBlobs.keys().next().value;
            const oldBlob = this.loadedBlobs.get(oldestKey);
            // Revoke old object URL to free memory
            if (oldBlob) {
                URL.revokeObjectURL(URL.createObjectURL(oldBlob));
            }
            this.loadedBlobs.delete(oldestKey);
        }
    }

    async loadAudio(lectureId, directUrl) {
        // Check if already loaded - move to end (most recent)
        if (this.loadedBlobs.has(lectureId)) {
            const blob = this.loadedBlobs.get(lectureId);
            // Move to end for LRU
            this.loadedBlobs.delete(lectureId);
            this.loadedBlobs.set(lectureId, blob);
            return URL.createObjectURL(blob);
        }

        // Cancel previous request
        if (this.currentRequest) {
            this.currentRequest.abort();
        }

        if (!directUrl) {
            throw new Error('Direct URL is required');
        }

        return new Promise((resolve, reject) => {
            const xhr = new XMLHttpRequest();
            this.currentRequest = xhr;

            xhr.open('GET', directUrl, true);
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

                    // Enforce cache limit before adding new entry
                    this.enforceCacheLimit();
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
