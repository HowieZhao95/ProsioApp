#!/usr/bin/env node
// Local review player. Re-run this script after editing the film source.
import {build} from 'esbuild';
import {createReadStream} from 'node:fs';
import {realpath, stat} from 'node:fs/promises';
import {createServer} from 'node:http';
import {dirname, extname, isAbsolute, relative, resolve, sep} from 'node:path';
import {fileURLToPath} from 'node:url';

const project = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const output = resolve(project, 'out/preview');
await build({
  absWorkingDir: project,
  entryPoints: ['src/preview.tsx'],
  outfile: resolve(output, 'app.js'),
  bundle: true,
  platform: 'browser',
  format: 'esm',
  target: ['chrome110', 'safari15'],
  jsx: 'automatic',
  sourcemap: true,
  define: {'process.env.NODE_ENV': '"production"'},
  logLevel: 'info',
});
if (process.argv.includes('--build-only')) process.exit(0);

const publicRoot = await realpath(resolve(project, 'public'));
const bundleRoot = await realpath(output);
const htmlPath = await realpath(resolve(project, 'preview.html'));
const mimeTypes = {
  '.html': 'text/html; charset=utf-8', '.js': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8', '.json': 'application/json; charset=utf-8',
  '.map': 'application/json; charset=utf-8', '.wav': 'audio/wav', '.mp3': 'audio/mpeg',
  '.m4a': 'audio/mp4', '.mp4': 'video/mp4', '.webm': 'video/webm',
  '.png': 'image/png', '.jpg': 'image/jpeg', '.jpeg': 'image/jpeg',
  '.webp': 'image/webp', '.svg': 'image/svg+xml', '.woff2': 'font/woff2',
  '.woff': 'font/woff', '.ttf': 'font/ttf', '.ico': 'image/x-icon',
};

const within = (root, filename) => {
  const path = relative(root, filename);
  return path === '' || (!isAbsolute(path) && path !== '..' && !path.startsWith(`..${sep}`));
};
const failure = (response, code, message) => {
  response.writeHead(code, {'Content-Type': 'text/plain; charset=utf-8', 'X-Content-Type-Options': 'nosniff'});
  response.end(message);
};

const server = createServer(async (request, response) => {
  if (!['GET', 'HEAD'].includes(request.method ?? '')) {
    response.setHeader('Allow', 'GET, HEAD');
    failure(response, 405, 'Method not allowed');
    return;
  }
  try {
    let pathname;
    try {
      pathname = decodeURIComponent((request.url ?? '/').split('?')[0]);
    } catch {
      failure(response, 400, 'Malformed path');
      return;
    }
    // Reject traversal BEFORE URL/path normalization. Also disallow Windows
    // separators, NUL and dotfiles. realpath below protects symlink escapes.
    if (!pathname.startsWith('/') || pathname.includes('\\') || pathname.includes('\0') ||
        pathname.split('/').some((part) => part === '..' || part === '.' || part.startsWith('.'))) {
      failure(response, 403, 'Forbidden path');
      return;
    }
    let filename;
    if (pathname === '/' || pathname === '/preview.html') {
      filename = htmlPath;
    } else {
      const isBundle = pathname === '/app.js' || pathname === '/app.js.map';
      const root = isBundle ? bundleRoot : publicRoot;
      const candidate = resolve(root, `.${pathname}`);
      if (!within(root, candidate)) {
        failure(response, 403, 'Forbidden path');
        return;
      }
      filename = await realpath(candidate);
      if (!within(root, filename)) {
        failure(response, 403, 'Forbidden path');
        return;
      }
    }
    const metadata = await stat(filename);
    if (!metadata.isFile()) {
      failure(response, 404, 'Not found');
      return;
    }
    let start = 0;
    let end = metadata.size - 1;
    let code = 200;
    const range = request.headers.range;
    if (range) {
      const match = /^bytes=(\d*)-(\d*)$/.exec(range);
      if (!match || (!match[1] && !match[2])) {
        response.setHeader('Content-Range', `bytes */${metadata.size}`);
        failure(response, 416, 'Invalid range');
        return;
      }
      if (!match[1]) {
        start = Math.max(0, metadata.size - Number(match[2]));
      } else {
        start = Number(match[1]);
        if (match[2]) end = Math.min(end, Number(match[2]));
      }
      if (start > end || start >= metadata.size || !Number.isSafeInteger(start) || !Number.isSafeInteger(end)) {
        response.setHeader('Content-Range', `bytes */${metadata.size}`);
        failure(response, 416, 'Range not satisfiable');
        return;
      }
      code = 206;
    }
    const headers = {
      'Content-Type': mimeTypes[extname(filename).toLowerCase()] ?? 'application/octet-stream',
      'Content-Length': String(Math.max(0, end - start + 1)),
      'Cache-Control': 'no-cache',
      'Accept-Ranges': 'bytes',
      'X-Content-Type-Options': 'nosniff',
    };
    if (code === 206) headers['Content-Range'] = `bytes ${start}-${end}/${metadata.size}`;
    response.writeHead(code, headers);
    if (request.method === 'HEAD' || metadata.size === 0) {
      response.end();
      return;
    }
    const stream = createReadStream(filename, {start, end});
    stream.on('error', () => response.destroy());
    response.on('close', () => stream.destroy());
    stream.pipe(response);
  } catch (error) {
    if (!response.headersSent) failure(response, error.code === 'ENOENT' || error.code === 'ENOTDIR' ? 404 : 500, 'Not found');
    else response.destroy();
  }
});

server.on('error', (error) => {
  console.error(`Preview server failed: ${error.message}`);
  process.exitCode = 1;
});
server.listen(3211, '127.0.0.1', () => {
  console.log('Prosio preview: http://127.0.0.1:3211');
  console.log('Restart this command to rebuild after source changes.');
});
for (const signal of ['SIGINT', 'SIGTERM']) {
  process.on(signal, () => server.close(() => process.exit(0)));
}
