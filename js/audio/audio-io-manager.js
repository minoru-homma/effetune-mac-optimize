/**
 * Prefix used to identify the non-fatal mic-denied warning returned by initAudioInput().
 * Callers (e.g. AudioManager._doReset) test against this prefix to distinguish a
 * recoverable mic-permission failure from a fatal context/output failure.  Keep this
 * exported so the prefix and the message stay coupled.
 */
export const MIC_DENIED_PREFIX = 'Audio Error: Microphone access denied';

/**
 * Local mirror of AudioManager.hdmiDebug (avoiding a circular import).
 * No-op unless userData/.hdmi-debug-enabled marker is present.
 */
function hdmiDebug(tag, message) {
    if (!window.electronAPI?.hdmiDebugEnabled) return;
    const line = `[hdmi-debug] [${tag}] ${message}`;
    try { console.log(line); } catch (_) { /* ignore */ }
    try { window.electronAPI?.writeDebugLog?.(line); } catch (_) { /* ignore */ }
}

/**
 * AudioIOManager - Manages audio input and output devices
 */
export class AudioIOManager {
    /**
     * Create a new AudioIOManager instance
     * @param {Object} contextManager - Reference to the AudioContextManager
     */
    constructor(contextManager) {
        this.contextManager = contextManager;
        this.stream = null;
        this.sourceNode = null;
        this.destinationNode = null;
        this.audioElement = null;
        this.defaultDestinationConnection = null;
        this.silenceNode = null;
        // When true, connect worklet output directly to AudioContext.destination
        // Used for multichannel and low-latency stereo modes
        this.directOutputMode = false;
        // When true, output is routed via AudioContext.setSinkId() directly.
        // This bypasses the MediaStream/audioElement path and uses the WebAudio
        // engine's own CoreAudio renderer, which may be more reliable for HDMI.
        this.audioContextSinkMode = false;
        this.currentOutputDeviceId = null;
        this._devicePollIntervalId = null;
        this._pollDeviceWasAbsent = false;
        // Guard against overlapping poll tick executions
        this._pollRunning = false;
    }
    
    /**
     * Initialize audio input (microphone)
     * @returns {Promise<string>} - Empty string on success, error message on failure
     */
    async initAudioInput() {
        hdmiDebug('INIT', 'initAudioInput start');
        try {
            // Variable to store microphone error message
            let microphoneError = null;
            
            // Flag to track if we're using microphone input
            let usingMicrophoneInput = true;
            
            // Check if we're running in Electron and have audio preferences
            let audioConstraints = {
                echoCancellation: false,
                noiseSuppression: false,
                autoGainControl: false
            };

            // If running in Electron, try to use saved audio preferences
            if (window.electronAPI && window.electronIntegration) {
                const preferences = await window.electronIntegration.loadAudioPreferences();
                if (preferences && preferences.inputDeviceId) {
                    audioConstraints.deviceId = { exact: preferences.inputDeviceId };
                } else {
                    console.log('No audio preferences found or no input device specified, using default audio input');
                    // Use default input device by not specifying deviceId
                }
            }

            // On macOS, trigger TCC permission dialog from the main process before getUserMedia.
            // We ignore the return value and let getUserMedia() be the final arbiter —
            // askForMediaAccess can return false for ad-hoc signed builds even when
            // System Settings shows the permission as allowed.
            if (window.electronAPI && window.electronAPI.requestMicrophoneAccess) {
                await window.electronAPI.requestMicrophoneAccess();
            }

            // Try to get user media with audio constraints
            let lastMicError = null;
            try {
                hdmiDebug('INIT', `getUserMedia start (deviceId=${audioConstraints.deviceId ? 'saved' : 'default'})`);
                this.stream = await this._getUserMediaWithTimeout({
                    audio: audioConstraints
                });
                hdmiDebug('INIT', 'getUserMedia done');
            } catch (error) {
                hdmiDebug('INIT', `getUserMedia failed: ${error.name} ${error.message}`);
                lastMicError = error;
                // If failed with saved device, try again with default device
                if (audioConstraints.deviceId) {
                    console.warn('Failed to use saved audio input device, falling back to default:', error.name, error.message);
                    delete audioConstraints.deviceId;
                    try {
                        this.stream = await this._getUserMediaWithTimeout({
                            audio: audioConstraints
                        });
                        lastMicError = null;
                    } catch (innerError) {
                        // If permission is denied, try to clear permission overrides and ask again.
                        // This recovers cases where Chromium's permission cache rejects despite
                        // the user actually having granted access (commonly seen on Windows/Linux,
                        // and on macOS ad-hoc signed builds where requestMicrophoneAccess returns false).
                        if (innerError.name === 'NotAllowedError' || innerError.name === 'PermissionDeniedError') {
                            if (window.electronAPI && window.electronAPI.clearMicrophonePermission) {
                                console.log('Microphone permission denied, attempting to clear permission overrides');
                                try {
                                    await window.electronAPI.clearMicrophonePermission();
                                    // Try one more time after clearing permissions
                                    this.stream = await this._getUserMediaWithTimeout({
                                        audio: audioConstraints
                                    });
                                    lastMicError = null;
                                } catch (finalError) {
                                    lastMicError = finalError;
                                    console.warn('Failed to get microphone access after clearing permissions:', finalError);
                                    usingMicrophoneInput = false;
                                }
                            } else {
                                console.warn('Microphone permission denied:', innerError);
                                usingMicrophoneInput = false;
                            }
                        } else {
                            console.warn('Failed to get microphone access:', innerError);
                            usingMicrophoneInput = false;
                        }
                    }
                } else if (error.name === 'NotAllowedError' || error.name === 'PermissionDeniedError') {
                    // If permission is denied on first attempt, try to clear permission overrides and ask again
                    if (window.electronAPI && window.electronAPI.clearMicrophonePermission) {
                        console.log('Microphone permission denied, attempting to clear permission overrides');
                        try {
                            await window.electronAPI.clearMicrophonePermission();
                            // Try one more time after clearing permissions
                            this.stream = await this._getUserMediaWithTimeout({
                                audio: audioConstraints
                            });
                            lastMicError = null;
                        } catch (finalError) {
                            lastMicError = finalError;
                            console.warn('Failed to get microphone access after clearing permissions:', finalError);
                            usingMicrophoneInput = false;
                        }
                    } else {
                        console.warn('Microphone permission denied:', error);
                        usingMicrophoneInput = false;
                    }
                } else {
                    console.warn('Failed to get microphone access:', error.name, error.message);
                    usingMicrophoneInput = false;
                }
            }

            // If we have microphone access, create source from stream
            if (usingMicrophoneInput && this.stream) {
                this.sourceNode = this.contextManager.audioContext.createMediaStreamSource(this.stream);
            } else {
                // No microphone access, create a stereo-compatible silent source as a fallback
                console.log('Creating stereo-compatible silent source as fallback');
                
                // Create a buffer source instead of oscillator for better stereo support
                const bufferSize = this.contextManager.audioContext.sampleRate * 2; // 2 seconds of silence
                const silentBuffer = this.contextManager.audioContext.createBuffer(
                    2, // 2 channels for stereo
                    bufferSize,
                    this.contextManager.audioContext.sampleRate
                );
                
                // Create a buffer source node
                const bufferSource = this.contextManager.audioContext.createBufferSource();
                bufferSource.buffer = silentBuffer;
                bufferSource.loop = true; // Loop the silent buffer
                
                // Create a gain node to ensure silence
                const gainNode = this.contextManager.audioContext.createGain();
                gainNode.gain.value = 0; // Mute
                
                // Connect buffer source to gain node
                bufferSource.connect(gainNode);
                bufferSource.start();
                
                // Use the gain node as our source node
                this.sourceNode = gainNode;
                
                // Log message for Electron users
                if (window.electronAPI && window.electronIntegration) {
                    console.log('Microphone access not available. Music file playback mode will still work.');
                }
                
                // Store the error message if microphone access was denied, but don't return it yet
                // This allows us to continue setting up the audio nodes for playback
                if (!usingMicrophoneInput) {
                    // Use the same error format as before so app.js can detect it properly.
                    // The MIC_DENIED_PREFIX shared constant guarantees the prefix stays in
                    // sync with AudioManager._doReset's startsWith() check.
                    microphoneError = `${MIC_DENIED_PREFIX}. Music file playback mode will still work.`;
                }
            }
            
            // Return microphone error if there was one
            return microphoneError || '';
        } catch (error) {
            console.error('Audio input initialization error:', error);
            return `Audio Error: ${error.message}`;
        }
    }

