# Web-888 Extension API Developer Guide

## Overview

The Web-888 supports 27 extensions that add specialized decoding and analysis capabilities. This guide documents the extension API and development workflow for creating custom extensions.

## Extension Architecture

### Extension Types

Extensions receive real-time IQ samples, audio samples, or FFT data from the SDR receiver and process them for specialized applications.

### Core Data Types

```cpp
// IQ sample (complex float)
typedef struct {
    float re;
    float im;
} TYPECPX;

// Mono 16-bit sample
typedef s2_t TYPEMONO16;  // 16-bit signed integer

// Extension context
typedef struct {
    const char* name;
    void (*close_conn)(int rx_chan);
    bool (*receive_msgs)(char* msg, int rx_chan);
    u4_t version;
    u4_t flags;
    void (*poll_cb)(int rx_chan);
} ext_t;
```

## Extension API

### Registration

```cpp
// Extension registration macro
#define EXT_NEW_VERSION 0xcafebeef

// Register extension with system
void ext_register(ext_t* ext);
```

### Data Callback Registration

```cpp
// Register for IQ samples (complex float)
void ext_register_receive_iq_samps(
    ext_receive_IQ_samps_t func,     // Callback function
    int rx_chan,                      // Receiver channel
    void* user_data                   // User context
);

// Register for real (mono) samples
void ext_register_receive_real_samps(
    ext_receive_real_samps_t func,
    int rx_chan,
    void* user_data
);

// Register for FFT/waterfall data
void ext_register_receive_FFT_samps(
    ext_receive_FFT_samps_t func,
    int rx_chan,
    void* user_data
);

// Register for S-meter data
void ext_register_receive_S_meter(
    ext_receive_S_meter_t func,
    int rx_chan,
    void* user_data
);
```

### Message Passing

```cpp
// Send message to extension's JavaScript frontend
void ext_send_msg(
    int rx_chan,
    bool debug,
    const char* msg,
    ...
);

// Send binary data to frontend
void ext_send_msg_data(
    int rx_chan,
    bool debug,
    u1_t cmd,
    u1_t* data,
    int nbytes
);

// Send message with encoded data
void ext_send_msg_encoded(
    int rx_chan,
    bool debug,
    const char* dst,
    u4_t encoding,
    const char* fmt,
    ...
);
```

### Frequency Control

```cpp
// Get current frequency
u4_t ext_get_freq(int rx_chan);

// Set frequency
void ext_set_freq(int rx_chan, u4_t freq_hz);

// Get mode (AM, USB, LSB, CW, etc.)
int ext_get_mode(int rx_chan);

// Set mode
void ext_set_mode(int rx_chan, int mode);
```

### Sample Rate Control

```cpp
// Set output sample rate
void ext_set_rate(int rx_chan, u2_t rate_kbps);

// Available rates: 4, 6, 8, 12, 16, 20, 24 kHz
```

## Extension Structure

### Minimum Extension Template

```cpp
// myext.cpp
#include "ext.h"
#include "myext.h"

// Per-channel state
typedef struct {
    int rx_chan;
    bool running;
    // Extension-specific data
} myext_t;

static myext_t myext[MAX_RX_CHANS];

// Initialize extension
bool myext_msgs(char* msg, int rx_chan)
{
    myext_t* e = &myext[rx_chan];
    
    if (strcmp(msg, "SET ext_init") == 0) {
        e->rx_chan = rx_chan;
        e->running = true;
        
        // Register for data
        ext_register_receive_iq_samps(myext_data, rx_chan, NULL);
        
        // Notify frontend
        ext_send_msg(rx_chan, false, "EXT ready");
        return true;
    }
    
    if (strcmp(msg, "SET start") == 0) {
        e->running = true;
        return true;
    }
    
    if (strcmp(msg, "SET stop") == 0) {
        e->running = false;
        return true;
    }
    
    return false;
}

// Data callback
void myext_data(int rx_chan, int nsamps, TYPECPX* samps)
{
    myext_t* e = &myext[rx_chan];
    
    if (!e->running) return;
    
    // Process samples
    for (int i = 0; i < nsamps; i++) {
        float re = samps[i].re;
        float im = samps[i].im;
        // Your processing here
    }
}

// Cleanup
void myext_close(int rx_chan)
{
    myext_t* e = &myext[rx_chan];
    e->running = false;
    ext_unregister_receive_iq_samps(rx_chan);
}

// Extension definition
ext_t myext_ext = {
    "myext",                    // Name
    myext_close,                // Close callback
    myext_msgs,                 // Message handler
    EXT_NEW_VERSION,            // Version
    0,                          // Flags
    NULL                        // Poll callback (optional)
};

// Auto-register
void myext_main()
{
    ext_register(&myext_ext);
}
```

