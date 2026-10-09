// Halo Lab home-network relay.
// Lets phones and other PCs on your home network open Halo Lab without admin rights:
// Windows already lets Node.js through the firewall, so this small program listens on the
// network and passes each request to Halo Lab on this PC (localhost only).
//   node halo-relay.js <listenPort> <haloPort>
// Halo Lab starts and stops it by itself when "home network" is turned on in Setup.
'use strict';
const http = require('http');

const listenPort = parseInt(process.argv[2] || '11501', 10);
const haloPort = parseInt(process.argv[3] || '11500', 10);

const server = http.createServer((req, res) => {
  const headers = Object.assign({}, req.headers);
  delete headers['x-halo-remote'];
  headers.host = 'localhost:' + haloPort;           // Halo Lab only answers to "localhost"
  headers['x-halo-remote'] = '1';                    // tells Halo Lab this came from another device
  headers['x-forwarded-for'] = req.socket.remoteAddress || '';
  const up = http.request({ host: '127.0.0.1', port: haloPort, method: req.method, path: req.url, headers }, (ur) => {
    res.writeHead(ur.statusCode || 502, ur.headers);
    ur.pipe(res);                                    // streams chat answers as they are written
  });
  up.on('error', () => {
    if (!res.headersSent) res.writeHead(502, { 'content-type': 'text/plain' });
    res.end('Halo Lab is not running on the PC right now.');
  });
  req.on('aborted', () => up.destroy());
  req.pipe(up);
});
server.keepAliveTimeout = 5000;
server.on('error', (e) => { console.error('Halo Lab relay: ' + e.message); process.exit(1); });
server.listen(listenPort, '0.0.0.0', () => console.log('Halo Lab relay on port ' + listenPort + ' -> localhost:' + haloPort));

// stop when Halo Lab stops (3 missed checks in a row, so a restart or a busy moment doesn't end it)
let missed = 0;
setInterval(() => {
  const r = http.get({ host: '127.0.0.1', port: haloPort, path: '/api/hl/ping', headers: { host: 'localhost:' + haloPort }, timeout: 5000 }, (res) => { missed = 0; res.resume(); });
  r.on('timeout', () => r.destroy());
  r.on('error', () => { if (++missed >= 3) { server.close(); process.exit(0); } });
}, 15000);