    /**
     * Acquire a microphone MediaStream using the saved device with a default-device
     * fallback.  Mirrors the acquisition portion of initAudioInput() but returns the
     * stream instead of wiring nodes, so the runtime reconnect path (reapplyInputDevice)
     * can reuse the exact same getUserMedia logic without rebuilding the audio graph.
     *
     * The clearMicrophonePermission retry from initAudioInput() is intentionally NOT
     * replicated: that path recovers a denied permission at startup, but a runtime
     * device reconnect implies permission was already granted earlier in the session.
     *
     * @param {string|null} preferredDeviceId - saved input device id, or null for default
     * @returns {Promise<{stream: MediaStream|null, error: Error|null}>}
     */
    async _acquireMicStream(preferredDeviceId) {
        const audioConstraints = {
            echoCancellation: false,
            noiseSuppression: false,
            autoGainControl: false
        };
        if (preferredDeviceId) {
            audioConstraints.deviceId = { exact: preferredDeviceId };
        }
        try {
            const stream = await this._getUserMediaWithTimeout({ audio: audioConstraints });
            return { stream, error: null };
        } catch (error) {
            // If the saved device failed, retry once with the default device.
            if (audioConstraints.deviceId) {
                delete audioConstraints.deviceId;
                try {
                    const stream = await this._getUserMediaWithTimeout({ audio: audioConstraints });
                    // The saved/preferred device failed and we silently bound to
                    // the system default instead. Signal it so reconnection
                    // callers can warn the user that input may not be the
                    // device they expect.
                    return { stream, error: null, usedFallback: true };
                } catch (innerError) {
                    return { stream: null, error: innerError };
                }
            }
            return { stream: null, error };
        }
    }