### Header File (myext.h)

```cpp
// myext.h
#ifndef _MYEXT_H_
#define _MYEXT_H_

#include "ext.h"

void myext_main();
void myext_close(int rx_chan);
bool myext_msgs(char* msg, int rx_chan);
void myext_data(int rx_chan, int nsamps, TYPECPX* samps);

#endif
```

## Frontend Integration

### HTML Template

```html
<!-- extensions/myext/myext.html -->
<div id="id-myext">
    <div class="myext-container">
        <div class="myext-header">
            <h3>My Extension</h3>
        </div>
        <div class="myext-content">
            <div id="id-myext-display"></div>
            <button id="id-myext-start" onclick="myext_start()">Start</button>
            <button id="id-myext-stop" onclick="myext_stop()">Stop</button>
        </div>
        <div class="myext-controls">
            <label>Parameter:</label>
            <input type="range" id="id-myext-param" 
                   min="0" max="100" value="50"
                   onchange="myext_set_param(this.value)">
        </div>
    </div>
</div>
```

### JavaScript

```javascript
// extensions/myext/myext.js

var myext = {
    ext_name: 'myext',
    first_time: true,
    param: 50
};

function myext_main() {
    ext_switch_to_mode(myext.ext_name);
    
    if (myext.first_time) {
        myext.first_time = false;
        // Initialize UI
        ext_set_controls_width_height(400, 300);
    }
    
    // Send init message to backend
    ext_send('SET ext_init');
}

function myext_start() {
    ext_send('SET start');
    document.getElementById('id-myext-start').disabled = true;
    document.getElementById('id-myext-stop').disabled = false;
}

function myext_stop() {
    ext_send('SET stop');
    document.getElementById('id-myext-start').disabled = false;
    document.getElementById('id-myext-stop').disabled = true;
}

function myext_set_param(value) {
    myext.param = value;
    ext_send('SET param=' + value);
}

// Handle messages from backend
function myext_msg(param) {
    var tokens = param.split(' ');
    
    for (var i = 0; i < tokens.length; i++) {
        var token = tokens[i];
        
        if (token == 'ready') {
            console.log('MyExt: Backend ready');
        } else if (token.startsWith('result=')) {
            var result = token.split('=')[1];
            document.getElementById('id-myext-display').innerHTML = result;
        } else if (token.startsWith('data:')) {
            // Handle binary data
            var data = param.slice(param.indexOf('data:') + 5);
            myext_process_data(data);
        }
    }
}

function myext_process_data(data) {
    // Process data from extension
    console.log('Received data:', data);
}

// Blur function (called when switching away)
function myext_blur() {
    myext_stop();
}
```

### CSS Styling

```css
/* extensions/myext/myext.css */

#id-myext {
    padding: 10px;
    font-family: sans-serif;
}

.myext-container {
    display: flex;
    flex-direction: column;
    gap: 10px;
}

.myext-header h3 {
    margin: 0;
    color: #333;
}

.myext-content {
    border: 1px solid #ccc;
    padding: 10px;
    border-radius: 4px;
}

#id-myext-display {
    min-height: 100px;
    background: #f5f5f5;
    padding: 10px;
    margin-bottom: 10px;
    font-family: monospace;
    white-space: pre-wrap;
}

.myext-controls {
    display: flex;
    align-items: center;
    gap: 10px;
}

.myext-controls label {
    font-weight: bold;
}
```

## Example: CW Decoder

