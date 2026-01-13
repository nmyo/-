# OpenResty Video Streaming Configuration

This project provides an optimized OpenResty configuration paired with a modern HTML5 video player for streaming video content through proxy servers.

## Features

### Nginx Configuration (`nginx.conf`)
- **Backend Connection Pooling**: Keep-alive connections to backend servers for improved performance
- **HTTPS Enforcement**: Automatic HTTP to HTTPS redirection
- **Video Streaming Optimized**: Special handling for video formats and range requests
- **Security Headers**: Proper CORS headers, security enhancements, and protection against common attacks
- **PHP Processing**: FastCGI integration for dynamic content processing
- **Static Asset Optimization**: Caching and compression for static files
- **Mobile-Friendly**: Responsive design and mobile-specific optimizations

### HTML Player (`index.html`)
- **HLS Support**: Uses hls.js library for adaptive streaming
- **Network Quality Detection**: Automatically adjusts buffering based on network conditions
- **Progressive Enhancement**: Works with both HLS.js and native HLS support (Safari)
- **User Controls**: Full playback controls including seeking, volume, speed, PiP, fullscreen
- **Keyboard Shortcuts**: Space(play/pause), arrows(seeking), volume controls
- **Search Integration**: Built-in search functionality with API integration
- **Playback History**: Remembers playback position per video

## Installation

### Prerequisites
- OpenResty installed on your server
- SSL certificates configured (using Let's Encrypt path in the example)
- PHP-FPM for backend processing

### Setup Steps

1. Place the `index.html` file in your web root directory (`/var/www/video/` by default)

2. Configure your OpenResty server with the provided `nginx.conf` settings

3. Update the server name in the configuration:
   ```nginx
   server_name videos.nyanx.de;  # Replace with your domain
   ```

4. Update the SSL certificate paths:
   ```nginx
   ssl_certificate     /etc/letsencrypt/live/videos.nyanx.de/fullchain.pem;
   ssl_certificate_key /etc/letsencrypt/live/videos.nyanx.de/privkey.pem;
   ```

5. Update the API endpoint in `index.html` if needed:
   ```javascript
   const API = "https://apiv.nyanx.de/";  # Replace with your API endpoint
   ```

## Configuration Options

### Nginx Configuration
- **Backend Proxy**: Configured for surrit.com with keep-alive connections
- **PHP Processing**: Integrated with PHP-FPM via Unix socket
- **Security**: Blocks access to sensitive files (.db, .sqlite, etc.)
- **Compression**: Gzip enabled for text-based assets
- **CORS**: Properly configured for cross-origin video streaming

### JavaScript Configuration
- **Network Adaptation**: Adjusts buffering and quality based on detected network conditions
- **Error Handling**: Comprehensive error recovery for streaming issues
- **Performance**: Optimized for mobile devices with wake lock and rendering optimizations

## Performance Optimizations

### Video Streaming
- Large buffer sizes for smooth playback over unstable connections
- Range request support for seeking
- Progressive loading to minimize startup time
- Multiple retry mechanisms for failed requests

### Mobile Optimizations
- Screen wake lock to prevent device sleep during playback
- Touch-friendly controls
- Hardware acceleration enabled
- Optimized for mobile networks with adaptive quality

### Caching Strategies
- Browser caching for static assets
- Backend connection pooling
- Smart buffering strategies based on network quality

## Security Considerations

- SSL/TLS enforced with strong cipher suites
- X-Frame-Options and other security headers
- Access restrictions for sensitive files
- Proper CORS configuration to prevent unauthorized usage

## Customization

### Changing Video Sources
Update the upstream configuration in nginx to point to your video source:
```nginx
upstream surrit_backend {
    server your-video-source.com:443;
    keepalive 64;
}
```

### API Integration
Modify the API variable in index.html to point to your backend:
```javascript
const API = "https://your-api-endpoint.com/";
```

### Styling
The player uses CSS variables for easy theme customization:
```css
:root {
  --yt-red: #ff0000;
  --bg-dark: #000000;
  --panel-bg: rgba(28, 28, 28, 0.95);
  --border-light: rgba(255, 255, 255, 0.1);
}
```

## Troubleshooting

### Common Issues
- **Videos not loading**: Check SSL certificates and backend connectivity
- **Playback stuttering**: Adjust buffer settings in JavaScript based on network conditions
- **CORS errors**: Verify nginx CORS configuration matches your domain
- **Mobile playback issues**: Ensure proper mobile meta tags and autoplay policies

### Debugging
Enable debug logging in nginx and check browser console for JavaScript errors.

## License

This project is open source and available under the MIT License.