    /**
     * Initialize audio output
     * @returns {Promise<string>} - Empty string on success, error message on failure
     */
    async initAudioOutput() {
        hdmiDebug('INIT', 'initAudioOutput start');
        try {
            // For Electron, check if we're using multichannel output
            const preferences = window.electronAPI && window.electronIntegration ? 
                await window.electronIntegration.loadAudioPreferences() : null;
            const isMultiChannel = preferences && preferences.outputChannels && preferences.outputChannels > 2;
            const lowLatencyStereo = preferences && preferences.outputChannels === 2 && preferences.lowLatencyOutput;
            
            // For multichannel mode, we'll use direct connection to AudioContext.destination
            // rather than MediaStreamDestination which only supports stereo
            if (isMultiChannel || lowLatencyStereo) {
                console.log(`Using direct connection for ${preferences.outputChannels} channel output${lowLatencyStereo ? ' (low latency)' : ''}`);
                // Skip MediaStreamDestination for multichannel mode
                this.destinationNode = null;
                this.directOutputMode = true;
                return '';
            }
            
            // For standard stereo mode, use MediaStreamDestination
            try {
                if (typeof this.contextManager.audioContext.createMediaStreamDestination === 'function') {
                    this.destinationNode = this.contextManager.audioContext.createMediaStreamDestination();
                } else {
                    console.warn('createMediaStreamDestination is not supported in this browser');
                    // Fall back to default destination only
                    this.destinationNode = null;
                }
            } catch (error) {
                console.error('Error creating MediaStreamDestination:', error);
                // Fall back to default destination only
                this.destinationNode = null;
                return `Audio Error: Failed to create audio destination: ${error.message}`;
            }
            
            // For Electron, prepare audio output device (only in stereo mode)
            if (!isMultiChannel && window.electronAPI && window.electronIntegration) {
                // Route output through AudioContext.setSinkId() if the API is available.
                // This uses Chromium's WebAudio CoreAudio renderer instead of the
                // HTMLMediaElement renderer.  On macOS, these are separate code paths and
                // the WebAudio path is more reliable for HDMI reconnect recovery.
                if (preferences?.outputDeviceId &&
                    typeof this.contextManager.audioContext?.setSinkId === 'function') {
                    hdmiDebug('INIT', `audioContextSinkMode entered deviceId=${preferences.outputDeviceId}`);
                    this.audioContextSinkMode = true;
                    this.destinationNode = null; // use audioContext.destination via connectAudioNodes fallback
                    this.currentOutputDeviceId = preferences.outputDeviceId;
                    try {
                        hdmiDebug('INIT', 'ctx.setSinkId start');
                        // 3 s timeout instead of the default 10 s — on macOS HDMI flux,
                        // setSinkId can hang and we want to fail fast and continue with
                        // a usable (default-sink) audio context.
                        await this._setSinkIdWithTimeout(this.contextManager.audioContext, preferences.outputDeviceId, 3000);
                        hdmiDebug('INIT', `ctx.setSinkId done sinkId=${this.contextManager.audioContext.sinkId}`);
                    } catch (e) {
                        hdmiDebug('INIT', `ctx.setSinkId failed: ${e.message}`);
                        console.warn('[audioCtxSink] setSinkId failed:', e.message);
                    }
                    if (window.electronIntegration?.isElectronEnvironment?.()) {
                        this.startDevicePoll(
                            () => window.electronIntegration.loadAudioPreferences(),
                            // On macOS HDMI (audioContextSinkMode), reset(null) cannot recover —
                            // CoreAudio renderer needs full process restart.  Defer to App's
                            // macOS relaunch handler (which is gated by cooldown + startup grace).
                            // Otherwise pass null so _doReset does not call saveAudioPreferences,
                            // which would schedule a mainWindow.reload() and undo the recovery.
                            () => {
                                if (window.electronAPI?.platform === 'darwin' && window.app?._doMacosRelaunch) {
                                    return window.app._doMacosRelaunch();
                                }
                                return window.audioManager?.reset(null) ?? Promise.resolve();
                            },
                            false
                        );
                    }
                    return '';
                }

                // Rest of function continues for stereo output with device selection...
                if (preferences && preferences.outputDeviceId) {
                    try {
                        // Create a new audio element for actual use
                        if (this.audioElement) {
                            this.audioElement.pause();
                            this.audioElement.srcObject = null;
                        }
                        
                        this.audioElement = new Audio();
                        this.audioElement.autoplay = true;
                        this.audioElement.volume = 1.0;
                        this.audioElement.muted = false;
                        
                        // Check for Audio Output Devices API support
                        // The setSinkId method is part of the Audio Output Devices API
                        const hasSinkIdSupport =
                            typeof this.audioElement.setSinkId === 'function';
                        
                        if (hasSinkIdSupport) {
                            try {
                                // Get available devices - this doesn't require microphone permission
                                let outputDevice = null;
                                
                                try {
                                    // Try to enumerate devices - this works even without microphone permission
                                    if (typeof navigator.mediaDevices !== 'undefined' &&
                                        typeof navigator.mediaDevices.enumerateDevices === 'function') {
                                        const devices = await navigator.mediaDevices.enumerateDevices();
                                        outputDevice = devices.find(device =>
                                            device.kind === 'audiooutput' &&
                                            device.deviceId === preferences.outputDeviceId
                                        );
                                    }
                                } catch (enumError) {
                                    console.warn('Failed to enumerate devices:', enumError);
                                    // Continue with the saved device ID even if we can't verify it exists
                                }
                                
                                if (outputDevice) {
                                    await this.audioElement.setSinkId(preferences.outputDeviceId);
                                    this.currentOutputDeviceId = preferences.outputDeviceId;
                                } else {
                                    // Try to use the saved device ID directly even if we couldn't verify it
                                    try {
                                        await this.audioElement.setSinkId(preferences.outputDeviceId);
                                        this.currentOutputDeviceId = preferences.outputDeviceId;
                                    } catch (directSinkError) {
                                        console.warn('Failed to set audio output to saved device, using default:', directSinkError);
                                        // Fall back to default device
                                        await this.audioElement.setSinkId('default');
                                        this.currentOutputDeviceId = 'default';
                                    }
                                }
                                
                                // Now set the srcObject after sinkId is set
                                if (this.destinationNode && this.destinationNode.stream) {
                                    this.audioElement.srcObject = this.destinationNode.stream;
                                } else {
                                    console.warn('No destination stream available');
                                    // We already have a default connection from above
                                }
                                
                                // Explicitly call play()
                                try {
                                    await this.audioElement.play();
                                } catch (playError) {
                                    console.warn('Failed to play audio:', playError);
                                    // We already have a default connection from above
                                }
                            } catch (sinkError) {
                                console.warn('Failed to set audio output device:', sinkError);
                                // We already have a default connection from above
                                
                                // Still try to use the audio element as a fallback
                                if (this.destinationNode && this.destinationNode.stream) {
                                    this.audioElement.srcObject = this.destinationNode.stream;
                                }
                            }
                        } else {
                            console.warn('Audio Output Devices API not supported in this browser');
                            // We already have a default connection from above
                            
                            // Still try to use the audio element as a fallback
                            if (this.destinationNode && this.destinationNode.stream) {
                                this.audioElement.srcObject = this.destinationNode.stream;
                            }
                        }
                        
                        // Add event listeners for debugging
                        this.audioElement.addEventListener('error', (e) => {
                            // If there's an error with the audio element, make sure we're using the default output
                            // We already have a default connection from above
                        });
                    } catch (error) {
                        console.warn('Error setting up audio element with preferences:', error);
                        // We already have a default connection from above
                    }
                } else {
                    console.log('No audio preferences found or no output device specified, using default audio output');
                    
                    // Create a new audio element for the default device
                    try {
                        if (this.audioElement) {
                            this.audioElement.pause();
                            this.audioElement.srcObject = null;
                        }
                        
                        this.audioElement = new Audio();
                        this.audioElement.autoplay = true;
                        this.audioElement.volume = 1.0;
                        this.audioElement.muted = false;
                        
                        // Check for Audio Output Devices API support
                        const hasSinkIdSupport = typeof this.audioElement.setSinkId === 'function';
                        
                        if (hasSinkIdSupport) {
                            // Set to default device explicitly
                            try {
                                await this.audioElement.setSinkId('default');
                                console.log('Audio output set to default device');
                                this.currentOutputDeviceId = 'default';
                            } catch (sinkError) {
                                console.warn('Failed to set audio output to default device:', sinkError);
                            }
                        }
                        
                        // Connect to destination if available
                        if (this.destinationNode && this.destinationNode.stream) {
                            this.audioElement.srcObject = this.destinationNode.stream;
                            
                            // Explicitly call play()
                            try {
                                await this.audioElement.play();
                            } catch (playError) {
                                console.warn('Failed to play audio:', playError);
                                // Fall back to default output
                                this.defaultDestinationConnection = this.contextManager.workletNode.connect(this.contextManager.audioContext.destination);
                            }
                        } else {
                            // If no destination stream, connect worklet to default destination
                            this.defaultDestinationConnection = this.contextManager.workletNode.connect(this.contextManager.audioContext.destination);
                        }
                        
                        // Ensure proper multichannel configuration for the destination connection
                        if (this.contextManager.audioContext.destination.channelCount > 2) {
                            this.contextManager.audioContext.destination.channelCountMode = 'explicit';
                            this.contextManager.audioContext.destination.channelInterpretation = 'discrete';
                        }
                        
                        // Add event listeners for debugging
                        this.audioElement.addEventListener('error', (e) => {
                            // If there's an error with the audio element, make sure we're using the default output
                            if (!this.defaultDestinationConnection) {
                                this.defaultDestinationConnection = this.contextManager.workletNode.connect(this.contextManager.audioContext.destination);
                            }
                        });
                    } catch (error) {
                        console.warn('Error setting up default audio device:', error);
                        // Ensure we have audio output in case of error
                        if (!this.defaultDestinationConnection) {
                            this.defaultDestinationConnection = this.contextManager.workletNode.connect(this.contextManager.audioContext.destination);
                        }
                    }
                }
            }
            
            // If this is the first launch, set up a processor to mute audio output
            if (this.contextManager.isFirstLaunch && window.electronIntegration && window.electronIntegration.isElectron) {
                // Create a script processor node to zero-fill audio output
                const bufferSize = 4096;
                // Handle vendor prefixes for ScriptProcessorNode (deprecated but still used)
                let silenceNode;
                if (typeof this.contextManager.audioContext.createScriptProcessor === 'function') {
                    silenceNode = this.contextManager.audioContext.createScriptProcessor(bufferSize, 2, 2);
                } else if (typeof this.contextManager.audioContext.createJavaScriptNode === 'function') {
                    // Older browsers used createJavaScriptNode
                    silenceNode = this.contextManager.audioContext.createJavaScriptNode(bufferSize, 2, 2);
                } else {
                    console.warn('ScriptProcessorNode is not supported in this browser');
                    // Skip silence node creation and continue with normal audio output
                    return '';
                }
                
                silenceNode.onaudioprocess = (e) => {
                    // Get output buffer
                    const outputL = e.outputBuffer.getChannelData(0);
                    const outputR = e.outputBuffer.getChannelData(1);
                    
                    // Fill with zeros (silence)
                    for (let i = 0; i < outputL.length; i++) {
                        outputL[i] = 0;
                        outputR[i] = 0;
                    }
                };
                
                // Insert the silence node between worklet and destination
                try {
                    // Only disconnect if connected
                    if (this.destinationNode) {
                        this.contextManager.workletNode.disconnect(this.destinationNode);
                    }
                    this.contextManager.workletNode.connect(silenceNode);
                    silenceNode.connect(this.destinationNode);
                } catch (error) {
                    console.warn('Error connecting silence node:', error);
                    // Fall back to direct connection if there's an error
                    if (this.destinationNode) {
                        this.contextManager.workletNode.connect(this.destinationNode);
                    }
                }
                
                // Store reference to remove on cleanup
                this.silenceNode = silenceNode;
            }
            
            // Start polling fallback for HDMI reconnection (macOS devicechange unreliable)
            if (window.electronIntegration?.isElectronEnvironment?.() && this.audioElement) {
                // If the audio element ended up on a different device than preferred (fallback after
                // disconnect), treat the preferred device as absent so the first poll tick that finds
                // it back triggers a full reset rather than a reapply.
                const pollInitiallyAbsent = preferences?.outputDeviceId
                    ? this.audioElement.sinkId !== preferences.outputDeviceId
                    : false;
                this.startDevicePoll(
                    () => window.electronIntegration.loadAudioPreferences(),
                    // On macOS, reset(null) cannot recover from stuck CoreAudio state —
                    // route to App's macOS relaunch handler instead (gated by cooldown +
                    // startup grace).  Otherwise pass null so _doReset does not call
                    // saveAudioPreferences, which would schedule a mainWindow.reload().
                    () => {
                        if (window.electronAPI?.platform === 'darwin' && window.app?._doMacosRelaunch) {
                            return window.app._doMacosRelaunch();
                        }
                        return window.audioManager?.reset(null) ?? Promise.resolve();
                    },
                    pollInitiallyAbsent
                );
            }

            return '';
        } catch (error) {
            console.error('Audio output initialization error:', error);
            return `Audio Error: ${error.message}`;
        }
    }
    