```cpp
// extensions/CW_decoder/CW_decoder.cpp

#include "ext.h"
#include "CW_decoder.h"

// CW decoder state
typedef struct {
    int rx_chan;
    bool running;
    float threshold;
    int wpm;
    // DSP state
    float goertzel_real;
    float goertzel_imag;
    int sample_count;
} cw_decoder_t;

static cw_decoder_t cw_decoder[MAX_RX_CHANS];

// Goertzel algorithm for tone detection
void goertzel_reset(cw_decoder_t* d)
{
    d->goertzel_real = 0;
    d->goertzel_imag = 0;
    d->sample_count = 0;
}

float goertzel_process(cw_decoder_t* d, float sample, float freq)
{
    // Standard Goertzel algorithm
    const float coeff = 2.0 * cos(2.0 * M_PI * freq / SND_RATE);
    static float s0 = 0, s1 = 0, s2 = 0;
    
    s0 = coeff * s1 - s2 + sample;
    s2 = s1;
    s1 = s0;
    
    d->sample_count++;
    
    if (d->sample_count >= GOERTZEL_N) {
        float power = s2*s2 + s1*s1 - coeff*s1*s2;
        goertzel_reset(d);
        return power;
    }
    return -1;  // Not ready yet
}

// Message handler
bool cw_decoder_msgs(char* msg, int rx_chan)
{
    cw_decoder_t* d = &cw_decoder[rx_chan];
    
    if (strcmp(msg, "SET ext_init") == 0) {
        d->rx_chan = rx_chan;
        d->threshold = 0.5;
        d->wpm = 20;
        
        // Set sample rate to 12 kHz for CW
        ext_set_rate(rx_chan, 12);
        
        // Register for real samples (post-detection)
        ext_register_receive_real_samps(cw_decoder_data, rx_chan, NULL);
        
        ext_send_msg(rx_chan, false, "EXT ready");
        return true;
    }
    
    int n;
    if (sscanf(msg, "SET threshold=%f", &d->threshold) == 1) {
        return true;
    }
    
    if (sscanf(msg, "SET wpm=%d", &d->wpm) == 1) {
        return true;
    }
    
    return false;
}

// Sample processing
void cw_decoder_data(int rx_chan, int nsamps, TYPEMONO16* samps)
{
    cw_decoder_t* d = &cw_decoder[rx_chan];
    
    if (!d->running) return;
    
    // Get current sidetone frequency
    u4_t freq = ext_get_freq(rx_chan);
    float tone_freq = 600.0;  // Default CW tone
    
    for (int i = 0; i < nsamps; i++) {
        float sample = samps[i] / 32768.0;  // Normalize
        
        float power = goertzel_process(d, sample, tone_freq);
        
        if (power >= 0) {  // Power computed
            bool tone_detected = power > d->threshold;
            
            // Decode Morse based on timing
            // (simplified - real decoder needs state machine)
            if (tone_detected) {
                // Mark detected
            } else {
                // Space detected
            }
        }
    }
}

void cw_decoder_close(int rx_chan)
{
    cw_decoder_t* d = &cw_decoder[rx_chan];
    d->running = false;
    ext_unregister_receive_real_samps(rx_chan);
}

ext_t cw_decoder_ext = {
    "CW_decoder",
    cw_decoder_close,
    cw_decoder_msgs,
    EXT_NEW_VERSION,
    0,
    NULL
};

void CW_decoder_main()
{
    ext_register(&cw_decoder_ext);
}
```

## Advanced Features

### Task-Based Extensions

For CPU-intensive processing, use separate tasks:

```cpp
// extensions/FT8/FT8.cpp pattern

#include "ext.h"

typedef struct {
    int rx_chan;
    tid_t tid;  // Task ID
    bool task_created;
    // ...
} ft8_t;

// Task function
static void ft8_task(void* param)
{
    ft8_t* e = (ft8_t*)param;
    
    while (e->running) {
        // Wait for samples
        TaskSleepUsec(100000);  // 100ms
        
        // Process accumulated samples
        // (FT8 decoding is CPU intensive)
    }
}

void ft8_init(int rx_chan)
{
    ft8_t* e = &ft8[rx_chan];
    
    // Create processing task
    e->tid = CreateTask(ft8_task, e, TASK_PRIORITY_MED);
    e->task_created = true;
    
    // Register for real samples (will wake task)
    ext_register_receive_real_samps_task(
        ft8_data,           // Callback
        rx_chan,            // Channel
        true,               // Create task
        e->tid,             // Task to signal
        0,                  // Notification index
        0                   // Sequence count
    );
}
```

### Autorun Extensions

Extensions can run automatically without user interface:

```cpp
// Internal connection for autorun
typedef struct {
    int rx_chan;
    bool autorun;
    u4_t freq;
    int mode;
} internal_conn_t;

// Check autorun conditions
void check_autorun(int rx_chan)
{
    ft8_t* e = &ft8[rx_chan];
    
    if (e->autorun && !e->internal_conn) {
        // Create internal connection
        e->internal_conn = (internal_conn_t*)calloc(1, sizeof(internal_conn_t));
        e->internal_conn->rx_chan = rx_chan;
        e->internal_conn->autorun = true;
        
        // Tune to FT8 frequency automatically
        e->internal_conn->freq = 14074000;  // 20m FT8
        e->internal_conn->mode = MODE_USB;
        
        // Start decoding
        ft8_start(e);
    }
}
```

## Build Integration

### Directory Structure

```
extensions/
└── myext/
    ├── myext.cpp      # Extension logic
    ├── myext.h        # Header file
    ├── myext.html     # Frontend HTML
    ├── myext.js       # Frontend JavaScript
    ├── myext.css      # Frontend styles
    └── CMakeLists.txt # Build configuration
```

### CMakeLists.txt

```cmake
# extensions/myext/CMakeLists.txt

set(EXT_FILES
    myext.cpp
)

# Optional: Add to main extension list
list(APPEND EXTENSIONS myext)
```

### Auto-Registration

Extensions are automatically registered via `mkextinit.py`:

```python
# pkgs/mkextinit.py generates extint.cpp

ext_list = [
    "ALE_2G",
    "CW_decoder",
    "FT8",
    "WSPR",
    # ... add myext here
    "myext",
]
```

## Testing and Debugging

### Debug Output

```cpp
// Use lprintf for debug output
lprintf("MyExt: Channel %d initialized\n", rx_chan);
lprintf("MyExt: Received %d samples\n", nsamps);

// Conditional debug
#define MYEXT_DEBUG
#ifdef MYEXT_DEBUG
    #define DBG(x) lprintf x
#else
    #define DBG(x)
#endif

DBG(("MyExt: Processing %d samples\n", nsamps));
```

### Frontend Debugging

```javascript
// Enable extension debugging
var myext_debug = true;

function myext_log(msg) {
    if (myext_debug) {
        console.log('MyExt: ' + msg);
    }
}

// Add UI debug panel
if (myext_debug) {
    var debugPanel = document.createElement('div');
    debugPanel.id = 'myext-debug';
    debugPanel.style.cssText = 'background:#333;color:#0f0;padding:10px;font-family:monospace;';
    document.body.appendChild(debugPanel);
}
```

## Best Practices

### 1. Resource Management

```cpp
// Always cleanup in close callback
void myext_close(int rx_chan)
{
    myext_t* e = &myext[rx_chan];
    
    // Stop processing
    e->running = false;
    
    // Unregister callbacks
    ext_unregister_receive_iq_samps(rx_chan);
    
    // Free allocated memory
    if (e->buffer) {
        free(e->buffer);
        e->buffer = NULL;
    }
    
    // Destroy tasks
    if (e->tid) {
        TaskRemove(e->tid);
        e->tid = 0;
    }
}
```

### 2. Thread Safety

```cpp
// Use mutex for shared data
static mutex_t myext_mutex;

void myext_init()
{
    mutex_init(&myext_mutex);
}

void myext_data(int rx_chan, int nsamps, TYPECPX* samps)
{
    mutex_lock(&myext_mutex);
    
    // Access shared data
    shared_counter++;
    
    mutex_unlock(&myext_mutex);
}
```

### 3. Error Handling

```cpp
bool myext_msgs(char* msg, int rx_chan)
{
    myext_t* e = &myext[rx_chan];
    
    if (strcmp(msg, "SET init") == 0) {
        // Check allocation
        if (!e) {
            ext_send_msg(rx_chan, true, "EXT error: allocation failed");
            return false;
        }
        
        // Check parameters
        if (e->buffer_size <= 0 || e->buffer_size > MAX_BUFFER) {
            ext_send_msg(rx_chan, true, "EXT error: invalid buffer size");
            return false;
        }
        
        // Allocate with check
        e->buffer = (float*)malloc(e->buffer_size * sizeof(float));
        if (!e->buffer) {
            ext_send_msg(rx_chan, true, "EXT error: malloc failed");
            return false;
        }
        
        return true;
    }
    
    return false;
}
```

### 4. Performance Considerations

```cpp
// Minimize work in data callback
void myext_data(int rx_chan, int nsamps, TYPECPX* samps)
{
    myext_t* e = &myext[rx_chan];
    
    // Quick rejection
    if (!e->running) return;
    
    // Batch processing - don't process every sample
    e->sample_buffer[e->buffer_idx++] = samps[0];
    
    if (e->buffer_idx >= BATCH_SIZE) {
        process_batch(e);
        e->buffer_idx = 0;
    }
}
```

## Extension Examples Summary

| Extension | Type | Data Source | Complexity |
|-----------|------|-------------|------------|
| CW_decoder | Signal processing | Real samples | Medium |
| FT8 | Protocol decoder | Real samples + Task | High |
| WSPR | Protocol decoder | IQ samples | High |
| S_meter | Display | S-meter | Low |
| IQ_display | Visualization | IQ samples | Low |
| FFT | Visualization | FFT data | Low |
| ant_switch | Control | None | Low |
| noise_blank | Signal processing | IQ samples | Medium |

## References

- [RaspSDR Extensions Directory](https://github.com/RaspSDR/server/tree/main/extensions)
- [KiwiSDR Extension API](https://github.com/jks-prv/Beagle_SDR_GPS/tree/master/extensions)
- [ext.h Header File](https://github.com/RaspSDR/server/blob/main/extensions/ext.h)

---

*Document version: 2026-03-31*