    /**
     * Connect audio nodes
     * @returns {Promise<string>} - Empty string on success, error message on failure
     */
    async connectAudioNodes() {
        try {
            // Connect source to worklet
            try {
                // Make sure both nodes exist
                if (!this.sourceNode || !this.contextManager.workletNode) {
                    console.error('Source or worklet node is missing');
                    return `Audio Error: Audio initialization incomplete - missing audio nodes`;
                }
                
                // Use the original connect method to avoid any overridden connect methods
                if (window.originalConnectMethod && this.contextManager.isFirstLaunch) {
                    window.originalConnectMethod.call(this.sourceNode, this.contextManager.workletNode);
                } else {
                    this.sourceNode.connect(this.contextManager.workletNode);
                }
            } catch (error) {
                console.error('Error connecting source to worklet:', error);
                return `Audio Error: Failed to connect audio nodes: ${error.message}`;
            }
            
            // Connect based on our mode (direct output or via MediaStreamDestination)
            if (this.directOutputMode) {
                // Direct output mode - connect directly to destination
                try {
                    this.defaultDestinationConnection = this.contextManager.workletNode.connect(this.contextManager.audioContext.destination);
                    
                    // Ensure proper multichannel configuration
                    this.contextManager.audioContext.destination.channelCountMode = 'explicit';
                    this.contextManager.audioContext.destination.channelInterpretation = 'discrete';
                    
                    const preferences = window.electronAPI && window.electronIntegration ? 
                        await window.electronIntegration.loadAudioPreferences() : null;
                    const channelCount = preferences?.outputChannels || 4;
                } catch (error) {
                    console.error('Error connecting direct output:', error);
                    return `Audio Error: Failed to connect direct output: ${error.message}`;
                }
            } else if (this.destinationNode) {
                // Stereo mode with device selection - connect to MediaStreamDestination
                try {
                    this.contextManager.workletNode.connect(this.destinationNode);
                } catch (error) {
                    console.error('Error connecting worklet to destination:', error);
                    return `Audio Error: Failed to connect to audio destination: ${error.message}`;
                }
            } else {
                // Fallback for stereo mode without MediaStreamDestination - direct connection
                try {
                    this.defaultDestinationConnection = this.contextManager.workletNode.connect(this.contextManager.audioContext.destination);
                } catch (error) {
                    console.error('Error connecting to default audio destination:', error);
                    return `Audio Error: Failed to connect to default audio destination: ${error.message}`;
                }
            }
            
            // For web app (non-Electron), always connect to default destination
            // This is crucial for audio output to work
            if (!window.electronAPI || !window.electronIntegration) {
                // Disconnect any existing connections first to avoid conflicts
                try {
                    this.contextManager.workletNode.disconnect();
                } catch (e) {
                    // Ignore errors if already disconnected
                }
                
                // Always create a fresh connection for web app
                try {
                    this.defaultDestinationConnection = this.contextManager.workletNode.connect(this.contextManager.audioContext.destination);
                    
                    // Ensure proper multichannel configuration for the destination
                    if (this.contextManager.audioContext.destination.channelCount > 2) {
                        this.contextManager.audioContext.destination.channelCountMode = 'explicit';
                        this.contextManager.audioContext.destination.channelInterpretation = 'discrete';
                    }
                } catch (error) {
                    console.error('Error connecting to default audio destination:', error);
                    return `Audio Error: Failed to connect to default audio destination: ${error.message}`;
                }
            }
            
            return '';
        } catch (error) {
            console.error('Error connecting audio nodes:', error);
            return `Audio Error: ${error.message}`;
        }
    }
    
    /**
     * Create a fallback silent source node
     * @returns {AudioNode} - The created source node
     */
    createFallbackSilentSource() {
        console.warn('Source node missing, creating fallback silent source');
        // Create a silent source node as fallback
        const bufferSize = this.contextManager.audioContext.sampleRate * 2;
        const silentBuffer = this.contextManager.audioContext.createBuffer(2, bufferSize, this.contextManager.audioContext.sampleRate);
        const bufferSource = this.contextManager.audioContext.createBufferSource();
        bufferSource.buffer = silentBuffer;
        bufferSource.loop = true;
        
        const gainNode = this.contextManager.audioContext.createGain();
        gainNode.gain.value = 0;
        
        bufferSource.connect(gainNode);
        bufferSource.start();

        return gainNode;
    }

    /**
     * Reapply the currently saved output device to the audio element
     * @param {string} deviceId - Output device ID
     * @returns {Promise<boolean>} Success status
     */
    async reapplyOutputDevice(deviceId) {
        hdmiDebug('REAPPLY', `reapplyOutputDevice start deviceId=${deviceId} mode=${this.audioContextSinkMode ? 'ctx' : 'el'}`);
        // Use a shorter timeout (3 s) for runtime reapply than the 10 s used at init,
        // so that macOS HDMI stuck states fail fast and route to the relaunch fallback
        // instead of leaving the UI unresponsive for 10 s during multi-display flux.
        const RUNTIME_SETSINK_TIMEOUT_MS = 3000;
        const ctx = this.contextManager?.audioContext;
        if (this.audioContextSinkMode && typeof ctx?.setSinkId === 'function') {
            try {
                // setSinkId can hang indefinitely on macOS when HDMI is in a
                // re-re-connect / multi-display flux state — use the timeout wrapper.
                await this._setSinkIdWithTimeout(ctx, deviceId, RUNTIME_SETSINK_TIMEOUT_MS);
                this.currentOutputDeviceId = deviceId;
                hdmiDebug('REAPPLY', `ctx.setSinkId ok newSinkId=${ctx.sinkId}`);
                console.log('Reapplied output device (ctx):', deviceId);
                return true;
            } catch (error) {
                hdmiDebug('REAPPLY', `ctx.setSinkId failed: ${error.message}`);
                console.warn('Failed to reapply output device (ctx):', error);
                return false;
            }
        }
        if (!this.audioElement || typeof this.audioElement.setSinkId !== 'function') {
            return false;
        }
        try {
            // Same hang risk on the audio-element renderer path — wrap with timeout.
            await this._setSinkIdWithTimeout(this.audioElement, deviceId, RUNTIME_SETSINK_TIMEOUT_MS);
            this.currentOutputDeviceId = deviceId;
            if (this.destinationNode && this.destinationNode.stream) {
                this.audioElement.srcObject = this.destinationNode.stream;
            }
            try {
                await this.audioElement.play();
            } catch (e) {
                // Ignore play errors
            }
            console.log('Reapplied output device (el):', deviceId);
            return true;
        } catch (error) {
            console.warn('Failed to reapply output device (el):', error);
            return false;
        }
    }

    /**
     * Light runtime re-acquisition of the microphone after a USB unplug/replug,
     * WITHOUT tearing down the AudioContext / worklet / output path.  This keeps
     * music playback and output uninterrupted while only the input source is
     * swapped (source → worklet is the single edge that gets rewired).
     *
     * Returns false on any ambiguity so the caller can fall back to a full
     * audioManager.reset(null) — the proven heavyweight recovery.
     *
     * @param {string|null} preferredDeviceId - saved input device id, or null for default
     * @returns {Promise<boolean>} true if a live mic source was reconnected
     */
    // Surface a non-fatal notice when mic acquisition silently fell back to
    // the system default (the preferred/saved device was unavailable on
    // replug, so input may not be the device the user expects).
    _warnIfMicFallback(usedFallback) {
        if (!usedFallback) return;
        try {
            if (typeof window !== 'undefined' && window.uiManager?.setError) {
                window.uiManager.setError(
                    'Preferred microphone unavailable — using the system default input device.',
                    false);
                // Auto-clear like every other transient notice (shared single
                // error line) so it cannot linger as a stale message.
                setTimeout(() => {
                    try { window.uiManager?.clearError?.(); } catch (_) { /* ignore */ }
                }, 5000);
            }
        } catch (_) { /* notice is best-effort, never break recovery */ }
    }

    async reapplyInputDevice(preferredDeviceId) {
        hdmiDebug('REAPPLY-IN', `start preferredDeviceId=${preferredDeviceId ?? 'default'}`);

        // Player-owns-source guard: while the file player is active with
        // useInputWithPlayer=false, the player has swapped audioManager.sourceNode
        // for its own buffer/media source and stashed the mic source in
        // contextManager.originalSourceNode (restored on player stop).  In that
        // state the mic must NOT be connected to the worklet (would bleed into
        // playback), and this.sourceNode must NOT be touched (player owns it).
        const useInputWithPlayer = !!window.electronIntegration?.audioPreferences?.useInputWithPlayer;
        const playerCtxMgr = window.uiManager?.audioPlayer?.contextManager;
        const playerOwnsSource = !!playerCtxMgr?.originalSourceNode;
        if (playerOwnsSource && !useInputWithPlayer) {
            const oldStream = this.stream;
            const oldOriginalNode = playerCtxMgr.originalSourceNode;
            const { stream, usedFallback } = await this._acquireMicStream(preferredDeviceId);
            if (!stream) {
                hdmiDebug('REAPPLY-IN', 'player-owned: acquire failed → false');
                return false;
            }
            try {
                playerCtxMgr.originalSourceNode = this.contextManager.audioContext.createMediaStreamSource(stream);
            } catch (e) {
                hdmiDebug('REAPPLY-IN', `player-owned: createMediaStreamSource failed: ${e.message ?? e}`);
                stream.getTracks().forEach(t => t.stop());
                return false;
            }
            this.stream = stream;
            // Defensive: the old node was disconnected when the player took
            // over, but disconnect() again so a lingering edge cannot survive
            // the swap (symmetric with the non-player branch below).
            try { oldOriginalNode?.disconnect(); } catch (_) { /* ignore */ }
            try { oldStream?.getTracks().forEach(t => t.stop()); } catch (_) { /* ignore */ }
            this._warnIfMicFallback(usedFallback);
            hdmiDebug('REAPPLY-IN', 'player-owned: updated originalSourceNode (not wired to worklet)');
            return true;
        }

        const oldStream = this.stream;
        const oldSource = this.sourceNode;

        const { stream, error, usedFallback } = await this._acquireMicStream(preferredDeviceId);
        if (!stream) {
            hdmiDebug('REAPPLY-IN', `acquire failed (${error?.name ?? 'unknown'}) → false`);
            return false;
        }
        this._warnIfMicFallback(usedFallback);

        // Stop the old (dead) tracks and detach the old source.  This also
        // correctly handles the silent-gain fallback case: oldStream is null and
        // oldSource is a GainNode, so only disconnect() runs (no tracks to stop).
        try { oldSource?.disconnect(); } catch (_) { /* ignore */ }
        try { oldStream?.getTracks().forEach(t => t.stop()); } catch (_) { /* ignore */ }

        if (!this.contextManager.workletNode) {
            hdmiDebug('REAPPLY-IN', 'no workletNode → false (defer to reset)');
            return false;
        }

        try {
            this.stream = stream;
            this.sourceNode = this.contextManager.audioContext.createMediaStreamSource(stream);
            // Same connect guard as connectAudioNodes()
            if (window.originalConnectMethod && this.contextManager.isFirstLaunch) {
                window.originalConnectMethod.call(this.sourceNode, this.contextManager.workletNode);
            } else {
                this.sourceNode.connect(this.contextManager.workletNode);
            }
        } catch (e) {
            hdmiDebug('REAPPLY-IN', `wire failed: ${e.message ?? e} → false`);
            return false;
        }

        hdmiDebug('REAPPLY-IN', 'done (mic source reconnected)');
        return true;
    }

    /**
     * Start periodic polling to verify audio output device is active.
     * Fallback for macOS where HDMI reconnection may not trigger devicechange.
     * @param {Function} getPrefs - async function returning saved preferences
     * @param {Function} onReset  - async function(prefs) for full reinit
     */
    startDevicePoll(getPrefs, onReset, initiallyAbsent = false) {
        this.stopDevicePoll();
        this._pollDeviceWasAbsent = initiallyAbsent;
        this._devicePollIntervalId = setInterval(async () => {
            if (!window.electronIntegration?.isElectronEnvironment?.()) return;
            // Skip if a previous poll tick is still running (avoids stacking)
            if (this._pollRunning) return;
            this._pollRunning = true;
            try { await this._pollTick(getPrefs, onReset); } finally { this._pollRunning = false; }
        }, 4000);
    }

    async _pollTick(getPrefs, onReset) {
        // On macOS, skip the poll's recovery actions during the 10 s startup grace
        // (was 30 s — kept in sync with App._doMacosRelaunch's grace window).
        if (window.electronAPI?.platform === 'darwin' && window.app?._appStartTime) {
            const elapsed = Date.now() - window.app._appStartTime;
            if (elapsed < 10000) {
                hdmiDebug('POLL', `tick skipped (grace, elapsed=${elapsed}ms)`);
                return;
            }
        }
        hdmiDebug('POLL', 'tick start');

        let prefs;
        try { prefs = await getPrefs(); } catch (e) {
            console.warn('[_pollTick] Failed to load audio preferences:', e.message);
            return;
        }
        if (!prefs || !prefs.outputDeviceId) return;

        let devices;
        try { devices = await navigator.mediaDevices.enumerateDevices(); } catch (e) {
            console.warn('[_pollTick] Failed to enumerate devices:', e.message);
            return;
        }

        const outputs = devices.filter(d => d.kind === 'audiooutput');

        // Try exact ID match first; fall back to label match (HDMI may get new ID on reconnect)
        let foundDevice = outputs.find(d => d.deviceId === prefs.outputDeviceId);
        let foundByLabel = false;
        if (!foundDevice && prefs.outputDeviceLabel) {
            foundDevice = outputs.find(d => d.label === prefs.outputDeviceLabel);
            foundByLabel = !!foundDevice;
        }

        const wasAbsent = this._pollDeviceWasAbsent;
        this._pollDeviceWasAbsent = !foundDevice;

        // Current sinkId: use AudioContext or audioElement depending on mode
        const ctx = this.contextManager?.audioContext;
        const el = this.audioContextSinkMode ? null : this.audioElement;
        const currentSinkId = this.audioContextSinkMode
            ? (ctx?.sinkId ?? 'no-ctx')
            : (el?.sinkId ?? 'no-element');

        if (!foundDevice) return;
        if (!this.audioContextSinkMode && !el) return;

        const activeDeviceId = foundDevice.deviceId;
        const updatedPrefs = foundByLabel ? { ...prefs, outputDeviceId: activeDeviceId } : prefs;

        hdmiDebug('POLL', `state: foundDevice=${!!foundDevice} foundByLabel=${foundByLabel} wasAbsent=${wasAbsent} currentSinkId=${currentSinkId} activeDeviceId=${activeDeviceId} ctxState=${ctx?.state}`);

        // Stuck non-'running' AudioContext check.
        // Even when sinkId already matches and the device is present, the underlying
        // CoreAudio renderer can stay in a 'suspended' state after macOS HDMI flux
        // (the user perceives this as audio is dead but UI is alive — the original
        // freeze report).  Recovery: try a quick resume; if it does not bring the
        // ctx back to 'running', defer to onReset (= _doMacosRelaunch on macOS).
        if (this.audioContextSinkMode && ctx && ctx.state !== 'running' && ctx.state !== 'closed') {
            hdmiDebug('POLL', `ctx stuck non-running (state=${ctx.state}) — attempting resume`);
            try {
                await Promise.race([
                    ctx.resume(),
                    new Promise(resolve => setTimeout(resolve, 3000))
                ]);
            } catch (e) {
                hdmiDebug('POLL', `resume threw: ${e.message ?? e}`);
            }
            if (ctx.state !== 'running') {
                hdmiDebug('POLL', `still ${ctx.state} after resume — calling onReset`);
                try {
                    await onReset(updatedPrefs);
                    hdmiDebug('POLL', 'onReset returned (stuck-state path)');
                } catch (e) {
                    hdmiDebug('POLL', `onReset threw (stuck-state path): ${e.message ?? e}`);
                }
                return;
            }
            hdmiDebug('POLL', 'ctx recovered to running via resume');
            return;
        }

        if (currentSinkId !== activeDeviceId || foundByLabel) {
            // sinkId mismatch or device got a new ID — full reset needed
            if (wasAbsent || foundByLabel) {
                await new Promise(resolve => setTimeout(resolve, 2000));
            }
            hdmiDebug('POLL', 'onReset call (sinkId mismatch path)');
            try {
                await onReset(updatedPrefs);
                hdmiDebug('POLL', 'onReset returned');
            } catch (e) {
                hdmiDebug('POLL', `onReset threw: ${e.message ?? e}`);
                console.error('[_pollTick] onReset failed (sinkId mismatch path):', e.message ?? e);
            }
        } else if (wasAbsent) {
            // sinkId is already correct after reconnect.
            // If the context is already running, the devicechange handler handled
            // the reconnect — don't interfere with another toggle.
            if (this.audioContextSinkMode && ctx?.state === 'running') return;

            // Context is not running — do a light toggle + resume.
            try {
                if (this.audioContextSinkMode && ctx) {
                    await this._setSinkIdWithTimeout(ctx, '');
                    await new Promise(r => setTimeout(r, 1000));
                    await this._setSinkIdWithTimeout(ctx, activeDeviceId);
                    await Promise.race([
                        ctx.resume(),
                        new Promise(resolve => setTimeout(resolve, 15000))
                    ]).catch(() => {});
                    if (ctx.state === 'running') {
                        await window.audioManager?.rebuildPipeline(false).catch(() => {});
                    }
                } else if (el) {
                    await this._setSinkIdWithTimeout(el, 'default');
                    await new Promise(r => setTimeout(r, 300));
                    await this._setSinkIdWithTimeout(el, activeDeviceId);
                    if (this.destinationNode?.stream) el.srcObject = this.destinationNode.stream;
                    await el.play().catch(() => {});
                }
            } catch (e) {
                console.warn('[_pollTick] toggle+resume failed, falling back to full reset:', e.message ?? e);
                await onReset(updatedPrefs);
            }
        } else if (!this.audioContextSinkMode && (el.paused || el.readyState < 2)) {
            try { await el.play(); } catch (e) {
                console.warn('[_pollTick] el.play() failed, falling back to full reset:', e.message ?? e);
                await onReset(prefs);
            }
        }
    }

    _setSinkIdWithTimeout(target, sinkId, ms = 10000) {
        let timerId;
        return Promise.race([
            target.setSinkId(sinkId).finally(() => clearTimeout(timerId)),
            new Promise((_, reject) => {
                timerId = setTimeout(
                    () => reject(new Error(`setSinkId('${sinkId}') timed out after ${ms}ms`)),
                    ms
                );
            })
        ]);
    }

    /**
     * getUserMedia with timeout — on macOS, getUserMedia can hang indefinitely when
     * the audio system is in flux (HDMI re-re-connect, multi-display).  Apply a 5 s
     * timeout so the renderer can fall back to silent-source mode and proceed instead
     * of freezing.
     */
    _getUserMediaWithTimeout(constraints, ms = 5000) {
        let timerId;
        return Promise.race([
            navigator.mediaDevices.getUserMedia(constraints).finally(() => clearTimeout(timerId)),
            new Promise((_, reject) => {
                timerId = setTimeout(
                    () => reject(new Error(`getUserMedia timed out after ${ms}ms`)),
                    ms
                );
            })
        ]);
    }

    /**
     * Stop periodic device polling
     */
    stopDevicePoll() {
        if (this._devicePollIntervalId !== null) {
            clearInterval(this._devicePollIntervalId);
            this._devicePollIntervalId = null;
        }
        this._pollRunning = false;
    }

    /**
     * Clean up audio input and output
     */
    cleanupAudio() {
        hdmiDebug('CLEANUP', 'cleanupAudio start');
        // Stop polling before teardown to prevent race conditions
        this.stopDevicePoll();

        // Reset audioContextSinkMode so next initAudioOutput() re-evaluates it
        this.audioContextSinkMode = false;

        // Stop audio element if it exists
        if (this.audioElement) {
            this.audioElement.pause();
            this.audioElement.srcObject = null;
            this.audioElement = null;
        }
        
        // Disconnect from default destination if connected
        if (this.defaultDestinationConnection && this.contextManager.workletNode && this.contextManager.audioContext) {
            try {
                this.contextManager.workletNode.disconnect(this.contextManager.audioContext.destination);
            } catch (error) {
                console.warn('Error disconnecting from default destination:', error);
            }
        }
        
        // Disconnect silence node if it exists
        if (this.silenceNode && this.contextManager.audioContext) {
            try {
                this.silenceNode.disconnect();
                this.silenceNode = null;
            } catch (error) {
                console.warn('Error disconnecting silence node:', error);
            }
        }
        
        // Stop all media tracks
        if (this.stream) {
            this.stream.getTracks().forEach(track => track.stop());
            this.stream = null;
        }
        
        // Clear nodes
        this.sourceNode = null;
        this.destinationNode = null;
        this.defaultDestinationConnection = null;
        hdmiDebug('CLEANUP', 'cleanupAudio done');
    }
}